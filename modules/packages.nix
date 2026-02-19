{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  environment.systemPackages =
    with pkgs;
    [
      # System packages
      rsync
      zfs
      fzf
      vim
      wget
      git
      jq
      nixfmt-rfc-style # For formatting nix files
      htop
      pre-commit
      oh-my-posh
      parted
      smartmontools
      hdparm
      restic
      podman-compose
      fuse-overlayfs # Required for rootless containers
      (python3.withPackages (
        ps: with ps; [
          pyyaml
          requests
        ]
      ))
    ]
    ++ [
      # Custom packages
      (pkgs.callPackage ../packages/sync-esp.nix { inherit secrets; })
      (pkgs.callPackage ../packages/nixos-rebuild-with-esp.nix { inherit secrets; })
      (pkgs.callPackage ../packages/system-generation-cleanup.nix { })
    ]
    ++ lib.optionals (secrets.diskIds ? bulkData) [
      # Bulk storage tier packages
      mergerfs # Union filesystem for HDDs
      snapraid # Parity protection for bulk storage
      # Storage management
      (pkgs.callPackage ../packages/storage-manager.nix { inherit secrets; })
    ];

  # Need this for vscode-server
  programs.nix-ld.enable = true;

  # Podman configuration
  virtualisation.containers.enable = true;
  virtualisation.containers.storage.settings = {
    storage = {
      driver = "zfs";
      runroot = "/containers/run/containers/storage";
      graphroot = "/containers/var/lib/containers/storage";
    };
  };
  virtualisation.containers.containersConf.settings = {
    containers = {
      log_driver = "k8s-file";
      log_size_max = 10485760; # 10MB in bytes
      log_rotate_max = 3; # Keep 3 log files
    };
  };
  virtualisation = {
    podman = {
      enable = true;
      # Required for containers under podman-compose to be able to talk to each other.
      defaultNetwork.settings.dns_enabled = true;
    };
  };
  systemd.user.sockets.podman = {
    enable = true;
    wantedBy = [ "sockets.target" ];
  };

  # User-level container storage configuration
  environment.etc."containers-user-storage-${secrets.username}.conf".text = ''
    [storage]
      driver = "overlay"
      runroot = "/containers/users/${secrets.username}/run"
      graphroot = "/containers/users/${secrets.username}/storage"

    [storage.options]
      mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
  '';
}
