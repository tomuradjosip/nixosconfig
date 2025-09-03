{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Backrest configuration
  environment.etc."backrest/config.json" = {
    text = builtins.toJSON {
      repos = [
        {
          id = "local-backup";
          uri = "/bulk/backup";
          password = secrets.backup.password;
        }
      ];
      plans = [
        {
          id = "backup";
          repo = "backup";
          paths = [
            "/home"
          ];
          excludes = [
            "*.tmp"
            "*.temp"
            "*/.cache/*"
            "*/node_modules/*"
            "*/.git/*"
          ];
          schedule = {
            schedule = "0 2 * * *"; # Daily at 2 AM
            disabled = true;
          };
          retention = {
            policy = {
              keepLast = 30;
              keepDaily = 7;
              keepWeekly = 4;
              keepMonthly = 12;
            };
          };
        }
      ];
    };
    mode = "0600";
  };

  # Systemd service for Backrest daemon
  systemd.services.backrest = {
    description = "Backrest backup service";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ]; # Wait for /bulk to be mounted
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.backrest}/bin/backrest --config-file /etc/backrest/config.json";
      Restart = "always";
      RestartSec = "10s";
      User = "root";
      Group = "root";
    };
  };
}
