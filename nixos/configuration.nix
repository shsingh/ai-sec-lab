# AI Security using FOSS tools with Macbook Pro — the NixOS lab machine, declared.
# One `nixos-rebuild switch --flake .#aisec-lab` stands up:
#   k3s (single node) + docker + the lab toolchain + shell env.
# No shell scripts: everything here is declarative.

{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------
  # 0. Machine identity (matches the OrbStack machine name)
  # ---------------------------------------------------------------
  networking.hostName = "aisec-lab";

  # OrbStack shares the Mac home into the VM; clone the repo anywhere under it.
  # Nothing to configure for that — but the lab user needs the docker group.

  # ---------------------------------------------------------------
  # 1. Users
  # ---------------------------------------------------------------
  users.users.lab = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    # Passwordless sudo for the lab (it's a disposable OrbStack VM):
    initialPassword = "aisec";
  };

  # ---------------------------------------------------------------
  # 2. Services
  # ---------------------------------------------------------------

  # Docker daemon: REMOVED. Images are built by Nix (flake packages
  # .#gate-image/.#victim-image) and streamed straight into k3s's containerd:
  #   nix run .#load-victim     # docker path (OrbStack) or k3s ctr fallback
  # k3s runs containerd natively, so no docker daemon is needed anywhere in
  # the runtime path. docker-compose stays available in the devShell for
  # anyone following the compose quickstart.

  # k3s: the declarative single-node cluster (replaces OrbStack's K8s toggle).
  services.k3s = {
    enable = true;
    role = "server";
    # No traefik: the edge is NGINX Gateway Fabric. No local storage provisioner
    # needs: the lab mounts ConfigMaps only.
    extraFlags = toString [
      "--disable=traefik"
      "--disable=servicelb"      # edge access is NodePort + hosts entries, not LB emulation
      # widen the NodePort range so NGF's edge can be pinned to port 80
      # (kubernetes default is 30000-32767; the lab uses http://ai-sec.lab.internal bare)
      "--kube-apiserver-arg=service-node-port-range=80-32767"
    ];
  };

  # The notebooks (and a Mac browser via OrbStack's port-forward) reach the
  # edge as http://ai-sec.lab.internal — the name maps to 127.0.0.1 and NGF
  # is pinned to NodePort 80 (see terraform/main.tf edge comments).
  networking.extraHosts = ''
    127.0.0.1 ai-sec.lab.internal
  '';

  # SSH (OrbStack provides its own; keep OpenSSH for completeness)
  services.openssh.enable = true;

  # ---------------------------------------------------------------
  # 3. The lab toolchain — system-wide so every shell has it
  # ---------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    opentofu
    # NOTE: no python here on purpose — the toolchain (and its venv) comes
    # exclusively from the flake's devShell, which is the same closure that
    # builds the images. A bare python312 system package invites ad-hoc
    # pip installs outside the uv.lock contract.
    git
    jq
    yq
    curl
    vim
    htop
    docker-compose
  ];

  # KUBECONFIG: point kubectl at the k3s admin config for every user shell.
  environment.variables = {
    KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  };

  # ---------------------------------------------------------------
  # 4. Nix itself
  # ---------------------------------------------------------------
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "root" "lab" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # ---------------------------------------------------------------
  # 5. Base OS bits
  # ---------------------------------------------------------------
  # OrbStack guest: the machine is booted by OrbStack's own loader, not a
  # real disk. Declare a nominal root filesystem and keep grub off so the
  # NixOS bootability assertions don't fire on a container-style guest.
  fileSystems."/" = {
    device = "/dev/orbstack-root";
    fsType = "ext4";
  };
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;

  time.timeZone = "Australia/Brisbane";
  system.stateVersion = "24.11";
}
