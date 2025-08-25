# ESP Synchronization Service
#
# Purpose: Keeps both ESP partitions synchronized with intelligent failover handling
#
# Features:
# - Automatic ESP detection and mounting
# - Bidirectional sync logic based on availability
# - Robust error handling for disk failures
# - Clean resource management with automatic cleanup
#
# Behavior:
# - Both ESPs available: sync primary → secondary
# - Only one ESP available: skip sync gracefully
# - No ESPs available: exit cleanly
#
# Usage:
# - Runs automatically after nixos-rebuild via systemd service
# - Manual execution: sudo systemctl start sync-esp
# - Logs: journalctl -u sync-esp
#
# Error Handling:
# - Uses trap for guaranteed cleanup on any exit
# - Provides clear feedback about ESP status
# - Gracefully handles partial disk failures
# - Never leaves temporary mounts

{ pkgs, secrets }:

pkgs.writeShellApplication {
  name = "sync-esp";

  runtimeInputs = with pkgs; [
    util-linux
    rsync
  ];

  text = ''
    set -euo pipefail  # Exit on any error, undefined vars, or pipe failures

    PRIMARY_ESP="/dev/disk/by-id/${secrets.diskIds.osPrimary}-part1"
    SECONDARY_ESP="/dev/disk/by-id/${secrets.diskIds.osSecondary}-part1"

    PRIMARY_MOUNT="/tmp/esp-primary"
    SECONDARY_MOUNT="/tmp/esp-secondary"

    # Cleanup function - runs automatically on ANY script exit
    # shellcheck disable=SC2317  # Called by trap
    cleanup() {
      local exit_code=$?
      echo "Cleanup: Starting cleanup process..."

      # Unmount primary ESP if mounted
      if mountpoint -q "$PRIMARY_MOUNT" 2>/dev/null; then
        echo "Cleanup: Unmounting primary ESP"
        umount "$PRIMARY_MOUNT" || echo "Warning: Failed to unmount primary ESP"
      fi

      # Unmount secondary ESP if mounted
      if mountpoint -q "$SECONDARY_MOUNT" 2>/dev/null; then
        echo "Cleanup: Unmounting secondary ESP"
        umount "$SECONDARY_MOUNT" || echo "Warning: Failed to unmount secondary ESP"
      fi

      # Remove mount directories
      if [ -d "$PRIMARY_MOUNT" ]; then
        rmdir "$PRIMARY_MOUNT" 2>/dev/null || true
      fi
      if [ -d "$SECONDARY_MOUNT" ]; then
        rmdir "$SECONDARY_MOUNT" 2>/dev/null || true
      fi

      echo "Cleanup: Complete"
      exit "$exit_code"
    }

    # Set cleanup trap - this runs cleanup() on ANY exit
    trap cleanup EXIT

    echo "Starting ESP sync process..."

    # Create mount points
    echo "Creating mount points..."
    mkdir -p "$PRIMARY_MOUNT" "$SECONDARY_MOUNT"

    # Try to mount both ESPs
    PRIMARY_MOUNTED=false
    SECONDARY_MOUNTED=false

    # Mount primary ESP
    if [ -e "$PRIMARY_ESP" ]; then
      echo "Attempting to mount primary ESP: $PRIMARY_ESP"
      if mount -t vfat "$PRIMARY_ESP" "$PRIMARY_MOUNT" 2>/dev/null; then
        echo "✓ Primary ESP mounted successfully"
        PRIMARY_MOUNTED=true
      else
        echo "✗ Failed to mount primary ESP"
      fi
    else
      echo "✗ Primary ESP device not found: $PRIMARY_ESP"
    fi

    # Mount secondary ESP
    if [ -e "$SECONDARY_ESP" ]; then
      echo "Attempting to mount secondary ESP: $SECONDARY_ESP"
      if mount -t vfat "$SECONDARY_ESP" "$SECONDARY_MOUNT" 2>/dev/null; then
        echo "✓ Secondary ESP mounted successfully"
        SECONDARY_MOUNTED=true
      else
        echo "✗ Failed to mount secondary ESP"
      fi
    else
      echo "✗ Secondary ESP device not found: $SECONDARY_ESP"
    fi

    # Determine action based on what's available and handle errors
    if [ "$PRIMARY_MOUNTED" = true ] && [ "$SECONDARY_MOUNTED" = true ]; then
      echo "Both ESPs available - syncing primary to secondary"
      if rsync -av --delete "$PRIMARY_MOUNT/" "$SECONDARY_MOUNT/"; then
        echo "✓ ESP sync completed successfully"
        exit 0  # SUCCESS - the only case that should exit 0
      else
        echo "✗ ERROR: rsync failed during ESP synchronization"
        exit 1  # ERROR
      fi
    elif [ "$PRIMARY_MOUNTED" = true ] && [ "$SECONDARY_MOUNTED" = false ]; then
      echo "✗ ERROR: Only primary ESP available - cannot sync to secondary"
      exit 2  # ERROR - secondary not available
    elif [ "$PRIMARY_MOUNTED" = false ] && [ "$SECONDARY_MOUNTED" = true ]; then
      echo "✗ ERROR: Only secondary ESP available - cannot sync from primary"
      exit 3  # ERROR - primary not available
    else
      echo "✗ ERROR: No ESPs available - both devices failed to mount"
      exit 4  # ERROR - both ESPs failed
    fi
  '';
}
