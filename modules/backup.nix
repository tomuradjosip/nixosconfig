{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

let
  #############################################################################
  # RESTIC BACKUP CONFIGURATION
  #
  # Customize these settings for your backup needs:
  # - backupPaths: What directories to backup
  # - excludePatterns: What files/patterns to skip
  # - Retention policy: How long to keep snapshots
  # - Logging and integrity check preferences
  #############################################################################

  backupConfig = {
    # Repository location
    repositoryPath = "/bulk/backup"; # Where to store backups

    # What to backup (add/remove paths as needed)
    backupPaths = [
      "/home/${secrets.username}/.ssh"
      "/etc/secrets"
      "/containers/homelab"
      "/bulk/mikrotik"
    ];

    # What to exclude from backups
    excludePatterns = [
      "*.tmp"
      "*.temp"
      "*/.cache/*"
      "*/node_modules/*"
      "*/.git/*"
    ];

    # Backup identification and retention
    backupTag = "nixos-scheduled";
    keepDaily = 10;
    keepWeekly = 10;
    keepMonthly = 24;

    # System preferences
    enableWeeklyCheck = true; # Run integrity checks on Mondays
    logDir = "/var/log/restic"; # Where to store backup logs
    cacheDir = "/var/lib/restic"; # Where to store Restic cache
  };

  resticBackupPackage = pkgs.callPackage ../packages/restic-backup.nix {
    repositoryPath = backupConfig.repositoryPath;
    backupPaths = backupConfig.backupPaths;
    excludePatterns = backupConfig.excludePatterns;
    backupTag = backupConfig.backupTag;
    keepDaily = backupConfig.keepDaily;
    keepWeekly = backupConfig.keepWeekly;
    keepMonthly = backupConfig.keepMonthly;
    enableWeeklyCheck = backupConfig.enableWeeklyCheck;
    logDir = backupConfig.logDir;
    cacheDir = backupConfig.cacheDir;
  };
in
{
  # Create directories for Restic backups
  systemd.tmpfiles.rules = [
    "d ${backupConfig.logDir} 0755 root root -"
    "d ${backupConfig.cacheDir} 0700 root root -"
  ];

  # Environment file for Restic password
  environment.etc."restic/environment" = {
    text = ''
      RESTIC_PASSWORD=${secrets.backupPassword}
    '';
    mode = "0600";
  };

  # Log rotation for backup logs
  services.logrotate.settings.restic = {
    files = "${backupConfig.logDir}/*.log";
    frequency = "weekly";
    rotate = 8; # Keep 8 weeks of logs
    compress = true;
    delaycompress = true;
    missingok = true;
    notifempty = true;
    create = "644 root root";
  };

  # Systemd service for Restic backup using the package
  systemd.services.restic-backup = {
    description = "Restic scheduled backup service";
    after = [ "local-fs.target" ]; # Wait for /bulk to be mounted
    conflicts = [
      "snapraid-sync.service"
      "snapraid-scrub.service"
    ]; # Prevent concurrent operations with SnapRAID
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${resticBackupPackage}/bin/restic-backup";
      EnvironmentFile = "/etc/restic/environment";
      User = "root";
      Group = "root";
      PrivateTmp = true;
      ProtectHome = "read-only";
      ProtectSystem = "strict";
      ReadWritePaths = [
        backupConfig.repositoryPath
        backupConfig.logDir
        backupConfig.cacheDir
      ];
    };
  };

  # Systemd timer for scheduled Restic backups
  systemd.timers.restic-backup = {
    description = "Daily Restic backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
