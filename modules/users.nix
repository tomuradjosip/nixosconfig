{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Root user configuration
  users.users.root = {
    hashedPasswordFile = "/persist/etc/secrets/passwords/root";
    shell = pkgs.zsh;
  };

  # Disable user management outside of this module
  users.mutableUsers = false;

  # User configuration using secrets
  users.users.${secrets.username} = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "podman"
      "systemd-journal"
    ];
    hashedPasswordFile = "/persist/etc/secrets/passwords/${secrets.username}";
    openssh.authorizedKeys.keys = secrets.sshKeys;
    shell = pkgs.zsh;
  };

  # SSH client configuration
  programs.ssh = {
    startAgent = true;
    extraConfig = ''
      AddKeysToAgent yes
      IdentitiesOnly yes
      IdentityFile /home/${secrets.username}/.ssh/${secrets.sshPrivateKeyFilename}
    '';
  };

  # Global Git configuration
  programs.git = {
    enable = true;
    config = {
      user = {
        name = secrets.gitUsername;
        email = secrets.gitEmail;
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      rebase.autosquash = true;
      rebase.autoStash = true;
    };
  };

  # Allow users in wheel group to use sudo without password
  security.sudo.wheelNeedsPassword = false;

  # Enable lingering for rootless podman and create user container directories
  systemd.tmpfiles.rules = [
    "f /var/lib/systemd/linger/${secrets.username} 0644 root root - -"
    # Create user container directories on ZFS
    "d /containers/users 0755 ${secrets.username} users - -"
    "d /containers/users/${secrets.username} 0755 ${secrets.username} users - -"
    "d /containers/users/${secrets.username}/storage 0755 ${secrets.username} users - -"
    "d /containers/users/${secrets.username}/run 0755 ${secrets.username} users - -"
    # Create config directory
    "d /home/${secrets.username}/.config/containers 0755 ${secrets.username} users - -"
    # Copy storage config from /etc to user home
    "C /home/${secrets.username}/.config/containers/storage.conf 0644 ${secrets.username} users - /etc/containers-user-storage-${secrets.username}.conf"
    # Symlink from home to ZFS storage
    "L+ /home/${secrets.username}/.local/share/containers - - - - /containers/users/${secrets.username}/storage"
  ];
}
