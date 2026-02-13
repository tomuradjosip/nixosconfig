# Backrest: Web UI for browsing and restoring restic repositories.
# Repos are added programmatically from the config below; passwords come from
# password files (no secrets in the generated config).

{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

let
  # Single password file for all repos (contents: secrets.backupPassword from secrets.nix).
  passwordFile = "/etc/restic/backrest-password";

  # Repos to show in Backrest UI. All use the same password (secrets.backupPassword).
  # URI can be local path or sftp:user@host:/path (SFTP needs ssh in PATH; Hetzner uses port 23 in ~/.ssh/config).
  #
  # For existing repos you must set `guid` to the restic repository ID. Get it with:
  #   RESTIC_PASSWORD_FILE=/etc/restic/backrest-password restic -r <uri> cat config --json
  # then use the "id" field as guid. For new (not yet initialized) repos use autoInitialize = true instead.
  repos = [
    {
      id = "nixos-server";
      uri = "/bulk/backup/nixos-server";
      guid = "f050eb4e5f1b75383ae0a607dcd0b6eb41a8e2461d2c64dcb9c012b661209e82"; # sudo restic -r /bulk/backup/nixos-server cat config --json → "id"
    }
    {
      id = "laptop-josip";
      uri = "/persist/backup/laptop-josip";
      guid = "d26c51372bcf7067bf020f42c2eff5cbdfa237845669d444cceba123428f979c"; # restic -r /persist/backup/laptop-josip cat config --json → "id"
    }
    # {
    #   id = "restic-media";
    #   uri = "sftp:${secrets.storageBoxUser}@${secrets.storageBoxUser}.your-storagebox.de:./restic-media";
    #   guid = "REPLACE_ME";  # restic -r "sftp:.../restic-media" cat config --json → "id"
    # }
  ];

  # Build Backrest config JSON (camelCase keys per proto).
  # Existing repos: set guid (from restic cat config --json "id"). New repos: set autoInitialize = true.
  repoToJson =
    repo:
    let
      base = {
        id = repo.id;
        uri = repo.uri;
        env = [ "RESTIC_PASSWORD_FILE=${passwordFile}" ];
      };
      withGuid = if (repo.guid or "") != "" then base // { guid = repo.guid; } else base;
      withAutoInit =
        if repo.autoInitialize or false then withGuid // { autoInitialize = true; } else withGuid;
    in
    withAutoInit;
  backrestConfig = builtins.toJSON {
    modno = 0;
    version = 6;
    instance = secrets.hostname or "nixos-backrest";
    repos = map repoToJson repos;
  };

in
{
  # Single password file for all Backrest repos (secrets.backupPassword from secrets.nix).
  environment.etc."restic/backrest-password" = {
    text = secrets.backupPassword;
    mode = "0600";
  };

  # Backrest config (no secrets inside, only env pointing to password files)
  environment.etc."backrest/config.json" = {
    text = backrestConfig;
    mode = "0600";
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
      # Restic and SSH (for SFTP repos) must be on PATH.
      # HOME/XDG_CACHE_HOME so restic can use a cache dir and won't print to stdout (breaks JSON parsing).
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
