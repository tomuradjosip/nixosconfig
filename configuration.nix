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
    ./modules/adguard.nix
    ./modules/users.nix
    ./modules/packages.nix
    ./modules/virtualization.nix
    ./modules/shell.nix
    ./modules/persistence.nix
    ./modules/localization.nix
    ./modules/backup.nix
    ./modules/backrest.nix
    ./modules/samba.nix
    ./modules/mikrotik-backup.nix
    ./modules/monitoring.nix
    ./modules/ci-runner-host.nix
    ./modules/ci-runner-network.nix
    ./modules/ci-runner-provisioner.nix
  ];

  # Ephemeral GitHub Actions runner platform (libvirt VMs). Keep github.enable
  # false until App credentials exist and disposable-VM isolation is validated.
  services.ciRunner = {
    enable = true;
    github.enable = true;
  };
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
