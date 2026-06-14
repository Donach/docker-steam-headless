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
        git
        bash
        coreutils
        gnused
        gawk
        gzip
        curl
      ];

      # Wrap `docker build` (BuildKit) for a given Dockerfile flavour.
      # Plain `docker build` is used instead of `docker buildx`: the image is
      # single-arch (linux/amd64) and loaded into the local daemon, so the
      # buildx plugin (which nixpkgs ships as a separate, non-auto-registered
      # binary) is not needed. Only the host docker socket is required.
      # Overridable via env: IMAGE, TAG, PLATFORM, PUSH (true -> docker push).
      mkBuildApp = pkgs: flavour:
        pkgs.writeShellApplication {
          name = "build-${flavour}";
          runtimeInputs = buildTools pkgs;
          text = ''
            export DOCKER_BUILDKIT=1
            flavour="${flavour}"
            image="''${IMAGE:-steam-headless}"
            tag="''${TAG:-amd-fix-''${flavour}}"
            platform="''${PLATFORM:-linux/amd64}"

            echo "Building ''${image}:''${tag} from Dockerfile.''${flavour} (''${platform})"

            docker build \
              --file "Dockerfile.''${flavour}" \
              --platform "''${platform}" \
              --tag "''${image}:''${tag}" \
              --pull \
              .

            if [ "''${PUSH:-false}" = "true" ]; then
              docker push "''${image}:''${tag}"
            fi
          '';
        };

      # `docker save` the locally-built image and upload it as a Forgejo generic
      # package. Used by the CI because the Forgejo container registry sits under
      # the /donach subpath, which the Docker registry protocol cannot address.
      # All inputs come from the environment (set by the workflow):
      #   IMAGE TAG FLAVOUR FORGEJO_BASE PKG_OWNER PKG_NAME PKG_VERSION FORGEJO_TOKEN
      mkPublishApp = pkgs:
        pkgs.writeShellApplication {
          name = "publish-image";
          runtimeInputs = with pkgs; [ docker-client gzip curl coreutils ];
          text = ''
            image="''${IMAGE:?}"
            tag="''${TAG:?}"
            flavour="''${FLAVOUR:?}"
            base="''${FORGEJO_BASE:?}"
            owner="''${PKG_OWNER:?}"
            pkg="''${PKG_NAME:?}"
            version="''${PKG_VERSION:?}"
            token="''${FORGEJO_TOKEN:?}"

            file="''${pkg}-''${flavour}.tar.gz"
            url="''${base}/api/packages/''${owner}/generic/''${pkg}/''${version}/''${file}"

            echo "Saving ''${image}:''${tag} -> ''${file}"
            docker save "''${image}:''${tag}" | gzip > "''${file}"
            ls -lh "''${file}"

            # Overwrite any previous upload of this version/filename (idempotent re-runs)
            curl -sS -X DELETE -H "Authorization: token ''${token}" "''${url}" || true
            curl -sS -f -X PUT --upload-file "''${file}" -H "Authorization: token ''${token}" "''${url}"
            echo "Published: ''${url}"
          '';
        };
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = buildTools pkgs;
          shellHook = ''
            echo "steam-headless build env ready. Run: nix run .#build-debian (or docker build -f Dockerfile.debian .)"
          '';
        };
      });

      packages = forAllSystems (pkgs: {
        build-debian = mkBuildApp pkgs "debian";
        build-arch = mkBuildApp pkgs "arch";
        publish = mkPublishApp pkgs;
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
        publish = {
          type = "app";
          program = "${mkPublishApp pkgs}/bin/publish-image";
        };
        default = {
          type = "app";
          program = "${mkBuildApp pkgs "debian"}/bin/build-debian";
        };
      });
    };
}
