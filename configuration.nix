{
  config,
  pkgs,
  lib,
  ...
}:

let
  secrets = import ./secrets.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ./modules/storage.nix
    ./modules/networking.nix
    ./modules/users.nix
    ./modules/packages.nix
    ./modules/persistence.nix
    ./modules/localization.nix
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
