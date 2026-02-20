# Backrest: Web UI for browsing and restoring restic repositories.
# Repos are defined in secrets.backrestRepos (id, uri, password, guid). The user
# must obtain guid manually via `restic -r <uri> cat config --json` (use the "id" field).
# /etc/backrest is persisted so UI auth (users) is preserved across reboot; an activation
# script merges instance and repos from Nix into existing config without wiping auth.

{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

let
  repos = secrets.backrestRepos or [ ];
  instance = secrets.hostname;

  repoToJson = repo: {
    id = repo.id;
    uri = repo.uri;
    guid = repo.guid;
    env = [ "RESTIC_PASSWORD_FILE=/etc/restic/backrest-password-${repo.id}" ];
  };

  # Seed file: instance + repos from Nix. Activation script merges this into
  # existing config.json (if any) so we never wipe auth/users.
  reposFromNix = builtins.toJSON {
    modno = 0;
    version = 6;
    inherit instance;
    repos = map repoToJson repos;
  };

  mergeScript = pkgs.writeShellScript "backrest-merge-config" ''
    set -euo pipefail
    SEED="/etc/backrest/repos-from-nix.json"
    CONFIG="/etc/backrest/config.json"
    export PATH="${lib.makeBinPath [ pkgs.jq ]}:$PATH"

    if [ -f "$CONFIG" ]; then
      # Merge: keep existing auth etc., overwrite only modno, version, instance, repos
      # (.[0] | . + ...) would make . = config so .[1] fails; keep . as array
      jq -s '(.[0]) + {modno: 0, version: 6, instance: .[1].instance, repos: .[1].repos}' "$CONFIG" "$SEED" > "$CONFIG.tmp"
      chmod 600 "$CONFIG.tmp"
      mv "$CONFIG.tmp" "$CONFIG"
    else
      # First run: copy seed as initial config (no auth yet)
      cp "$SEED" "$CONFIG"
      chmod 600 "$CONFIG"
    fi
  '';
in
{
  # Per-repo password files (from secrets.backrestRepos)
  environment.etc = lib.mkMerge (
    (map (repo: {
      "restic/backrest-password-${repo.id}" = {
        text = repo.password;
        mode = "0600";
      };
    }) repos)
    ++ [
      {
        "backrest/repos-from-nix.json" = {
          text = reposFromNix;
          mode = "0600";
        };
      }
    ]
  );

  system.activationScripts.backrestConfig = {
    deps = [ "etc" ];
    text = ''
      ${mergeScript}
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/backrest 0755 root root -"
    "d /var/lib/backrest/cache 0755 root root -"
  ];

  systemd.services.backrest = {
    description = "Backrest – Web UI for restic repositories";
    after = [
      "network.target"
      "local-fs.target"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      Environment = [
        "BACKREST_CONFIG=/etc/backrest/config.json"
        "BACKREST_DATA=/var/lib/backrest"
        "BACKREST_PORT=0.0.0.0:9898"
        "HOME=/var/lib/backrest"
        "XDG_CACHE_HOME=/var/lib/backrest/cache"
        "PATH=${
          lib.makeBinPath [
            pkgs.restic
            pkgs.openssh
          ]
        }:/usr/bin:/bin"
      ];
    };

    path = [
      pkgs.restic
      pkgs.openssh
    ];

    script = ''
      exec ${lib.getExe pkgs.backrest}
    '';
  };
}
