# Restic Media Backup Script
#
# Purpose: Back up media files directly to a remote Hetzner Storage Box
#
# Features:
# - Backs up directly to remote repo (no local repo)
# - Automatic remote repository initialization
# - Configurable retention policy
# - Comprehensive logging with timestamps
# - Proper error handling
#
# Usage:
# - Runs automatically via systemd timer
# - Manual execution: sudo restic-media-backup
# - Logs: journalctl -u restic-media-backup

{
  pkgs,
  # All configuration is provided by the calling module
  remoteRepositoryPath,
  sshPort,
  sshUser,
  sshHost,
  backupPaths,
  excludePatterns,
  backupTag,
  keepDaily,
  keepWeekly,
  keepMonthly,
  logDir,
  cacheDir,
}:

pkgs.writeShellApplication {
  name = "restic-media-backup";

  runtimeInputs = with pkgs; [
    restic
    openssh
    coreutils
  ];

  text = ''
    set -euo pipefail

    REMOTE_REPO="${remoteRepositoryPath}"
    export RESTIC_CACHE_DIR="${cacheDir}"

    # Full SFTP command for Hetzner Storage Box (port ${toString sshPort})
    SFTP_CMD="ssh ${sshUser}@${sshHost} -p ${toString sshPort} -o StrictHostKeyChecking=accept-new -o BatchMode=yes -s sftp"

    # Logging setup
    LOG_DIR="${logDir}"
    LOG_FILE="$LOG_DIR/media-$(date +%Y%m%d_%H%M%S).log"

    # Ensure log directory exists
    mkdir -p "$LOG_DIR"

    # Redirect all output to log file and console
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1

    echo "Starting media backup at $(date)"
    echo "Remote repo: $REMOTE_REPO"
    echo "Backup tag: ${backupTag}"
    echo "Backup paths: ${builtins.concatStringsSep " " backupPaths}"
    echo "Log file: $LOG_FILE"
    echo "----------------------------------------"

    # Initialize remote repository if it doesn't exist
    if ! restic -r "$REMOTE_REPO" -o sftp.command="$SFTP_CMD" snapshots >/dev/null 2>&1; then
      echo "Initializing remote Restic repository..."
      restic -r "$REMOTE_REPO" -o sftp.command="$SFTP_CMD" init
      echo "Remote repository initialized successfully"
    fi

    # Perform backup directly to remote repo
    echo "Creating backup snapshot..."
    restic backup \
      --verbose \
      --repo "$REMOTE_REPO" \
      -o sftp.command="$SFTP_CMD" \
      --tag "${backupTag}" \
      ${
        builtins.concatStringsSep " \\\n      " (map (pattern: ''--exclude="${pattern}"'') excludePatterns)
      } \
      ${builtins.concatStringsSep " \\\n      " (map (path: ''"${path}"'') backupPaths)}

    echo "Backup snapshot created successfully"

    # Remove any stale locks from interrupted runs
    restic -r "$REMOTE_REPO" -o sftp.command="$SFTP_CMD" unlock --remove-all 2>/dev/null || true

    # Cleanup old snapshots
    echo "Cleaning up old remote snapshots..."
    restic -r "$REMOTE_REPO" -o sftp.command="$SFTP_CMD" forget \
      --verbose \
      --tag "${backupTag}" \
      --keep-daily ${toString keepDaily} \
      --keep-weekly ${toString keepWeekly} \
      --keep-monthly ${toString keepMonthly} \
      --prune

    echo "Remote snapshot cleanup completed"

    echo "----------------------------------------"
    echo "Media backup completed successfully at $(date)"
  '';
}
