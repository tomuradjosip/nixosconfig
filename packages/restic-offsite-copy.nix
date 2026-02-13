# Restic Offsite Copy Script
#
# Purpose: Copy local Restic snapshots to a remote Hetzner Storage Box
#
# Features:
# - Copies new snapshots from local to remote repo via SFTP
# - Automatic remote repository initialization
# - Configurable retention policy for remote repo
# - Comprehensive logging with timestamps
# - Proper error handling
#
# Usage:
# - Runs automatically after restic-backup via OnSuccess chaining
# - Manual execution: sudo restic-offsite-copy
# - Logs: journalctl -u restic-offsite-copy

{
  pkgs,
  # All configuration is provided by the calling module
  localRepositoryPath,
  remoteRepositoryPath,
  sshPort,
  sshUser,
  sshHost,
  backupTag,
  keepDaily,
  keepWeekly,
  keepMonthly,
  logDir,
  cacheDir,
}:

pkgs.writeShellApplication {
  name = "restic-offsite-copy";

  runtimeInputs = with pkgs; [
    restic
    openssh
    coreutils
  ];

  text = ''
    set -euo pipefail

    LOCAL_REPO="${localRepositoryPath}"
    REMOTE_REPO="${remoteRepositoryPath}"
    export RESTIC_CACHE_DIR="${cacheDir}"

    # restic copy needs the password for both repos
    # RESTIC_PASSWORD is set via EnvironmentFile for the destination repo
    # RESTIC_FROM_PASSWORD is needed for the source (local) repo — same password
    export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"

    # Logging setup
    LOG_DIR="${logDir}"
    LOG_FILE="$LOG_DIR/offsite-$(date +%Y%m%d_%H%M%S).log"

    # Ensure log directory exists
    mkdir -p "$LOG_DIR"

    # Redirect all output to log file and console
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1

    # Full SFTP command for Hetzner Storage Box (port ${toString sshPort})
    # sftp.command replaces restic's default SSH invocation entirely,
    # so it must include the destination and -s sftp subsystem flag
    SFTP_CMD="ssh ${sshUser}@${sshHost} -p ${toString sshPort} -o StrictHostKeyChecking=accept-new -o BatchMode=yes -s sftp"

    echo "Starting offsite copy at $(date)"
    echo "Local repo: $LOCAL_REPO"
    echo "Remote repo: $REMOTE_REPO"
    echo "Log file: $LOG_FILE"
    echo "----------------------------------------"

    # Initialize remote repository if it doesn't exist
    if ! restic -r "$REMOTE_REPO" -o sftp.command="$SFTP_CMD" snapshots >/dev/null 2>&1; then
      echo "Initializing remote Restic repository..."
      restic -r "$REMOTE_REPO" -o sftp.command="$SFTP_CMD" init
      echo "Remote repository initialized successfully"
    fi

    # Copy only the latest snapshot from local to remote
    echo "Copying latest snapshot to remote repository..."
    restic copy \
      --verbose \
      --from-repo "$LOCAL_REPO" \
      --repo "$REMOTE_REPO" \
      -o sftp.command="$SFTP_CMD" \
      --tag "${backupTag}" \
      latest

    echo "Snapshot copy completed successfully"

    # Remove any stale locks from interrupted runs
    restic -r "$REMOTE_REPO" -o sftp.command="$SFTP_CMD" unlock --remove-all 2>/dev/null || true

    # Cleanup old snapshots on remote
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
    echo "Offsite copy completed successfully at $(date)"
  '';
}
