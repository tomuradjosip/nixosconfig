# Bulk Storage Manager
#
# Purpose: Manage MergerFS + SnapRAID bulk storage tier
#
# Features:
# - Check storage health across all tiers
# - Manual SnapRAID operations
# - Disk usage reporting
# - Maintenance scheduling
#
# Usage:
# - bulk-storage status    # Show overall storage status
# - bulk-storage sync      # Manual SnapRAID sync
# - bulk-storage scrub     # Manual SnapRAID scrub
# - bulk-storage check     # Check array integrity
# - bulk-storage fix       # Fix detected errors
# - bulk-storage usage     # Show detailed storage usage

{ pkgs, secrets }:

pkgs.writeShellApplication {
  name = "bulk-storage";

  runtimeInputs = with pkgs; [
    snapraid
    mergerfs
    util-linux
    coreutils
    gawk
  ];

  text = ''
    set -euo pipefail

    # Check if bulk storage is configured
    if ! [ -d "/bulk" ]; then
      echo "❌ Bulk storage not configured or not mounted"
      exit 1
    fi

    case "''${1:-status}" in
      "status")
        echo "🏗️  Three-Tier Storage Status"
        echo "================================"
        echo

        echo "📊 Tier 1: OS/Apps (ZFS Mirror - SSDs)"
        zpool status rpool | head -20
        echo

        if zpool status dpool >/dev/null 2>&1; then
          echo "🚀 Tier 2: Hot Data (ZFS Mirror - NVMe)"
          zpool status dpool | head -20
          echo
        fi

        echo "📦 Tier 3: Bulk Storage (MergerFS + SnapRAID - HDDs)"
        echo "MergerFS Status:"
        df -h /bulk
        echo
        echo "Individual Disks:"
        df -h /mnt/disk* 2>/dev/null || echo "No individual disks mounted"
        echo
        echo "SnapRAID Status:"
        if [ -f /etc/snapraid.conf ]; then
          snapraid status 2>/dev/null || echo "Run 'bulk-storage sync' first"
        else
          echo "SnapRAID not configured"
        fi
        ;;

      "sync")
        echo "🔄 Running SnapRAID sync..."
        snapraid sync
        echo "✅ SnapRAID sync completed"
        ;;

      "scrub")
        echo "🔍 Running SnapRAID scrub..."
        snapraid scrub -p 10
        echo "✅ SnapRAID scrub completed"
        ;;

      "check")
        echo "🔍 Checking array integrity..."
        snapraid check
        ;;

      "fix")
        echo "🔧 Attempting to fix detected errors..."
        read -p "This will modify data. Are you sure? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
          snapraid fix
        else
          echo "❌ Operation cancelled"
        fi
        ;;

      "usage")
        echo "📊 Storage Usage Report"
        echo "======================"
        echo
        echo "Tier 1 (OS/Apps):"
        zfs list rpool
        echo
        if zpool status dpool >/dev/null 2>&1; then
          echo "Tier 2 (Hot Data):"
          zfs list dpool
          echo
        fi
        echo "Tier 3 (Bulk Storage):"
        df -h /bulk /mnt/disk* 2>/dev/null
        ;;

      *)
        echo "Bulk Storage Manager"
        echo "==================="
        echo
        echo "Usage: bulk-storage <command>"
        echo
        echo "Commands:"
        echo "  status  - Show storage status across all tiers"
        echo "  sync    - Run SnapRAID sync (updates parity)"
        echo "  scrub   - Run SnapRAID scrub (verify data integrity)"
        echo "  check   - Check array for errors"
        echo "  fix     - Fix detected errors (interactive)"
        echo "  usage   - Show detailed storage usage"
        echo
        echo "Examples:"
        echo "  bulk-storage status"
        echo "  bulk-storage sync"
        echo "  bulk-storage usage"
        ;;
    esac
  '';
}
