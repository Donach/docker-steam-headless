
# Fech NVIDIA GPU device (if one exists)
if [ "${NVIDIA_VISIBLE_DEVICES:-}" == "all" ]; then
    export gpu_select=$(nvidia-smi --format=csv --query-gpu=uuid 2> /dev/null | sed -n 2p)
elif [ -z "${NVIDIA_VISIBLE_DEVICES:-}" ]; then
    export gpu_select=$(nvidia-smi --format=csv --query-gpu=uuid 2> /dev/null | sed -n 2p)
else
    export gpu_select=$(nvidia-smi --format=csv --id=$(echo "$NVIDIA_VISIBLE_DEVICES" | cut -d ',' -f1) --query-gpu=uuid | sed -n 2p)
    if [ -z "$gpu_select" ]; then
        export gpu_select=$(nvidia-smi --format=csv --query-gpu=uuid 2> /dev/null | sed -n 2p)
    fi
fi

export nvidia_gpu_hex_id=$(nvidia-smi --format=csv --query-gpu=pci.bus_id --id="${gpu_select}" 2> /dev/null | sed -n 2p)

export monitor_connected=$(cat /sys/class/drm/card*/status | awk '/^connected/ { print $1; }' | head -n1)

# Detect an AMD GPU (only relevant when no NVIDIA device is in use)
if lspci 2>/dev/null | grep -iE 'vga|display|3d controller' | grep -iqE 'amd/ati|advanced micro devices'; then
    export amd_gpu_present="true"
else
    export amd_gpu_present="false"
fi

# Fech current configuration (if modified in UI)
if [ -f "${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml" ]; then
    new_display_sizew=$(cat ${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml | grep Resolution | head -n1 | grep -oP '(?<=value=").*?(?=")' | cut -d'x' -f1)
    new_display_sizeh=$(cat ${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml | grep Resolution | head -n1 | grep -oP '(?<=value=").*?(?=")' | cut -d'x' -f2)
    new_display_refresh=$(cat ${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml | grep RefreshRate | head -n1 | grep -oP '(?<=value=").*?(?=")' | cut -d'x' -f2)
    if [ "${new_display_sizew}x" != "x" ] && [ "${new_display_sizeh}x" != "x" ] && [ "${new_display_refresh}x" != "x" ]; then
        export DISPLAY_SIZEW="${new_display_sizew}"
        export DISPLAY_SIZEH="${new_display_sizeh}"
        # Round refresh rate to closest multiple of 60
        export DISPLAY_REFRESH="$(echo ${new_display_refresh} | awk '{rounded = int(($1 + 30) / 60) * 60; if (rounded < 30) rounded += 60; print rounded}')"
    fi
fi

# Configure a NVIDIA X11 config
function configure_nvidia_x_server {
    print_step_header "Configuring X11 with GPU ID: '${gpu_select}'"
    nvidia_gpu_hex_id=$(nvidia-smi --format=csv --query-gpu=pci.bus_id --id="${gpu_select}" 2> /dev/null | sed -n 2p)
    IFS=":." ARR_ID=(${nvidia_gpu_hex_id})
    unset IFS
    bus_id=PCI:$((16#${ARR_ID[1]})):$((16#${ARR_ID[2]})):$((16#${ARR_ID[3]}))
    print_step_header "Configuring X11 with PCI bus ID: '${bus_id}'"
    export MODELINE=$(cvt -r "${DISPLAY_SIZEW}" "${DISPLAY_SIZEH}" "${DISPLAY_REFRESH}" | sed -n 2p)
    print_step_header "Writing X11 config with ${MODELINE}"
    connected_monitor="--use-display-device=None"
    if [[ "X${DISPLAY_VIDEO_PORT:-}" != "X" ]]; then
        connected_monitor="--connected-monitor=${DISPLAY_VIDEO_PORT:?}"
    fi
    nvidia-xconfig --virtual="${DISPLAY_SIZEW:?}x${DISPLAY_SIZEH:?}" --depth="${DISPLAY_CDEPTH:?}" --mode=$(echo "${MODELINE:?}" | awk '{print $2}' | tr -d '"') --allow-empty-initial-configuration --no-probe-all-gpus --busid="${bus_id:?}" --no-multigpu --no-sli --no-base-mosaic --only-one-x-screen ${connected_monitor:?}
    # Allow SteamHeadless to run with an eGPU
    sed -i '/Driver\s\+"nvidia"/a\    Option         "AllowExternalGpus" "True"' /etc/X11/xorg.conf
    # Configure primary GPU
    sed -i '/Driver\s\+"nvidia"/a\    Option         "PrimaryGPU" "yes"' /etc/X11/xorg.conf
    # Force X server to start even if no display devices are connected
    sed -i '/Driver\s\+"nvidia"/a\    Option         "AllowEmptyInitialConfiguration"' /etc/X11/xorg.conf
    # Disable some mode validation checks
    sed -i '/Driver\s\+"nvidia"/a\    Option         "ModeValidation" "NoMaxPClkCheck, NoEdidMaxPClkCheck, NoMaxSizeCheck, NoHorizSyncCheck, NoVertRefreshCheck, NoVirtualSizeCheck, NoTotalSizeCheck, NoDualLinkDVICheck, NoDisplayPortBandwidthCheck, AllowNon3DVisionModes, AllowNonHDMI3DModes, AllowNonEdidModes, NoEdidHDMI2Check, AllowDpInterlaced"' /etc/X11/xorg.conf
    # Configure the default modeline
    sed -i '/Section\s\+"Monitor"/a\    '"${MODELINE}" /etc/X11/xorg.conf
    # Prevent interference between GPUs
    echo -e "Section \"ServerFlags\"\n    Option \"AutoAddGPU\" \"false\"\nEndSection" | tee -a /etc/X11/xorg.conf > /dev/null
}

# Configure an AMD (amdgpu) X11 config for a hardware-accelerated, headless X server.
# Without this, AMD GPUs fall through to the software "dummy" driver (llvmpipe) whenever
# no physical monitor is connected, which breaks GPU rendering for many games (e.g. UE5
# titles crash with EXCEPTION_ACCESS_VIOLATION when they pick the software device).
# NOTE: a disconnected output cannot light up on its own. For a truly headless host set
# a forced mode on the GPU connector via the HOST kernel cmdline, e.g.:
#     video=DP-1:1920x1080e
# (or plug in a cheap HDMI/DP dummy adapter). Optionally point AMD_CUSTOM_EDID at an EDID
# blob and DISPLAY_VIDEO_PORT at the connector to inject an EDID via the DDX driver.
function configure_amd_x_server {
    print_step_header "Configuring X11 for AMD GPU (amdgpu)"
    local amd_pci_addr amd_bus amd_dev amd_func amd_bus_id modeline modename

    # Resolve the AMD VGA controller PCI address (e.g. "0d:00.0")
    amd_pci_addr="$(lspci 2>/dev/null | grep -iE 'vga|display|3d controller' | grep -iE 'amd/ati|advanced micro devices' | head -n1 | awk '{print $1}')"
    if [ -z "${amd_pci_addr}" ]; then
        print_warning "Could not resolve AMD GPU PCI address. Falling back to dummy xorg.conf"
        cp -f /templates/xorg/xorg.dummy.conf /etc/X11/xorg.conf
        return 0
    fi

    # Convert hex PCI address to the decimal "PCI:bus:dev:func" form Xorg expects
    IFS=':.' read -r amd_bus amd_dev amd_func <<< "${amd_pci_addr}"
    amd_bus_id="PCI:$((16#${amd_bus})):$((16#${amd_dev})):$((16#${amd_func}))"
    print_step_header "AMD GPU at ${amd_pci_addr} -> ${amd_bus_id}"

    modeline="$(cvt -r "${DISPLAY_SIZEW:?}" "${DISPLAY_SIZEH:?}" "${DISPLAY_REFRESH:?}" | sed -n 2p)"
    modename="$(echo "${modeline}" | awk '{print $2}' | tr -d '"')"
    print_step_header "Writing AMD X11 config with ${modeline}"

    # Optional EDID injection (lets a disconnected port present a monitor to the DDX driver)
    local edid_option=""
    if [ -n "${AMD_CUSTOM_EDID:-}" ] && [ -f "${AMD_CUSTOM_EDID}" ] && [ -n "${DISPLAY_VIDEO_PORT:-}" ]; then
        print_step_header "Using CustomEDID ${DISPLAY_VIDEO_PORT}:${AMD_CUSTOM_EDID}"
        edid_option="    Option         \"CustomEDID\" \"${DISPLAY_VIDEO_PORT}:${AMD_CUSTOM_EDID}\""
    fi

    cat > /etc/X11/xorg.conf <<EOF
Section "ServerFlags"
    Option         "AutoAddGPU" "false"
    Option         "DontVTSwitch" "true"
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    ${modeline}
    Option         "PreferredMode" "${modename}"
EndSection

Section "Device"
    Identifier     "AMD"
    Driver         "amdgpu"
    BusID          "${amd_bus_id}"
    Option         "DRI" "3"
${edid_option}
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "AMD"
    Monitor        "Monitor0"
    DefaultDepth   ${DISPLAY_CDEPTH:?}
    SubSection     "Display"
        Depth      ${DISPLAY_CDEPTH:?}
        Modes      "${modename}"
        Virtual    ${DISPLAY_SIZEW:?} ${DISPLAY_SIZEH:?}
    EndSubSection
EndSection
EOF
}

# Allow anybody for running x server
function configure_x_server {
    # Configure x to be run by anyone
    if [[ ! -f /etc/X11/Xwrapper.config ]]; then
        print_step_header "Create Xwrapper.config"
        echo 'allowed_users=anybody' > /etc/X11/Xwrapper.config
        echo 'needs_root_rights=yes' >> /etc/X11/Xwrapper.config
    elif grep -Fxq "allowed_users=console" /etc/X11/Xwrapper.config; then
        print_step_header "Configure Xwrapper.config"
        sed -i "s/allowed_users=console/allowed_users=anybody/" /etc/X11/Xwrapper.config
        echo 'needs_root_rights=yes' >> /etc/X11/Xwrapper.config
    fi

    # Remove previous Xorg config
    rm -f /etc/X11/xorg.conf

    # Ensure the X socket path exists
    mkdir -p ${XORG_SOCKET_DIR:?}

    # Clear out old lock files
    display_file=${XORG_SOCKET_DIR}/X${DISPLAY#:}
    if [ -S ${display_file} ]; then
        print_step_header "Removing ${display_file} before starting"
        rm -f /tmp/.X${DISPLAY#:}-lock
        rm ${display_file}
    fi

    # Ensure X-windows session path is owned by root 
    mkdir -p /tmp/.ICE-unix
    chown root:root /tmp/.ICE-unix/
    chmod 1777 /tmp/.ICE-unix/

    # Check if this container is being run as a secondary instance
    if ([ "${MODE}" = "p" ] || [ "${MODE}" = "primary" ]); then
        print_step_header "Configure container as primary the X server"
        # Enable supervisord script
        sed -i 's|^autostart.*=.*$|autostart=true|' /etc/supervisor.d/xorg.ini
    elif [ "${MODE}" == "fb" ] | [ "${MODE}" == "framebuffer" ]; then
        print_step_header "Configure container to use a virtual framebuffer as the X server"
        # Disable xorg supervisord script
        sed -i 's|^autostart.*=.*$|autostart=false|' /etc/supervisor.d/xorg.ini
        # Enable xvfb supervisord script
        sed -i 's|^autostart.*=.*$|autostart=true|' /etc/supervisor.d/xvfb.ini
    else
        print_step_header "Configure container with no X server"
        sed -i 's|^autostart.*=.*$|autostart=false|' /etc/supervisor.d/xorg.ini
    fi

    # Enable KB/Mouse input capture with Xorg if configured
    if [ ${ENABLE_EVDEV_INPUTS:-} = "true" ]; then
        print_step_header "Enabling evdev input class on pointers, keyboards, touchpads, touch screens, etc."
        cp -f /usr/share/X11/xorg.conf.d/10-evdev.conf /etc/X11/xorg.conf.d/10-evdev.conf
    else
        print_step_header "Leaving evdev inputs disabled"
    fi
    
    # Configure dummy config if no monitor is connected (not applicable to NVIDIA)
    if [ "${FORCE_X11_DUMMY_CONFIG}" = "true" ]; then
        print_step_header "FORCE_X11_DUMMY_CONFIG=true. Installing dummy xorg.conf"
        # Use a dummy display input
        cp -f /templates/xorg/xorg.dummy.conf /etc/X11/xorg.conf
    elif [ "X${monitor_connected}" = "X" ]; then
        # No physical monitor. On AMD, opt in to a real amdgpu X server with
        # AMD_HW_XORG=true (gives hardware GL instead of software llvmpipe);
        # otherwise keep the historical dummy/software behaviour.
        if [ "${amd_gpu_present:-false}" = "true" ] && [ "${AMD_HW_XORG:-false}" = "true" ] && [ -z "${nvidia_gpu_hex_id}" ]; then
            print_step_header "No monitors connected. AMD_HW_XORG enabled; using amdgpu xorg.conf"
            configure_amd_x_server
        else
            print_step_header "No monitors connected. Installing dummy xorg.conf"
            # Use a dummy display input
            cp -f /templates/xorg/xorg.dummy.conf /etc/X11/xorg.conf
        fi
    fi
}

if ([ "${MODE}" != "s" ] && [ "${MODE}" != "secondary" ]); then
    if [[ -z ${nvidia_gpu_hex_id} ]]; then
        print_header "Generate default xorg.conf"
        configure_x_server
    else
        print_header "Generate NVIDIA xorg.conf"
        configure_x_server
        configure_nvidia_x_server
    fi
fi

echo -e "\e[34mDONE\e[0m"
