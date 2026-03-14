{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

let
  textfileDir = "/var/lib/node_exporter_textfile";

  # Fetches public IP every 2 minutes (fallback across multiple services).
  # Writes node_public_ip_info gauge for the textfile collector.
  # IP is a label so Prometheus stores full address history automatically.
  fetchPublicIpScript = pkgs.writeShellScript "fetch-public-ip" ''
    set -euo pipefail
    DIR="${textfileDir}"
    mkdir -p "$DIR"

    URLS=(
      "https://api.ipify.org"
      "https://ifconfig.me/ip"
      "https://icanhazip.com"
      "https://checkip.amazonaws.com"
      "https://wtfismyip.com/text"
    )

    last_ip=""

    while true; do
      ip=""
      for url in "''${URLS[@]}"; do
        if raw=$(curl -sSf --max-time 5 "$url" 2>/dev/null); then
          candidate=$(printf '%s' "$raw" | tr -d ' \t\n\r')
          if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip="$candidate"
            break
          fi
        fi
      done

      if [[ -n "$ip" ]]; then
        tmp="$DIR/public_ip.prom.$$.tmp"
        {
          echo '# HELP node_public_ip_info Current public IP (value=1 when reachable).'
          echo '# TYPE node_public_ip_info gauge'
          echo "node_public_ip_info{ip=\"$ip\"} 1"
        } > "$tmp"
        mv -f "$tmp" "$DIR/public_ip.prom"
        last_ip="$ip"
      fi

      sleep 120
    done
  '';

  # Blackbox exporter probe modules (HTTP, TCP, ICMP, DNS). Prometheus scrapes
  # /probe?target=...&module=... to run a probe; this defines the modules.
  blackboxConfig = pkgs.writeText "blackbox.yml" ''
    modules:
      http_2xx:
        prober: http
        timeout: 5s
        http:
          valid_status_codes: []
          method: GET
      http_post_2xx:
        prober: http
        timeout: 5s
        http:
          method: POST
      tcp_connect:
        prober: tcp
        timeout: 5s
      icmp:
        prober: icmp
        timeout: 5s
      dns:
        prober: dns
        timeout: 5s
        dns:
          query_name: "google.com"
  '';
in
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
      "textfile" # Custom .prom files (e.g. public IP from fetch-public-ip.service)
    ];
    extraFlags = [
      "--collector.textfile.directory=${textfileDir}"
    ];
  };

  # Prometheus blackbox exporter (HTTP/TCP/ICMP/DNS probes for endpoint monitoring)
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "0.0.0.0"; # so Prometheus in Podman can scrape via host.containers.internal
    port = 9115;
    configFile = blackboxConfig;
  };

  # Fetch public IP every 5s (round-robin across 6 services), write to node exporter textfile dir
  systemd.services.fetch-public-ip = {
    description = "Fetch public IP and expose via node exporter textfile collector";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      StateDirectory = "node_exporter_textfile";
    };
    path = [
      pkgs.curl
      pkgs.coreutils
    ];
    script = ''
      chmod 0755 ${textfileDir}
      exec ${fetchPublicIpScript}
    '';
  };
}
