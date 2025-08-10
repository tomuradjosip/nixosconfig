{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Modern EFI bootloader - much simpler than GRUB
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 5;

  # ZFS configuration
  boot.initrd.availableKernelModules = [ "zfs" ];
  boot.initrd.kernelModules = [ "zfs" ];
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.devNodes = "/dev";

  # Impermanence setup with stable device IDs
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    # Set ZFS mountpoints
    zfs set mountpoint=legacy rpool/nix
    zfs set mountpoint=legacy rpool/persist

    # Import and mount ZFS pool (true mirror)
    zpool import -f rpool
    mount -t zfs rpool/nix /mnt-root/nix
    mount -t zfs rpool/persist /mnt-root/persist
  '';

  # Filesystem configuration
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=755" ];
  };

  fileSystems."/nix" = {
    device = "rpool/nix";
    fsType = "zfs";
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "rpool/persist";
    fsType = "zfs";
    neededForBoot = true;
  };

  # ESP sync service for redundancy
  systemd.services.sync-esp = {
    description = "Sync ESP partitions for redundancy";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Add capabilities needed for mounting
      AmbientCapabilities = [ "CAP_SYS_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_SYS_ADMIN" ];
      ExecStart = "${pkgs.callPackage ../packages/sync-esp.nix { inherit secrets; }}/bin/sync-esp";
    };
  };

  # Run ESP sync after system updates
  system.activationScripts.sync-esp = ''
    ${config.systemd.package}/bin/systemctl start sync-esp.service || true
  '';

  # ZFS services
  services.zfs = {
    autoScrub.enable = true;
    autoScrub.pools = [ "rpool" ];
  };
}
