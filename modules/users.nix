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
}
