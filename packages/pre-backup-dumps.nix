# Pre-Backup Database Dump Script
#
# Purpose: Create consistent database dumps before Restic backup
#
# Supports two database types:
# - SQLite: Uses sqlite3 .backup command for consistent copies
# - PostgreSQL: Uses pg_dump via podman exec into containers
#
# Configuration is data-driven — add entries to sqliteDumps or
# postgresDumps lists in backup.nix, no script editing needed.
#
# Usage:
# - Runs automatically as ExecStartPre for restic-backup service
# - Manual execution: sudo pre-backup-dumps

{
  pkgs,
  sqliteDumps ? [ ],
  postgresDumps ? [ ],
}:

let
  # Generate sqlite3 dump commands
  # Each entry: { name, path }
  # Dumps to <path>.backup
  sqliteDumpCommands = builtins.concatStringsSep "\n" (
    map (
      db: ''
        echo "Dumping SQLite database: ${db.name}"
        if [ -f "${db.path}" ]; then
          sqlite3 "${db.path}" ".backup '${db.path}.backup'"
          echo "  -> ${db.path}.backup created successfully"
        else
          echo "  WARNING: Database file ${db.path} not found, skipping"
        fi
      ''
    ) sqliteDumps
  );

  # Generate pg_dump commands via podman exec
  # Each entry: { name, container, user, database, outputPath }
  postgresDumpCommands = builtins.concatStringsSep "\n" (
    map (
      db: ''
        echo "Dumping PostgreSQL database: ${db.name}"
        if podman container exists "${db.container}" 2>/dev/null && \
           [ "$(podman inspect -f '{{.State.Status}}' "${db.container}" 2>/dev/null)" = "running" ]; then
          podman exec "${db.container}" \
            pg_dump -U "${db.user}" -d "${db.database}" --clean --if-exists \
            > "${db.outputPath}"
          echo "  -> ${db.outputPath} created successfully"
        else
          echo "  WARNING: Container ${db.container} is not running, skipping"
        fi
      ''
    ) postgresDumps
  );

  hasSqlite = sqliteDumps != [ ];
  hasPostgres = postgresDumps != [ ];
in

pkgs.writeShellApplication {
  name = "pre-backup-dumps";

  runtimeInputs =
    with pkgs;
    [ coreutils ]
    ++ lib.optionals hasSqlite [ sqlite ]
    ++ lib.optionals hasPostgres [ podman ];

  text = ''
    set -euo pipefail

    echo "Starting pre-backup database dumps at $(date)"
    echo "----------------------------------------"

    ${if hasSqlite then sqliteDumpCommands else "# No SQLite dumps configured"}

    ${if hasPostgres then postgresDumpCommands else "# No PostgreSQL dumps configured"}

    echo "----------------------------------------"
    echo "Pre-backup database dumps completed at $(date)"
  '';
}
