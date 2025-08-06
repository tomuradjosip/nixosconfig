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
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ ];
    };
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
