{
  description = "AI-Sec Inbound Lab — Laya + NOVA on NixOS (OrbStack), hybrid Metal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # ---- The lab machine: one rebuild stands up the whole runtime ----
      nixosConfigurations.aisec-lab = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./nixos/configuration.nix ];
      };

      # ---- The pinned participant toolchain (also used inside the VM) ----
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          kubectl
          kubernetes-helm
          opentofu          # terraform-compatible, MPL
          python312         # nbdev + laya + nova-hunting go in the venv below
          nodejs_22         # mermaid-cli, for diagram re-renders only
          jq
          yq
          git
          docker-compose
        ];
        shellHook = ''
          export PS1="(ai-sec-lab) $PS1"
          [ -d .venv ] || python3 -m venv .venv
          source .venv/bin/activate
          pip install -q nbdev "laya[serve]" "nova-hunting[semantic]" fastapi uvicorn httpx jupyterlab 2>/dev/null || true
          echo "tools: $(kubectl version --client -o name 2>/dev/null) | tofu $(tofu version 2>/dev/null | head -1)"
        '';
      };
    };
}