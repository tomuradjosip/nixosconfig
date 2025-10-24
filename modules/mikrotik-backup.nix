{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

let
  backupConfig = {
    backupDir = "/bulk/mikrotik";
    routerIP = secrets.ipRouter;
    routerUser = "admin";
    retentionDays = 90;
    sshKeyPath = "/home/${secrets.username}/.ssh/${secrets.sshPrivateKeyFilename}";
  };

  mikrotikBackupPackage = pkgs.callPackage ../packages/mikrotik-backup.nix {
    backupDir = backupConfig.backupDir;
    routerIP = backupConfig.routerIP;
    routerUser = backupConfig.routerUser;
    retentionDays = backupConfig.retentionDays;
    sshKeyPath = backupConfig.sshKeyPath;
  };
in
{
  # Create backup directory with proper permissions
  systemd.tmpfiles.rules = [
    "d ${backupConfig.backupDir} 0700 ${secrets.username} users -"
  ];

  # Systemd service for MikroTik configuration backup
  systemd.services.mikrotik-backup = {
    description = "Export MikroTik RouterOS configuration backup";
    after = [
      "local-fs.target"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = secrets.username;
      Group = "users";
      ExecStart = "${mikrotikBackupPackage}/bin/mikrotik-backup";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ backupConfig.backupDir ];
      NoNewPrivileges = true;

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Systemd timer for weekly backups
  systemd.timers.mikrotik-backup = {
    description = "Weekly MikroTik backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true; # Run on next boot if missed
      RandomizedDelaySec = "1h"; # Add random delay up to 1 hour
    };
  };
}
