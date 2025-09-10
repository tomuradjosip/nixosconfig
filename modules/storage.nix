{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Systemd-boot EFI bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 5;

  # ZFS support with optional FUSE for mergerfs support
  boot.initrd.availableKernelModules = [ "zfs" ];
  boot.initrd.kernelModules = [ "zfs" ];
  boot.supportedFilesystems = [ "zfs" ] ++ lib.optionals (secrets.diskIds ? bulkData) [ "fuse" ];
  boot.zfs.devNodes = "/dev"; # TODO check if this is needed

  # Impermanence setup with stable device IDs
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    # Set ZFS mountpoints for OS pool
    zfs set mountpoint=legacy rpool/nix
    zfs set mountpoint=legacy rpool/persist

    # Import and mount OS ZFS pool
    zpool import -f rpool
    mount -t zfs rpool/nix /mnt-root/nix
    mount -t zfs rpool/persist /mnt-root/persist

    # Import data pool if available (optional for users without data drives)
    if zpool import -f dpool 2>/dev/null; then
      echo "Data pool (dpool) imported successfully"
    else
      echo "Data pool (dpool) not available - skipping"
    fi
  '';

  fileSystems = lib.mkMerge [
    # Base OS filesystems (defined above)
    {
      "/" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "mode=755" ];
      };

      "/nix" = {
        device = "rpool/nix";
        fsType = "zfs";
        neededForBoot = true;
      };

      "/persist" = {
        device = "rpool/persist";
        fsType = "zfs";
        neededForBoot = true;
      };
    }

    # Conditional data pool filesystems (Tier 2: NVMe)
    (lib.mkIf (secrets.diskIds ? dataPrimary && secrets.diskIds ? dataSecondary) {
      "/containers" = {
        device = "dpool/containers";
        fsType = "zfs";
      };

      "/data" = {
        device = "dpool/data";
        fsType = "zfs";
      };
    })

    # Conditional bulk storage filesystems (Tier 3: HDDs with MergerFS)
    (lib.mkIf (secrets.diskIds ? bulkData) {
      "/bulk" = {
        # Only include data disks (parity disk is separate)
        device = lib.concatStringsSep ":" (
          lib.imap (i: diskId: "/mnt/data${toString i}") secrets.diskIds.bulkData
        );
        fsType = "fuse.mergerfs";
        options = [
          "defaults"
          "allow_other"
          "use_ino"
          "cache.files=partial"
          "dropcacheonclose=true"
          "category.create=epmfs" # Existing path, most free space
        ];
      };
    })

    # Individual data disk mount points
    (lib.mkIf (secrets.diskIds ? bulkData) (
      lib.listToAttrs (
        lib.imap (i: diskId: {
          name = "/mnt/data${toString i}";
          value = {
            device = "/dev/disk/by-id/${diskId}-part1";
            fsType = "ext4";
            options = [ "defaults" ];
            noCheck = true;
          };
        }) secrets.diskIds.bulkData
      )
    ))

    # Parity disk mount point
    (lib.mkIf (secrets.diskIds ? bulkParity) {
      "/mnt/parity" = {
        device = "/dev/disk/by-id/${secrets.diskIds.bulkParity}-part1";
        fsType = "ext4";
        options = [ "defaults" ];
        noCheck = true;
      };
    })
  ];

  # Zram swap configuration
  zramSwap = {
    enable = true;
    algorithm = "lzo-rle";
    memoryMax = 2147483648; # 2GB in bytes
  };

  # Run ESP sync after system updates
  system.activationScripts.sync-esp = ''
    ${config.systemd.package}/bin/systemctl start sync-esp.service || true
  '';

  # Disk power management via udev rules
  services.udev.extraRules = ''
    # Set power management for HDDs (rotational drives) on device add
    SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", \
      RUN+="${pkgs.hdparm}/bin/hdparm -S 240 -B 127 /dev/%k"
  '';

  # System services (ESP sync, cleanup, and bulk storage)
  systemd.services = lib.mkMerge [
    # Base services (always present)
    {
      # ESP sync service for redundancy
      sync-esp = {
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

      # System generation cleanup service - more intelligent than nix-collect-garbage
      system-profile-cleanup = {
        description = "Intelligent system profile cleaner";
        startAt = "daily";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${
            pkgs.callPackage ../packages/system-generation-cleanup.nix { }
          }/bin/system-generation-cleanup";
        };
      };
    }

    # Bulk storage services (conditional)
    (lib.mkIf (secrets.diskIds ? bulkData) {
      # SnapRAID sync service
      "snapraid-sync" = {
        description = "SnapRAID sync operation";
        conflicts = [
          "restic-backup.service"
          "snapraid-scrub.service"
        ]; # Prevent concurrent operations with Restic backup and SnapRAID scrub
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.snapraid}/bin/snapraid sync";
        };
      };

      # SnapRAID scrub service
      "snapraid-scrub" = {
        description = "SnapRAID scrub operation";
        conflicts = [
          "restic-backup.service"
          "snapraid-sync.service"
        ]; # Prevent concurrent operations with Restic backup and SnapRAID sync
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.snapraid}/bin/snapraid scrub -p 10";
        };
      };
    })
  ];

  # SnapRAID configuration (conditional)
  environment.etc = lib.mkIf (secrets.diskIds ? bulkData && secrets.diskIds ? bulkParity) {
    "snapraid.conf".text = ''
      # SnapRAID configuration for ${toString (builtins.length secrets.diskIds.bulkData)} data disks + 1 parity disk

      # Parity file
      parity /mnt/parity/snapraid.parity

      # Data disks
      ${lib.concatImapStrings (
        i: diskId: "data d${toString i} /mnt/data${toString i}/\n"
      ) secrets.diskIds.bulkData}

      # Content files (system storage + parity disk)
      content /persist/snapraid.content
      content /mnt/parity/snapraid.content

      # Exclude patterns
      exclude *.tmp
      exclude *.temp
      exclude Thumbs.db
      exclude .DS_Store
      exclude *.!sync

      # Auto-save content file
      autosave 500
    '';
  };

  # Systemd timers (cleanup and SnapRAID maintenance)
  systemd.timers = lib.mkMerge [
    # Base timers (always present)
    {
      system-profile-cleanup.timerConfig.Persistent = true;
    }

    # Bulk storage timers (conditional)
    (lib.mkIf (secrets.diskIds ? bulkData) {
      "snapraid-sync" = {
        description = "Run SnapRAID sync daily";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "01:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };

      "snapraid-scrub" = {
        description = "Run SnapRAID scrub weekly";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "2h";
        };
      };
    })
  ];

  # ZFS services - include data pool if available
  services.zfs = {
    autoScrub.enable = true;
    autoScrub.pools = [
      "rpool"
    ]
    ++ lib.optionals (secrets.diskIds ? dataPrimary && secrets.diskIds ? dataSecondary) [ "dpool" ];
    autoScrub.interval = "daily";
    trim.enable = true;
    trim.interval = "weekly";
  };
}
