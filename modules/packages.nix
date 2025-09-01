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
      vim
      wget
      git
      nixfmt-rfc-style # For formatting nix files
      htop
      pre-commit
      oh-my-posh
      parted
      smartmontools
      hdparm
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

  # Docker configuration
  virtualisation.docker = {
    enable = true;
    storageDriver = "zfs";
    extraOptions = "--data-root=/containers/var/lib/docker";
  };
}
