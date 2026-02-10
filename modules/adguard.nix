{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Disable DynamicUser so state lives at /var/lib/AdGuardHome (compatible with impermanence bind mounts)
  users.users.adguardhome = {
    isSystemUser = true;
    group = "adguardhome";
  };
  users.groups.adguardhome = { };

  systemd.services.adguardhome.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "adguardhome";
    Group = "adguardhome";
  };

  services.adguardhome = {
    enable = true;
    host = "0.0.0.0";
    port = 3000;
    # Allow settings to be changed through the web UI
    mutableSettings = true;
    openFirewall = false; # We manage firewall rules in networking.nix

    settings = {
      dns = {
        # Bind DNS to the server's LAN IP
        bind_hosts = [ "192.168.10.7" ];
        port = 53;

        # Upstream DNS with DNS-over-HTTPS
        upstream_dns = [
          "https://dns.cloudflare.com/dns-query"
          "https://dns.google/dns-query"
        ];
        # Bootstrap DNS for resolving DoH hostnames
        bootstrap_dns = [
          "1.1.1.1"
          "8.8.8.8"
        ];

        # Enable DNSSEC validation
        enable_dnssec = true;

        # Caching
        cache_size = 4194304; # 4MB
        cache_ttl_min = 300;
      };

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        parental_enabled = false;
        safe_search = {
          enabled = false;
        };
      };

      filters =
        map
          (url: {
            enabled = true;
            url = url;
          })
          [
            "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt" # AdGuard DNS filter
            "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt" # AdAway Default Blocklist
            "https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt" # The Big List of Hacked Malware Web Sites
            "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt" # Malicious URL Blocklist
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" # Steven Black's unified hosts
          ];
    };
  };
}
