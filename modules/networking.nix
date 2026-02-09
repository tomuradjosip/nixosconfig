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
        80
        443
        49694
      ];
      allowedUDPPorts = [
        53
        49694
      ];
    };
  };

  # Kernel parameters
  boot.kernel.sysctl = {
    # Allow rootless podman to bind to privileged ports (80/443 for Traefik)
    "net.ipv4.ip_unprivileged_port_start" = 80;
    # Disable IPv6 (no IPv6 connectivity available, prevents timeout delays)
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
  };

  # Enable SSH server with secure settings
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
    allowSFTP = false; # Don't set this if you need sftp
    extraConfig = ''
      AllowTcpForwarding yes
      X11Forwarding no
      AllowAgentForwarding no
      AllowStreamLocalForwarding no
      AuthenticationMethods publickey
    '';
  };
}
