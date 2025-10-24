{
  config,
  pkgs,
  lib,
  ...
}:

let
  secrets = import /etc/secrets/config/secrets.nix;
in
{
  imports = [
    /etc/secrets/config/hardware-configuration.nix
    ./modules/storage.nix
    ./modules/networking.nix
    ./modules/users.nix
    ./modules/packages.nix
    ./modules/shell.nix
    ./modules/persistence.nix
    ./modules/localization.nix
    ./modules/backup.nix
    ./modules/samba.nix
    ./modules/mikrotik-backup.nix
  ];

  # Enable flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # System hostname from secrets
  networking.hostName = secrets.hostname;

  # Pass secrets to modules
  _module.args.secrets = secrets;

  # Very dangerous to change, read docs before touching this variable
  system.stateVersion = "25.05";
}
