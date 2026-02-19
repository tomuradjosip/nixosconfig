{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Network configuration
  networking = {
    networkmanager.enable = true;
    hostId = secrets.zfsHostId;
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22
        53
        # Traefik
        80
        443
        7443
        # Coturn TURN/STUN for PairDrop
        3478
        5349
        # qBittorrent
        49694
      ];
      allowedUDPPorts = [
        53
        # Coturn TURN/STUN for PairDrop
        3478
        5349
        # qBittorrent
        49694
      ];
      # Coturn TURN/STUN relay port range for PairDrop
      allowedUDPPortRanges = [
        {
          from = 10000;
          to = 20000;
        }
      ];
    };
  };

  # Disable IPv6 completely (no IPv6 connectivity available, prevents timeout delays)
  # Kernel boot parameter is the most reliable method
  boot.kernelParams = [ "ipv6.disable=1" ];

  # Kernel parameters
  boot.kernel.sysctl = {
    # Allow rootless podman to bind to privileged ports (80/443 for Traefik)
    "net.ipv4.ip_unprivileged_port_start" = 80;
  };

  # Prevent NetworkManager from enabling IPv6 on any connection
  networking.networkmanager.connectionConfig = {
    "ipv6.method" = "disabled";
  };

  # Enable SSH server with secure settings
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
    allowSFTP = true; # Required for restic external machines backup (sftp:... repo)
    extraConfig = ''
      AllowTcpForwarding yes
      X11Forwarding no
      AllowAgentForwarding no
      AllowStreamLocalForwarding no
      AuthenticationMethods publickey
      AddressFamily inet
    '';
  };
}
