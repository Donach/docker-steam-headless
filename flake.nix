{
  description = "Build environment for the Steam-Headless docker image (AMD GPU fork)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));

      # Everything required to build the OCI image from the Dockerfiles.
      # The docker daemon itself is provided by the host (the NixOS runner);
      # the flake pins the client tooling so the build env is reproducible.
      buildTools = pkgs: with pkgs; [
        docker-client
        docker-buildx
        qemu
        git
        bash
        coreutils
        gnused
        gawk
      ];

      # Wrap `docker buildx build` for a given Dockerfile flavour.
      # Overridable via env: IMAGE, TAG, PLATFORM, PUSH (true -> --push, else --load).
      mkBuildApp = pkgs: flavour:
        pkgs.writeShellApplication {
          name = "build-${flavour}";
          runtimeInputs = buildTools pkgs;
          text = ''
            flavour="${flavour}"
            image="''${IMAGE:-steam-headless}"
            tag="''${TAG:-amd-fix-''${flavour}}"
            platform="''${PLATFORM:-linux/amd64}"

            echo "Building ''${image}:''${tag} from Dockerfile.''${flavour} (''${platform})"

            args=(
              build
              --file "Dockerfile.''${flavour}"
              --platform "''${platform}"
              --tag "''${image}:''${tag}"
              --pull
            )
            if [ "''${PUSH:-false}" = "true" ]; then
              args+=(--push)
            else
              args+=(--load)
            fi
            exec docker buildx "''${args[@]}" .
          '';
        };
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = buildTools pkgs;
          shellHook = ''
            echo "steam-headless build env ready. Run: docker buildx build -f Dockerfile.debian ."
          '';
        };
      });

      packages = forAllSystems (pkgs: {
        build-debian = mkBuildApp pkgs "debian";
        build-arch = mkBuildApp pkgs "arch";
        default = mkBuildApp pkgs "debian";
      });

      apps = forAllSystems (pkgs: {
        build-debian = {
          type = "app";
          program = "${mkBuildApp pkgs "debian"}/bin/build-debian";
        };
        build-arch = {
          type = "app";
          program = "${mkBuildApp pkgs "arch"}/bin/build-arch";
        };
        default = {
          type = "app";
          program = "${mkBuildApp pkgs "debian"}/bin/build-debian";
        };
      });
    };
}
