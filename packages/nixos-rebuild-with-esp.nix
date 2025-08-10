# NixOS Rebuild ESP Wrapper
#
# Purpose: Transparent wrapper for nixos-rebuild that handles ESP mounting automatically
#
# Features:
# - Drop-in replacement for standard nixos-rebuild command
# - Smart operation detection (only mounts ESP when needed)
# - Automatic ESP failover (primary → secondary)
# - Proper cleanup with trap handlers
# - All nixos-rebuild options supported
#
# Smart Operation Detection:
# - switch/test/boot: Mount ESP (bootloader operations)
# - build/dry-build/build-vm: Skip ESP (no bootloader changes)
# - Unknown operations: Mount ESP (safe default)
#
# Failover Logic:
# 1. Check if ESP already mounted (skip if so)
# 2. Try mounting primary ESP
# 3. Fall back to secondary ESP if primary fails
# 4. Abort if both ESPs unavailable
#
# Implementation Notes:
# - Uses ${pkgs.nixos-rebuild}/bin/nixos-rebuild to avoid circular dependency
# - exec replaces process cleanly rather than subprocess
# - Trap ensures cleanup even on interruption (Ctrl+C)
#
# Usage:
# Simply use as normal nixos-rebuild:
#   sudo nixos-rebuild switch --flake .#hostname
#   sudo nixos-rebuild test --flake .#hostname
#   nixos-rebuild build --flake .#hostname  # Won't mount ESP

{ pkgs, secrets }:

pkgs.writeShellApplication {
  name = "nixos-rebuild";

  runtimeInputs = with pkgs; [
    nixos-rebuild
    util-linux
    coreutils
  ];

  text = ''
    set -euo pipefail

    # Cleanup function - runs automatically on ANY script exit
    # Ensures ESP is unmounted even on errors or interruption
        cleanup() {
      echo "🧹 Unmounting anything mounted to /boot..."
      # Force unmount everything from /boot, including nested mounts
      # Safety: limit regular unmount attempts, then use lazy as final fallback
      local attempts=0
      local max_attempts=5

      while mountpoint -q /boot 2>/dev/null; do
        if [ $attempts -lt $max_attempts ]; then
          attempts=$((attempts + 1))
          echo "  Attempt $attempts: trying regular unmount..."
          if umount /boot 2>/dev/null; then
            echo "  Regular unmount successful"
          else
            echo "  Regular unmount failed"
          fi
        else
          # Final fallback: lazy unmount always succeeds
          echo "  Using lazy unmount as final fallback..."
          umount --lazy /boot 2>/dev/null
          echo "✅ /boot lazy unmount initiated"
          break
        fi
      done

      # Final check
      if ! mountpoint -q /boot 2>/dev/null; then
        echo "✅ /boot unmounted successfully"
      fi
    }
    trap cleanup EXIT

    # Determine if operation requires ESP mounting
    # Only bootloader operations need ESP access
    NEEDS_ESP=false
    case "''${1:-}" in
      switch|boot|test)
        # These operations modify bootloader
        NEEDS_ESP=true
        ;;
      build|dry-build|build-vm|build-vm-with-bootloader)
        # These operations don't touch bootloader
        NEEDS_ESP=false
        ;;
      *)
        # Unknown operation - err on side of caution
        NEEDS_ESP=true
        ;;
    esac

    # Mount ESP with failover if needed
    if [ "$NEEDS_ESP" = true ]; then
      echo "🔧 Mounting ESP for nixos-rebuild $1..."
      mkdir -p /boot

      if mountpoint -q /boot 2>/dev/null; then
        echo "✅ ESP already mounted"
      else
        # Try primary ESP first
        if mount -t vfat /dev/disk/by-id/${secrets.diskIds.primary}-part1 /boot 2>/dev/null; then
          echo "✅ Primary ESP mounted"
        # Fall back to secondary ESP
        elif mount -t vfat /dev/disk/by-id/${secrets.diskIds.secondary}-part1 /boot 2>/dev/null; then
          echo "✅ Secondary ESP mounted (failover)"
        else
          echo "❌ ERROR: Could not mount any ESP"
          exit 1
        fi
      fi
    fi

    # Execute real nixos-rebuild with all arguments
    # Run as subprocess so cleanup trap can execute afterward
    echo "🚀 Running nixos-rebuild $*"
    nixos-rebuild "$@"
  '';
}
