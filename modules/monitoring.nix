{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Dedicated system user for Glances (compatible with impermanence, same pattern as AdGuard)
  users.users.glances = {
    isSystemUser = true;
    group = "glances";
  };
  users.groups.glances = { };

  # Hardware sensor kernel modules (detected via sensors-detect)
  # coretemp: Intel CPU thermal sensor
  # nct6775: Nuvoton NCT6798D Super I/O (motherboard temps, fan speeds, voltages)
  boot.kernelModules = [ "coretemp" "nct6775" ];

  # Hardware monitoring tools
  environment.systemPackages = with pkgs; [
    lm_sensors # CLI: run 'sensors' to see temps/fan speeds
    glances # CLI: run 'glances' for a quick overview
  ];

  # Glances web UI service
  systemd.services.glances = {
    description = "Glances system monitoring web UI";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.glances}/bin/glances -w -B 0.0.0.0 -p 61208 -t 5 --disable-plugin now";
      Restart = "on-failure";
      RestartSec = 5;

      User = "glances";
      Group = "glances";
      SupplementaryGroups = [ "systemd-journal" ];

      # Read-only access to system info
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;

      # Need access to /sys/class/hwmon for sensor data
      ReadOnlyPaths = [
        "/sys/class/hwmon"
        "/sys/class/thermal"
        "/proc"
      ];
    };
  };
}
