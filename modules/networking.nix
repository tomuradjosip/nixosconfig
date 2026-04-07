{ secrets, ... }:

{
  # Scripted bridge: physical NIC → br0 (libvirt, Traefik → VMs). NM off avoids br0-netdev EBUSY.
  # IPv6 stays enabled (no ipv6.disable=1 — dhcpcd needs /proc/sys/net/ipv6).
  networking = {
    useDHCP = false;
    hostId = secrets.zfsHostId;
    bridges.br0.interfaces = [ secrets.bridgePhysicalInterface ];
    interfaces = {
      br0.useDHCP = true;
      ${secrets.bridgePhysicalInterface}.useDHCP = false;
    };
    dhcpcd.allowInterfaces = [ "br0" ];
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

  boot.kernel.sysctl = {
    "net.ipv4.ip_unprivileged_port_start" = 80;
  };

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
    '';
  };
}
