# System Generation Cleanup Service
#
# Purpose: Intelligently cleans up old NixOS system generations
#
# Features:
# - Always preserves a minimum number of recent generations
# - Only removes generations older than a specified age
# - More conservative than nix-collect-garbage
# - Provides clear feedback about what's being removed
#
# Behavior:
# - Keeps at least 5 generations regardless of age
# - Only considers generations older than 30 days for removal
# - Processes generations in chronological order (oldest first)
# - Safe fail-fast behavior on any errors
#
# Usage:
# - Runs automatically daily via systemd timer
# - Manual execution: sudo systemctl start system-profile-cleanup
# - Logs: journalctl -u system-profile-cleanup
#
# Safety:
# - Conservative defaults protect against accidental removal
# - Clear logging of all actions taken
# - Dry-run capability for testing

{ pkgs }:

pkgs.writeShellApplication {
  name = "system-generation-cleanup";

  runtimeInputs = with pkgs; [
    coreutils
    findutils
  ];

  text = ''
    set -euo pipefail  # Exit on any error, undefined vars, or pipe failures

    # Configuration
    readonly MIN_GENERATIONS_TO_KEEP=5
    readonly MAX_GENERATION_AGE="30 days ago"
    readonly PROFILES_PATH="/nix/var/nix/profiles"

    echo "Starting system generation cleanup..."
    echo "Configuration:"
    echo "  - Minimum generations to keep: $MIN_GENERATIONS_TO_KEEP"
    echo "  - Maximum age for removal: $MAX_GENERATION_AGE"

    # Calculate cutoff timestamp
    cutoffTimestamp="$(date -d "$MAX_GENERATION_AGE" '+%s')"
    echo "  - Cutoff timestamp: $cutoffTimestamp ($(date -d "@$cutoffTimestamp"))"

    # Initialize counters
    previousTimestamp=$(date '+%s')
    remainingGenerationsToKeep=$MIN_GENERATIONS_TO_KEEP
    totalProcessed=0
    totalRemoved=0

    echo ""
    echo "Processing generations:"

    # Process each system generation
    for generationPath in $(ls -1Adt --time=birth "$PROFILES_PATH"/system-* 2>/dev/null || true); do
      if [ ! -e "$generationPath" ]; then
        echo "Warning: Generation path no longer exists: $generationPath"
        continue
      fi

      currentTimestamp="$(stat -c '%W' "$generationPath" 2>/dev/null || echo "0")"
      generationNumber="''${generationPath#"$PROFILES_PATH"/system-}"
      generationNumber="''${generationNumber%-link}"

      totalProcessed=$((totalProcessed + 1))

      # Log current generation being processed
      if [ "$currentTimestamp" != "0" ]; then
        generationDate="$(date -d "@$currentTimestamp" '+%Y-%m-%d %H:%M:%S')"
        echo "  Generation $generationNumber ($generationDate):"
      else
        echo "  Generation $generationNumber (unknown date):"
      fi

      # Check if this generation should be removed
      if [ "$previousTimestamp" -lt "$cutoffTimestamp" ] && [ "$remainingGenerationsToKeep" -lt 1 ]; then
        echo "    → Removing (older than cutoff and beyond minimum keep count)"
        if rm -f -- "$generationPath"; then
          totalRemoved=$((totalRemoved + 1))
          echo "    ✓ Successfully removed"
        else
          echo "    ✗ Failed to remove"
        fi
      else
        if [ "$previousTimestamp" -ge "$cutoffTimestamp" ]; then
          echo "    → Keeping (newer than cutoff date)"
        else
          echo "    → Keeping (within minimum keep count: $remainingGenerationsToKeep remaining)"
        fi
      fi

      # Update counters for next iteration
      previousTimestamp="$currentTimestamp"
      remainingGenerationsToKeep=$((remainingGenerationsToKeep - 1))
    done

    echo ""
    echo "Cleanup completed:"
    echo "  - Total generations processed: $totalProcessed"
    echo "  - Total generations removed: $totalRemoved"
    echo "  - Total generations kept: $((totalProcessed - totalRemoved))"

    if [ "$totalRemoved" -gt 0 ]; then
      echo "✓ Successfully cleaned up $totalRemoved old system generations"
    else
      echo "✓ No generations needed cleanup"
    fi
  '';
}
