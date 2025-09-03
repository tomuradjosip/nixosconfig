{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Persist specific directories
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/lib/nixos" # NixOS state and generation history (essential)
      "/etc/ssh" # SSH server config and host keys (essential)
      "/etc/secrets" # Password hashes and other sensitive data (essential)
      "/var/log" # System logs for debugging and troubleshooting
      "/var/lib/systemd" # Systemd state and journal data
      "/var/lib/NetworkManager" # NetworkManager state and interface info
      "/var/lib/restic" # Restic cache
      "/etc/NetworkManager/system-connections" # Saved WiFi passwords and network configs
      "/home" # All user data and application settings
    ];
    files = [
      "/etc/machine-id" # Unique system identifier used by many services
    ];
  };
}
