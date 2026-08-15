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
  # Two independently labelled pools share one host-wide guest ceiling so a
  # long-running agent cannot starve PR CI (and vice versa under hostMaxGuests).
  # Live host (2026-08-15): ~62 GiB RAM, swap often full at 3×4 GiB guests + HA +
  # dense Podman — hostMaxGuests=3 is the physical ceiling; do not raise without
  # re-checking MemAvailable.
  services.ciRunner = {
    enable = true;
    github.enable = true;
    hostMaxGuests = 3;

    # CI pool: keep idle spare; reserve 2 host slots so an agent guest cannot
    # reduce CI below useful concurrency for the Developer→CI→Reviewer flow.
    desiredIdleCapacity = 1;
    maxGuests = 3;
    pools.ci.reservedHostSlots = 2;
    pools.ci.priority = 100;

    # Agent pool: one concurrent Developer/Reviewer spare (polling idle model).
    pools.agent = {
      enable = true;
      desiredIdleCapacity = 1;
      maxGuests = 1;
      reservedHostSlots = 0;
      priority = 50;
    };

    # Explicit CI-only DNS for internal HTTPS deps (not LAN AdGuard).
    # verdaccio.iktstudio.com terminates on this host's Traefik (br0 192.168.10.7:443)
    # → INPUT path via hostAllowTcp, not FORWARD/internalAllowTcp.
    # Shared by CI and agent guests on the same isolated ci-net.
    internalDnsHosts = [
      {
        name = "verdaccio.iktstudio.com";
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
    validationUrls = [ "https://verdaccio.iktstudio.com/" ];
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
