{
  config,
  pkgs,
  lib,
  secrets,
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
      # User-specific directories
      "/home/${secrets.username}/.config" # Application configurations
      "/home/${secrets.username}/.ssh" # SSH keys and configuration
      "/home/${secrets.username}/.cursor" # Cursor IDE cache and settings
      "/home/${secrets.username}/.cursor-server" # Cursor server files
      "/home/${secrets.username}/nixosconfig" # NixOS configuration
    ]
    ++ lib.optionals (secrets.diskIds ? bulkData) [
      "/var/lib/samba" # Samba password database
    ];
    files = [
      "/etc/machine-id" # Unique system identifier used by many services
      "/home/${secrets.username}/.zsh_history" # Zsh command history
    ];
  };
}
