{ pkgs, secrets }:

pkgs.writeShellApplication {
  name = "sync-esp";

  runtimeInputs = with pkgs; [
    util-linux
    rsync
  ];

  text = ''
    set -euo pipefail  # Exit on any error, undefined vars, or pipe failures

    ESP_BACKUP_DIR="/tmp/esp-backup"
    ESP_DEVICE="/dev/disk/by-id/${secrets.diskIds.secondary}-part1"

    # Cleanup function
    cleanup() {
      local exit_code=$?
      if mountpoint -q "$ESP_BACKUP_DIR" 2>/dev/null; then
        echo "Cleaning up: unmounting $ESP_BACKUP_DIR"
        umount "$ESP_BACKUP_DIR" || true
      fi
      if [ -d "$ESP_BACKUP_DIR" ]; then
        echo "Cleaning up: removing $ESP_BACKUP_DIR"
        rmdir "$ESP_BACKUP_DIR" || true
      fi
      exit $exit_code
    }

    # Set cleanup trap
    trap cleanup EXIT

    echo "Starting ESP sync process..."

    # Create temporary mount point
    echo "Creating mount point: $ESP_BACKUP_DIR"
    mkdir -p "$ESP_BACKUP_DIR"

    # Mount second ESP with error checking
    echo "Mounting backup ESP: $ESP_DEVICE"
    if ! mount "$ESP_DEVICE" "$ESP_BACKUP_DIR"; then
      echo "ERROR: Failed to mount backup ESP at $ESP_DEVICE"
      exit 1
    fi

    # Verify mount succeeded
    if ! mountpoint -q "$ESP_BACKUP_DIR"; then
      echo "ERROR: Mount verification failed for $ESP_BACKUP_DIR"
      exit 1
    fi

    echo "Successfully mounted backup ESP"

    # Sync contents from primary to backup ESP
    echo "Syncing ESP contents from /boot/ to $ESP_BACKUP_DIR/"
    if ! rsync -av --delete /boot/ "$ESP_BACKUP_DIR/"; then
      echo "ERROR: rsync failed"
      exit 1
    fi

    echo "ESP sync completed successfully"

    # Unmount (cleanup function will handle this, but do it explicitly too)
    echo "Unmounting backup ESP"
    if ! umount "$ESP_BACKUP_DIR"; then
      echo "WARNING: Failed to unmount $ESP_BACKUP_DIR"
      # Don't exit here, let cleanup handle it
    fi

    echo "Removing mount point"
    rmdir "$ESP_BACKUP_DIR"

    echo "ESP sync process completed successfully"
  '';
}
