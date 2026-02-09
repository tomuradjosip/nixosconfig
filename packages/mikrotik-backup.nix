# MikroTik Backup Script
#
# Purpose: Export MikroTik RouterOS configuration with all secrets
#
# Features:
# - Full configuration export with secrets (.rsc)
# - Binary backup for complete system restoration (.backup)
# - Automatic backup directory creation
# - Timestamped backup files
# - Automatic cleanup of old backups
# - Proper error handling and logging
# - Multi-router support via per-device instances
#
# Usage:
# - Runs via systemd service (e.g. mikrotik-backup-main)
# - Manual execution: systemctl start mikrotik-backup-<name>
# - Logs: journalctl -u mikrotik-backup-<name>

{
  pkgs,
  # Configuration provided by the calling module
  routerName,
  backupDir,
  routerIP,
  routerUser,
  retentionDays,
  sshKeyPath,
}:

pkgs.writeShellApplication {
  name = "mikrotik-backup-${routerName}";

  runtimeInputs = with pkgs; [
    openssh
    coreutils
    findutils
  ];

  text = ''
    set -euo pipefail

    ROUTER_NAME="${routerName}"
    BACKUP_DIR="${backupDir}"
    ROUTER_IP="${routerIP}"
    ROUTER_USER="${routerUser}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_NAME="config_$TIMESTAMP"
    EXPORT_FILE="$BACKUP_DIR/$BACKUP_NAME.rsc"
    BINARY_FILE="$BACKUP_DIR/$BACKUP_NAME.backup"
    TEMP_EXPORT="$BACKUP_DIR/.$BACKUP_NAME.rsc.tmp"
    TEMP_BINARY="$BACKUP_DIR/.$BACKUP_NAME.backup.tmp"

    echo "Starting MikroTik backup for '$ROUTER_NAME' at $(date)"
    echo "Router: $ROUTER_USER@$ROUTER_IP"
    echo "Export file: $EXPORT_FILE"
    echo "Binary file: $BINARY_FILE"

    # 1. Export configuration with all secrets to temporary file
    echo "[$ROUTER_NAME] Creating text export..."
    ssh \
      -i "${sshKeyPath}" \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      "$ROUTER_USER@$ROUTER_IP" \
      "/export verbose show-sensitive" > "$TEMP_EXPORT"

    # Only move to final location if SSH succeeded and file is not empty
    if [ -s "$TEMP_EXPORT" ]; then
      mv "$TEMP_EXPORT" "$EXPORT_FILE"
      chmod 600 "$EXPORT_FILE"
      EXPORT_SIZE=$(stat -c %s "$EXPORT_FILE")
      echo "[$ROUTER_NAME] Text export completed: $EXPORT_FILE ($EXPORT_SIZE bytes)"
    else
      echo "[$ROUTER_NAME] Error: Export file is empty or SSH failed"
      rm -f "$TEMP_EXPORT"
      exit 1
    fi

    # 2. Create binary backup on router and download it
    echo "[$ROUTER_NAME] Creating binary backup..."
    REMOTE_BACKUP_NAME="backup_$TIMESTAMP"

    # Create backup on router (unencrypted for easier restoration)
    ssh \
      -i "${sshKeyPath}" \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      "$ROUTER_USER@$ROUTER_IP" \
      "/system backup save name=$REMOTE_BACKUP_NAME dont-encrypt=yes"

    # Download the backup file
    scp \
      -i "${sshKeyPath}" \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      "$ROUTER_USER@$ROUTER_IP:$REMOTE_BACKUP_NAME.backup" \
      "$TEMP_BINARY"

    # Remove backup from router to save space
    ssh \
      -i "${sshKeyPath}" \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      "$ROUTER_USER@$ROUTER_IP" \
      "/file remove $REMOTE_BACKUP_NAME.backup"

    # Move binary backup to final location
    if [ -s "$TEMP_BINARY" ]; then
      mv "$TEMP_BINARY" "$BINARY_FILE"
      chmod 600 "$BINARY_FILE"
      BINARY_SIZE=$(stat -c %s "$BINARY_FILE")
      echo "[$ROUTER_NAME] Binary backup completed: $BINARY_FILE ($BINARY_SIZE bytes)"
    else
      echo "[$ROUTER_NAME] Warning: Binary backup file is empty or download failed"
      rm -f "$TEMP_BINARY"
    fi

    # Keep only last N days of backups
    echo "[$ROUTER_NAME] Cleaning up old backups (keeping last ${toString retentionDays} days)..."
    find "$BACKUP_DIR" -name "config_*.rsc" -type f -mtime +${toString retentionDays} -delete
    find "$BACKUP_DIR" -name "config_*.backup" -type f -mtime +${toString retentionDays} -delete

    # List current backups (last 10)
    echo "[$ROUTER_NAME] Current backups:"
    find "$BACKUP_DIR" -name "config_*" -type f -printf "%TY-%Tm-%Td %TH:%TM %s %p\n" | sort -rn | head -n 10 || true

    echo "MikroTik backup for '$ROUTER_NAME' completed at $(date)"
  '';
}
