{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

let
  # Shared defaults for all routers
  commonDefaults = {
    routerUser = "admin";
    retentionDays = 90;
    sshKeyPath = "/home/${secrets.username}/.ssh/${secrets.sshPrivateKeyFilename}";
  };

  # Generate router configs from secrets.ipRouter
  # To add a new router, just add an entry to ipRouter in secrets.nix
  routers = lib.mapAttrs (name: ip: commonDefaults // {
    backupDir = "/bulk/mikrotik/${name}";
    routerIP = ip;
  }) secrets.mikrotikRouterIP;

  # Build a backup package for a specific router
  mkBackupPackage =
    name: cfg:
    pkgs.callPackage ../packages/mikrotik-backup.nix {
      routerName = name;
      inherit (cfg)
        backupDir
        routerIP
        routerUser
        retentionDays
        sshKeyPath
        ;
    };

  # Generate a systemd service for a router
  mkService = name: cfg: {
    name = "mikrotik-backup-${name}";
    value = {
      description = "Export MikroTik RouterOS configuration backup (${name})";
      after = [
        "local-fs.target"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = secrets.username;
        Group = "users";
        ExecStart = "${mkBackupPackage name cfg}/bin/mikrotik-backup-${name}";

        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.backupDir ];
        NoNewPrivileges = true;

        # Logging
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };

  # Generate a systemd timer for a router
  mkTimer = name: _cfg: {
    name = "mikrotik-backup-${name}";
    value = {
      description = "Weekly MikroTik backup timer (${name})";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };

  # Generate a tmpfiles rule for a router's backup directory
  mkTmpfilesRule = _name: cfg: "d ${cfg.backupDir} 0700 ${secrets.username} users -";
in
{
  # Create backup directories with proper permissions
  systemd.tmpfiles.rules = lib.mapAttrsToList mkTmpfilesRule routers;

  # Systemd services for MikroTik configuration backups
  systemd.services = builtins.listToAttrs (lib.mapAttrsToList mkService routers);

  # Systemd timers for weekly backups
  systemd.timers = builtins.listToAttrs (lib.mapAttrsToList mkTimer routers);
}
