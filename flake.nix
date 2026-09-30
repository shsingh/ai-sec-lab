{
  description = "AI Security using FOSS tools with Macbook Pro — Laya + NOVA on NixOS (OrbStack), hybrid Metal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The uv.lock -> Nix stack: devShells and container images are
    # materialised from the same hash-verbatim dependency contract.
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, pyproject-nix, uv2nix, pyproject-build-systems, flake-utils }:
    let
      # aarch64-darwin: ad-hoc dev shell on the Mac (wheels resolve darwin-
      # variants from the same lock); x86_64-linux: GitHub-hosted runners;
      # aarch64-linux: the OrbStack lab VM. Container images are exposed
      # on linux systems only — Nix builds the platform that ships.
      supportedSystems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
    in
    (flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = nixpkgs.lib;

        # ---- Participant toolchain from the one uv.lock ------------------
        # pyproject.toml is the dependency contract (Renovate-bumped,
        # contract-test-gated); uv2nix materialises its exact contents for
        # shells AND images — no pip install at shell-enter time, no PyPI
        # drift between dev and what the gate actually serves.
        workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

        python = pkgs.python314;
        pythonBase = pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        };

        pythonSet = pythonBase.overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            # config (extra-build-dependencies) comes from pyproject.toml's
            # [tool.uv.extra-build-dependencies] via loadWorkspace.
            (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
          ]
        );

        # The reproducible venv: nbdev + laya[serve] + nova-hunting[semantic]
        # + fastapi/uvicorn/httpx + torch + jupyterlab (the [notebooks]
        # extra), exactly as locked. Container images use deps.default —
        # same contract, slim closure.
        labVirtualenv = pythonSet.mkVirtualEnv "ai-sec-lab-venv" workspace.deps.all;

        # ---- Container image definitions (linux only — the shippers) ------
        # Images materialise the deps.default set from the SAME uv.lock —
        # devShell venv carries the [notebooks] extra (jupyterlab), images
        # stay slim. One shared import; `packages`/`apps` reference it.
        imgs = lib.optionalAttrs (system != "aarch64-darwin") (import ./nix/images.nix {
          inherit pkgs lib pythonSet;
          workspaceDeps = workspace.deps;
          gateAppSrc = ./gate/app.py;
          victimAppSrc = ./gate/victim_app.py;
          rulesDir = ./nova-rules;
        });
      in
      {
        # ---- The pinned participant toolchain (portable: CI + VM) --------
        # Pure shell: every binary pinned, the venv built from uv.lock.
        # No network on entry, no .venv on disk. `jupyter lab` still comes
        # from the same venv (jupyterlab is a dep in pyproject.toml).
        devShells.default = pkgs.mkShell {
          packages = [
            labVirtualenv
            pkgs.uv
            pkgs.kubectl
            pkgs.kubernetes-helm
            pkgs.opentofu          # terraform-compatible, MPL
            pkgs.nodejs_22         # mermaid-cli, for diagram re-renders only
            pkgs.jq
            pkgs.yq
            pkgs.git
            pkgs.docker-compose
          ];
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = "${python.interpreter}";
            UV_PYTHON_DOWNLOADS = "never";
          };
          shellHook = ''
            export PS1="(ai-sec-lab) $PS1"
            unset PYTHONPATH
            echo "tools: $(kubectl version --client -o name 2>/dev/null) | tofu $(tofu version 2>/dev/null | head -1) | py $(python --version 2>&1)"
          '';
        };

        packages = imgs;

        # ---- Image runners + pinned OpenTofu -----------------------------
        # nix run .#load-gate   → stream the gate image into docker (or k3s ctr)
        # nix run .#tofu plan   → pinned tofu from the same flake; provider
        #                         hashes locked in terraform/.terraform.lock.hcl
        apps = lib.optionalAttrs (system != "aarch64-darwin") (let
          loadImage = name: img: let
            exe = pkgs.writers.writeBash "load-${name}" ''
              #!/usr/bin/env bash
              set -euo pipefail
              if command -v docker >/dev/null 2>&1; then
                ${img} | docker load
              elif command -v k3s >/dev/null 2>&1; then
                echo "no docker; streaming into k3s containerd (ctr needs root)" >&2
                ${img} | sudo k3s ctr images import -
              else
                echo "no docker/k3s found. Pipe the image manually:" >&2
                echo "  nix run .#${name}-image > ${name}.tar" >&2
                echo "  docker load < ${name}.tar   # or: sudo k3s ctr images import ${name}.tar" >&2
                exit 1
              fi
            '';
          in { type = "app"; program = toString exe; };
        in {
          gate-image = { type = "app"; program = "${imgs.gate-image}"; };
          victim-image = { type = "app"; program = "${imgs.victim-image}"; };
          load-gate = loadImage "gate" imgs.gate-image;
          load-victim = loadImage "victim" imgs.victim-image;
          tofu = { type = "app"; program = toString (pkgs.writers.writeBash "tofu" ''
            #!/usr/bin/env bash
            set -euo pipefail
            top="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
            exec ${pkgs.opentofu}/bin/tofu -chdir="$top/terraform" "$@"
          ''); };
          tofu-init = { type = "app"; program = toString (pkgs.writers.writeBash "tofu-init" ''
            #!/usr/bin/env bash
            set -euo pipefail
            top="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
            exec ${pkgs.opentofu}/bin/tofu -chdir="$top/terraform" init -reconfigure
          ''); };
        });
      }))
    // {
      # ---- The lab machine: one rebuild stands up the whole runtime ----
      # aarch64 = the OrbStack VM; not per-system.
      nixosConfigurations.aisec-lab = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [ ./nixos/configuration.nix ];
      };
    };
}
