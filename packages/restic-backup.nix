# Restic Backup Script
#
# Purpose: Automated Restic backup with cleanup and logging
#
# Features:
# - Automatic repository initialization
# - Comprehensive logging with timestamps
# - Configurable retention policy
# - Weekly integrity checks
# - Proper error handling
# - Fully configurable paths, excludes, and retention
#
# Usage:
# - Runs automatically via systemd timer
# - Manual execution: sudo restic-backup
# - Logs: journalctl -u restic-backup

{
  pkgs,
  # All configuration is provided by the calling module
  repositoryPath,
  backupPaths,
  excludePatterns,
  backupTag,
  keepDaily,
  keepWeekly,
  keepMonthly,
  enableWeeklyCheck,
  logDir,
  cacheDir,
}:

pkgs.writeShellApplication {
  name = "restic-backup";

  runtimeInputs = with pkgs; [
    restic
    coreutils
  ];

  text = ''
    set -euo pipefail

    export RESTIC_REPOSITORY="${repositoryPath}"
    export RESTIC_CACHE_DIR="${cacheDir}"

    # Logging setup
    LOG_DIR="${logDir}"
    LOG_FILE="$LOG_DIR/backup-$(date +%Y%m%d_%H%M%S).log"

    # Ensure log directory exists
    mkdir -p "$LOG_DIR"

    # Redirect all output to log file and console
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1

    echo "Starting Restic backup at $(date)"
    echo "Repository: $RESTIC_REPOSITORY"
    echo "Backup tag: ${backupTag}"
    echo "Backup paths: ${builtins.concatStringsSep " " backupPaths}"
    echo "Log file: $LOG_FILE"
    echo "----------------------------------------"

    # Initialize repository if it doesn't exist
    if ! restic snapshots >/dev/null 2>&1; then
      echo "Initializing Restic repository..."
      restic init
      echo "Repository initialized successfully"
    fi

    # Perform backup
    echo "Creating backup snapshot..."
    restic backup \
      --verbose \
      --tag "${backupTag}" \
      ${
        builtins.concatStringsSep " \\\n      " (map (pattern: ''--exclude="${pattern}"'') excludePatterns)
      } \
      ${builtins.concatStringsSep " \\\n      " (map (path: ''"${path}"'') backupPaths)}

    echo "Backup snapshot created successfully"

    # Cleanup old snapshots
    echo "Cleaning up old snapshots..."
    restic forget \
      --verbose \
      --tag "${backupTag}" \
      --keep-daily ${toString keepDaily} \
      --keep-weekly ${toString keepWeekly} \
      --keep-monthly ${toString keepMonthly} \
      --prune

    echo "Snapshot cleanup completed"

    ${
      if enableWeeklyCheck then
        ''
          # Weekly integrity check (run on Mondays)
          if [ "$(date +%u)" -eq "1" ]; then
            echo "Running weekly repository integrity check..."
            if restic check --verbose; then
              echo "Repository integrity check passed"
            else
              echo "WARNING: Repository integrity check failed!"
              exit 1
            fi
          fi
        ''
      else
        "# Weekly integrity check disabled"
    }

    echo "----------------------------------------"
    echo "Restic backup completed successfully at $(date)"
  '';
}
