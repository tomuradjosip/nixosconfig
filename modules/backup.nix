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
      "/home/${secrets.username}/nixosconfig"
      "/etc/secrets"
      "/containers/homelab"
      "/bulk/mikrotik"
      "/var/lib/AdGuardHome"
      "/var/lib/samba"
    ];

    # What to exclude from backups
    excludePatterns = [
      # General temp/dev files
      "*.tmp"
      "*.temp"
      "*/cache/*"
      "*/.cache/*"
      "*/node_modules/*"
      "*/.git/*"

      # SQLite WAL/journal files (we have proper .backup dumps)
      "*-shm"
      "*-wal"

      # Application logs (not useful for restore)
      "*/logs/*"
      "*/log/*"
      "*/logs.db"
      "*.pid"

      # Prowlarr bundled indexer definitions (regenerated on update)
      "*/prowlarr/Definitions/*"

      # Profilarr TRaSH Guide data (synced/regenerated, not user config)
      "*/profilarr/db/*"

      # Crash telemetry
      "*/Sentry/*"

      # Cached media artwork (re-fetched from metadata providers)
      "*/MediaCover/*"

      # Vaultwarden favicon cache (regenerated automatically)
      "*/icon_cache/*"

      # GeoIP databases (re-downloaded)
      "*/GeoDB/*"

      # Jellyfin cached metadata/artwork (re-fetched from TMDB/TVDB)
      "*/jellyfin/config/metadata/*"

      # AdGuard Home downloaded filter lists (refreshed automatically)
      "*/AdGuardHome/data/filters/*"
      "*/AdGuardHome/data/querylog.json"
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

    #############################################################################
    # OFFSITE BACKUP TO HETZNER STORAGE BOX
    #
    # After the local backup succeeds, snapshots are copied to a remote Restic
    # repo on a Hetzner Storage Box via SFTP. Same password as local repo.
    #############################################################################

    offsite = {
      repositoryPath = "sftp:${secrets.storageBoxUser}@${secrets.storageBoxUser}.your-storagebox.de:./restic-repo";
      sshPort = 23; # Hetzner Storage Box uses port 23
      keepDaily = 7;
      keepWeekly = 4;
      keepMonthly = 12;
    };

    #############################################################################
    # PRE-BACKUP DATABASE DUMPS
    #
    # Databases need consistent dumps before Restic snapshots them.
    # Add entries here when new services with databases are added.
    # Dump files are written alongside the source DB and picked up by Restic.
    #############################################################################

    # SQLite databases: { name, path }
    # Dumps to <path>.backup using sqlite3 .backup command
    sqliteDumps = [
      {
        name = "vaultwarden";
        path = "/containers/homelab/appdata/vaultwarden/data/db.sqlite3";
      }
      {
        name = "vikunja";
        path = "/containers/homelab/appdata/vikunja/vikunja.db";
      }
    ];

    # PostgreSQL databases: { name, container, user, database, outputPath }
    # Dumps via podman exec using pg_dump
    postgresDumps = [
      # Uncomment when Immich is re-enabled:
      # {
      #   name = "immich";
      #   container = "immich-postgres";
      #   user = "postgres";
      #   database = "immich";
      #   outputPath = "/containers/homelab/appdata/immich/backups/pg_dump.sql";
      # }
    ];
  };

  #############################################################################
  # MEDIA BACKUP CONFIGURATION
  #
  # Backs up media files directly to a separate Restic repo on Hetzner.
  # No local repo — uploads directly over SFTP.
  #############################################################################

  mediaBackupConfig = {
    repositoryPath = "sftp:${secrets.storageBoxUser}@${secrets.storageBoxUser}.your-storagebox.de:./restic-media";
    sshPort = 23;

    # What to backup (add/remove paths as needed)
    backupPaths = [
      "/bulk/Elements"
    ];

    excludePatterns = [
      "*.tmp"
      "*.temp"
    ];

    backupTag = "media-scheduled";
    keepDaily = 7;
    keepWeekly = 4;
    keepMonthly = 6;
  };

  resticMediaBackupPackage = pkgs.callPackage ../packages/restic-media-backup.nix {
    remoteRepositoryPath = mediaBackupConfig.repositoryPath;
    sshPort = mediaBackupConfig.sshPort;
    sshUser = secrets.storageBoxUser;
    sshHost = "${secrets.storageBoxUser}.your-storagebox.de";
    backupPaths = mediaBackupConfig.backupPaths;
    excludePatterns = mediaBackupConfig.excludePatterns;
    backupTag = mediaBackupConfig.backupTag;
    keepDaily = mediaBackupConfig.keepDaily;
    keepWeekly = mediaBackupConfig.keepWeekly;
    keepMonthly = mediaBackupConfig.keepMonthly;
    logDir = backupConfig.logDir;
    cacheDir = backupConfig.cacheDir;
  };

  preBackupDumpsPackage = pkgs.callPackage ../packages/pre-backup-dumps.nix {
    sqliteDumps = backupConfig.sqliteDumps;
    postgresDumps = backupConfig.postgresDumps;
  };

  resticOffsiteCopyPackage = pkgs.callPackage ../packages/restic-offsite-copy.nix {
    localRepositoryPath = backupConfig.repositoryPath;
    remoteRepositoryPath = backupConfig.offsite.repositoryPath;
    sshPort = backupConfig.offsite.sshPort;
    sshUser = secrets.storageBoxUser;
    sshHost = "${secrets.storageBoxUser}.your-storagebox.de";
    backupTag = backupConfig.backupTag;
    keepDaily = backupConfig.offsite.keepDaily;
    keepWeekly = backupConfig.offsite.keepWeekly;
    keepMonthly = backupConfig.offsite.keepMonthly;
    logDir = backupConfig.logDir;
    cacheDir = backupConfig.cacheDir;
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
    unitConfig = {
      OnSuccess = "restic-offsite-copy.service"; # Chain offsite copy on success
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${preBackupDumpsPackage}/bin/pre-backup-dumps";
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
      ]
      # Allow writing dump files next to source databases
      ++ map (db: builtins.dirOf db.path) backupConfig.sqliteDumps
      ++ map (db: builtins.dirOf db.outputPath) backupConfig.postgresDumps;
    };
  };

  # Systemd service for offsite copy (chained from restic-backup via OnSuccess)
  systemd.services.restic-offsite-copy = {
    description = "Copy Restic snapshots to Hetzner Storage Box";
    unitConfig = {
      OnSuccess = "restic-media-backup.service"; # Chain media backup on success
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${resticOffsiteCopyPackage}/bin/restic-offsite-copy";
      EnvironmentFile = "/etc/restic/environment";
      User = "root";
      Group = "root";
      PrivateTmp = true;
      ProtectHome = "read-only";
      ProtectSystem = "strict";
      ReadWritePaths = [
        backupConfig.repositoryPath # Local repo (restic copy needs to write lock files)
        backupConfig.logDir
        backupConfig.cacheDir
        "/root/.ssh" # SSH known_hosts for Hetzner Storage Box
      ];
    };
  };

  # Systemd service for media backup (chained from restic-offsite-copy; conflicts on restic-backup prevent SnapRAID overlap)
  systemd.services.restic-media-backup = {
    description = "Restic media backup to Hetzner Storage Box";
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${resticMediaBackupPackage}/bin/restic-media-backup";
      EnvironmentFile = "/etc/restic/environment";
      User = "root";
      Group = "root";
      PrivateTmp = true;
      ProtectHome = "read-only";
      ProtectSystem = "strict";
      ReadWritePaths = [
        backupConfig.logDir
        backupConfig.cacheDir
        "/root/.ssh"
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
