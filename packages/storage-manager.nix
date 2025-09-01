# Storage Manager
#
# Purpose: Monitor storage health and usage across all tiers

{ pkgs, secrets }:

pkgs.writeShellApplication {
  name = "storage";

  runtimeInputs = with pkgs; [
    snapraid
    mergerfs
    util-linux
    coreutils
    gawk
    smartmontools
  ];

  text = ''
    set -euo pipefail

    # Check if bulk storage is configured
    if ! [ -d "/bulk" ]; then
      echo "❌ Bulk storage not configured or not mounted"
      exit 1
    fi

    echo "🏗️  Three-Tier Storage Status & Usage"
    echo "======================================"
    echo

    echo "📊 Tier 1: OS/Apps (ZFS Mirror - SSDs)"
    echo "Status:"
    zpool status rpool | head -20
    echo
    echo "Usage:"
    zfs list rpool
    echo

    if zpool status dpool >/dev/null 2>&1; then
      echo "🚀 Tier 2: Hot Data (ZFS Mirror - NVMe)"
      echo "Status:"
      zpool status dpool | head -20
      echo
      echo "Usage:"
      zfs list dpool
      echo
    fi

    echo "📦 Tier 3: Bulk Storage (MergerFS + SnapRAID - HDDs)"
    echo "MergerFS Status:"
    df -h /bulk || echo "No mergerfs mounted"
    echo
    echo "Individual Disks:"
    df -h /mnt/data* || echo "No individual disks mounted"
    echo
    echo "SnapRAID Status:"
    if [ -f /etc/snapraid.conf ]; then
      snapraid status || echo "Run SnapRAID sync manually if needed"
    else
      echo "SnapRAID not configured"
    fi
    echo

    echo "🔍 SMART Data Summary"
    echo "===================="
    echo

    # Get all physical disks
    for disk in $(lsblk -dno NAME | grep -E '^(sd|nvme|hd)' | sort); do
        if smartctl -i "/dev/$disk" >/dev/null 2>&1; then

            echo "💾 /dev/$disk"

        # Show disk ID if it matches ata or nvme criteria
        disk_id=""
        if [ -d "/dev/disk/by-id" ]; then
            for id_link in /dev/disk/by-id/*; do
                if [ -L "$id_link" ] && [ "$(readlink -f "$id_link")" = "/dev/$disk" ]; then
                    candidate_id=$(basename "$id_link")
                    # Check if disk ID contains ata or nvme (but not nvme-eui)
                    if [[ "$candidate_id" == ata* ]] || { [[ "$candidate_id" == nvme* ]] && [[ "$candidate_id" != nvme-eui* ]]; }; then
                        disk_id="$candidate_id"
                        break
                    fi
                fi
            done
        fi

        if [ -n "$disk_id" ]; then
            echo "Disk ID: $disk_id"
        fi

        echo
        echo "Summary:"
        smartctl -i "/dev/$disk" | grep -E '^(Device Model|Product|Serial Number):' || true
        smartctl -H "/dev/$disk" | grep -E '^SMART overall-health' || true

        # Show temperature if available
        # Try NVMe format first: "Temperature: 32 Celsius"
        temp=$(smartctl -a "/dev/$disk" | grep "^Temperature:" | awk '{print $2}' || true)
        if [ -z "$temp" ] || [ "$temp" = "-" ]; then
            # Try SATA format: attribute 194 Temperature_Celsius
            temp=$(smartctl -a "/dev/$disk" | grep "194 Temperature_Celsius" | awk '{print $10}' || true)
        fi
        if [ -n "$temp" ] && [ "$temp" != "-" ]; then
            echo "Temperature: ''${temp}°C"
        fi

        # Show power cycles if available
        # Try NVMe format first: "Power Cycles: 22"
        cycles=$(smartctl -a "/dev/$disk" | grep "^Power Cycles:" | awk '{print $3}' || true)
        if [ -z "$cycles" ] || [ "$cycles" = "-" ]; then
            # Try SATA format: attribute 12 Power_Cycle_Count
            cycles=$(smartctl -a "/dev/$disk" | grep "12 Power_Cycle_Count" | awk '{print $10}' || true)
        fi
        if [ -n "$cycles" ] && [ "$cycles" != "-" ]; then
            echo "Power Cycles: ''${cycles}"
        fi

        # Show power-on hours if available
        # Try NVMe format first: "Power On Hours: 757"
        hours=$(smartctl -a "/dev/$disk" | grep "^Power On Hours:" | awk '{print $4}' || true)
        if [ -z "$hours" ] || [ "$hours" = "-" ]; then
            # Try SATA format: attribute 9 Power_On_Hours
            hours=$(smartctl -a "/dev/$disk" | grep "9 Power_On_Hours" | awk '{print $10}' || true)
        fi
        if [ -n "$hours" ] && [ "$hours" != "-" ]; then
            echo "Power-on Hours: ''${hours}"
        fi

        echo "========================================"
        echo
        fi
    done

  '';
}
