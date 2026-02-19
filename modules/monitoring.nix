{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Hardware sensor kernel modules (detected via sensors-detect)
  # coretemp: Intel CPU thermal sensor
  # nct6775: Nuvoton NCT6798D Super I/O (motherboard temps, fan speeds, voltages)
  boot.kernelModules = [
    "coretemp"
    "nct6775"
  ];

  # Prometheus node exporter (CPU, memory, disk, network, hwmon sensors for Grafana/Prometheus)
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "0.0.0.0"; # so Prometheus in Podman can scrape via host.containers.internal
    port = 9100;
    enabledCollectors = [
      "hwmon" # Hardware sensors (temps, fans, voltages) — needs boot.kernelModules above
      "systemd" # Systemd unit states
      "ethtool" # NIC stats (speed, errors)
      "ntp" # NTP daemon time-sync health
    ];
  };
}
