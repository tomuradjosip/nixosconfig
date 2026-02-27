{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

let
  textfileDir = "/var/lib/node_exporter_textfile";

  # Fetches public IP from 6 services round-robin every 5s; writes node_public_ip_info
  # and node_public_ip_change_timestamp_seconds (last 5 changes) for the textfile collector.
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
    SOURCES=("api.ipify.org" "ifconfig.me" "icanhazip.com" "checkip.amazonaws.com" "ip.seeip.org" "wtfismyip.com")
    n=6
    idx=0
    last_ip=""
    change_ts=()  # up to 5 timestamps, newest first

    while true; do
      url="''${URLS[$idx]}"
      source="''${SOURCES[$idx]}"
      idx=$(( (idx + 1) % n ))

      ip=""
      success=0
      if raw=$(curl -sSf --max-time 5 "$url" 2>/dev/null); then
        ip=$(printf '%s' "$raw" | tr -d ' \t\n\r')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          success=1
        fi
      fi

      if [[ "$success" -eq 1 && -n "$ip" && "$ip" != "$last_ip" ]]; then
        ts=$(date +%s)
        change_ts=("$ts" "''${change_ts[@]:0:4}")
        last_ip="$ip"
      fi

      ip_escaped=$(printf '%s' "$ip" | sed 's/\\/\\\\/g; s/"/\\"/g')
      tmp="$DIR/public_ip.prom.$$.tmp"
      {
        echo '# HELP node_public_ip_info Current public outbound IP from round-robin fetch'
        echo '# TYPE node_public_ip_info gauge'
        echo "node_public_ip_info{ip=\"$ip_escaped\",source=\"$source\",success=\"$success\"} $success"
        echo '# HELP node_public_ip_change_timestamp_seconds Unix timestamp of last 5 public IP changes'
        echo '# TYPE node_public_ip_change_timestamp_seconds gauge'
        for i in 0 1 2 3 4; do
          ts="''${change_ts[$i]:-0}"
          echo "node_public_ip_change_timestamp_seconds{index=\"$i\"} $ts"
        done
      } > "$tmp"
      mv -f "$tmp" "$DIR/public_ip.prom"

      sleep 15
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
