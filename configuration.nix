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

  # Ephemeral GitHub Actions runner platform (libvirt VMs).
  # desiredIdleCapacity=1 keeps one fresh idle spare; maxGuests is evidence-based
  # for this host (62 GiB RAM, HA VM + dense Podman). Architectural ceiling is 10 —
  # do not raise without re-checking MemAvailable and vCPU headroom.
  services.ciRunner = {
    enable = true;
    github.enable = true;
    desiredIdleCapacity = 1;
    maxGuests = 3;

    # Explicit CI-only DNS for internal HTTPS deps (not LAN AdGuard).
    # homepage.iktstudio.com terminates on this host's Traefik (br0 192.168.10.7:443)
    # → INPUT path via hostAllowTcp, not FORWARD/internalAllowTcp.
    internalDnsHosts = [
      {
        name = "homepage.iktstudio.com";
        address = "192.168.10.7";
      }
    ];
    hostAllowTcp = [
      {
        address = "192.168.10.7";
        port = 443;
      }
    ];
    # Optional disposable-guest probe; also overridable via
    # `ci-runnerctl validate-candidate … --probe-url …`.
    validationUrls = [ "https://homepage.iktstudio.com/" ];
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
