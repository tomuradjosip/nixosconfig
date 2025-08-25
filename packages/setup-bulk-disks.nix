# Bulk Storage Disk Setup
#
# Purpose: Initialize and mount individual HDDs for MergerFS + SnapRAID
#
# Features:
# - Automatic disk detection and formatting
# - Graceful handling of missing/failed disks
# - Directory structure creation
# - Proper ownership and permissions
# - Idempotent operations (safe to run multiple times)
#
# Usage:
# - Runs automatically via systemd service
# - Manual execution: setup-bulk-disks

{
  pkgs,
  lib,
  secrets,
  ...
}:

pkgs.writeShellApplication {
  name = "setup-bulk-disks";

  runtimeInputs = with pkgs; [
    util-linux # for blkid, mount, mountpoint
    e2fsprogs # for mkfs.ext4
    coreutils # for mkdir, chown, etc
  ];

  text = ''
        set -euo pipefail

        # Configuration from secrets
        DATA_DISK_IDS=(${lib.concatStringsSep " " (map (id: ''"${id}"'') secrets.diskIds.bulkData)})
        PARITY_DISK_ID="${secrets.diskIds.bulkParity}"
        DIRECTORIES=(${
          lib.concatStringsSep " " (map (dir: ''"${dir}"'') secrets.bulkStorageDirectories)
        })
        USERNAME="${secrets.username}"

        log() {
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
        }

        setup_data_disk() {
          local disk_id="$1"
          local disk_number="$2"
          local disk_path="/dev/disk/by-id/$disk_id"
          local mount_path="/mnt/data$disk_number"

          log "Setting up data disk $disk_number: $disk_id"

          # Check if disk exists
          if [[ ! -e "$disk_path" ]]; then
            log "WARNING: Data disk not found: $disk_path"
            return 0
          fi

          # Create mount point
          mkdir -p "$mount_path"

          # Format if needed
          if ! blkid "$disk_path" >/dev/null 2>&1; then
            log "Formatting $disk_path with ext4..."
            mkfs.ext4 -F "$disk_path"
          fi

          # Mount if not already mounted
          if ! mountpoint -q "$mount_path" 2>/dev/null; then
            log "Mounting $disk_path to $mount_path"
            mount "$disk_path" "$mount_path"
          fi

          # Create user directories
          for dir in "''${DIRECTORIES[@]}"; do
            local dir_path="$mount_path/$dir"
            if [[ ! -d "$dir_path" ]]; then
              log "Creating directory: $dir_path"
              mkdir -p "$dir_path"
              chown "$USERNAME:users" "$dir_path"
            fi
          done

          log "Data disk $disk_number setup completed"
        }

        setup_parity_disk() {
          local disk_id="$1"
          local disk_path="/dev/disk/by-id/$disk_id"
          local mount_path="/mnt/parity"

          log "Setting up parity disk: $disk_id"

          # Check if disk exists
          if [[ ! -e "$disk_path" ]]; then
            log "WARNING: Parity disk not found: $disk_path"
            return 0
          fi

          # Create mount point
          mkdir -p "$mount_path"

          # Format if needed
          if ! blkid "$disk_path" >/dev/null 2>&1; then
            log "Formatting $disk_path with ext4..."
            mkfs.ext4 -F "$disk_path"
          fi

          # Mount if not already mounted
          if ! mountpoint -q "$mount_path" 2>/dev/null; then
            log "Mounting $disk_path to $mount_path"
            mount "$disk_path" "$mount_path"
          fi

          # Create warning file
          local warning_file="$mount_path/WARNING-PARITY-DISK.txt"
          if [[ ! -f "$warning_file" ]]; then
            cat > "$warning_file" << 'EOF'
    ⚠️  PARITY DISK - DO NOT STORE USER DATA HERE ⚠️

    This disk contains SnapRAID parity data only.
    User data should go in /bulk (which excludes this disk).
    EOF
            chmod 444 "$warning_file"
            log "Created parity disk warning"
          fi

          log "Parity disk setup completed"
        }

        main() {
          log "Setting up bulk storage: ''${#DATA_DISK_IDS[@]} data disks + 1 parity disk"

          # Setup data disks
          local disk_number=1
          for disk_id in "''${DATA_DISK_IDS[@]}"; do
            setup_data_disk "$disk_id" "$disk_number"
            ((disk_number++))
          done

          # Setup parity disk
          setup_parity_disk "$PARITY_DISK_ID"

          log "All bulk storage disks ready"
        }

        main "$@"
  '';
}
