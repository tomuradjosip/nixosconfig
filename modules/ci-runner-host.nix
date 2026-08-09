# Host prerequisites for the ephemeral CI runner platform:
# directories, packages, libvirt bridge allowlist, enable option.
{
  config,
  pkgs,
  lib,
  secrets,
  # Baked github-runner version, provided via flake specialArgs (single source of truth
  # is the unstable github-runner pinned into the guest image). Empty when evaluated
  # outside the flake; the freshness monitor degrades gracefully in that case.
  ciRunnerVersion ? "",
  ...
}:

let
  cfg = config.services.ciRunner;
  ciRoot = cfg.dataDir;
in
{
  options.services.ciRunner = {
    enable = lib.mkEnableOption "ephemeral GitHub Actions CI runner platform (libvirt VMs)";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/data/ci";
      description = "Root directory for CI base images, overlays, seeds, and state (prefer fast persistent storage).";
    };

    networkName = lib.mkOption {
      type = lib.types.str;
      default = "ci-net";
      description = "libvirt network name for CI guests.";
    };

    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "virbr-ci";
      description = "Bridge interface created for the CI libvirt NAT network.";
    };

    subnetCidr = lib.mkOption {
      type = lib.types.str;
      default = "192.168.67.0/24";
      description = "Dedicated CI NAT subnet (must not overlap LAN or Podman networks).";
    };

    gatewayAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.67.1";
      description = "CI network gateway address on the host.";
    };

    dhcpRangeStart = lib.mkOption {
      type = lib.types.str;
      default = "192.168.67.10";
    };

    dhcpRangeEnd = lib.mkOption {
      type = lib.types.str;
      default = "192.168.67.50";
    };

    domainPrefix = lib.mkOption {
      type = lib.types.str;
      default = "ci-ephemeral-";
      description = "libvirt domain name prefix; reaper only touches domains with this prefix.";
    };

    runnerLabel = lib.mkOption {
      type = lib.types.str;
      default = "nixos-ephemeral-ci";
      description = "Generic custom GitHub Actions runner label for this platform.";
    };

    runnerVersion = lib.mkOption {
      type = lib.types.str;
      default = ciRunnerVersion;
      description = ''
        github-runner version baked into the current guest image. Used only by the
        freshness monitor to compare against the latest published GitHub runner release.
        Defaults to the version threaded from the flake (unstable github-runner).
      '';
    };

    desiredCleanCapacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Desired number of clean idle ephemeral runners.";
    };

    maxGuests = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Hard cap on concurrent CI guests.";
    };

    guestMemoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
    };

    guestVcpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
    };

    lanCidr = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.0/24";
      description = "Trusted LAN CIDR denied to CI guests by default.";
    };

    lanProbeTarget = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.7";
      description = "LAN address used by dummy isolation probes (typically the host br0 address).";
    };

    github = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable GitHub App registration for warm-spare runners.";
      };

      owner = lib.mkOption {
        type = lib.types.str;
        default = (secrets.ciRunner or { }).githubOwner or "";
        description = "GitHub repository owner.";
      };

      repo = lib.mkOption {
        type = lib.types.str;
        default = (secrets.ciRunner or { }).githubRepo or "";
        description = "GitHub repository name.";
      };

      appId = lib.mkOption {
        type = lib.types.str;
        default = (secrets.ciRunner or { }).githubAppId or "";
        description = "GitHub App ID.";
      };

      installationId = lib.mkOption {
        type = lib.types.str;
        default = (secrets.ciRunner or { }).githubAppInstallationId or "";
        description = "GitHub App installation ID.";
      };

      privateKeyFile = lib.mkOption {
        type = lib.types.path;
        default = "/persist/etc/secrets/ci-runner/github-app.pem";
        description = "Host-only GitHub App private key (never injected into guests).";
      };
    };

    internalAllowTcp = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            address = lib.mkOption { type = lib.types.str; };
            port = lib.mkOption { type = lib.types.port; };
          };
        }
      );
      default = [ ];
      description = "Explicit internal TCP exceptions CI guests may reach (empty for v1).";
    };
    package = lib.mkOption {
      type = lib.types.package;
      internal = true;
      description = "ci-runnerctl package";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      ciPkg = pkgs.callPackage ../packages/ci-runner-provisioner.nix {
        inherit (cfg)
          dataDir
          networkName
          bridgeName
          domainPrefix
          runnerLabel
          runnerVersion
          desiredCleanCapacity
          maxGuests
          guestMemoryMiB
          guestVcpus
          lanProbeTarget
          ;
        githubEnable = cfg.github.enable;
        githubOwner = cfg.github.owner;
        githubRepo = cfg.github.repo;
        githubAppId = cfg.github.appId;
        githubInstallationId = cfg.github.installationId;
        githubPrivateKeyFile = cfg.github.privateKeyFile;
        textfileDir = "/var/lib/node_exporter_textfile";
      };
    in
    {
      assertions = [
        {
          assertion = cfg.desiredCleanCapacity <= cfg.maxGuests;
          message = "services.ciRunner.desiredCleanCapacity must be <= maxGuests";
        }
        {
          assertion =
            !(cfg.github.enable)
            || (
              cfg.github.owner != ""
              && cfg.github.repo != ""
              && cfg.github.appId != ""
              && cfg.github.installationId != ""
            );
          message = "services.ciRunner.github.enable requires owner/repo/appId/installationId (see secrets.ciRunner)";
        }
      ];

      services.ciRunner.package = ciPkg;

      # Allow qemu to attach CI guests to the dedicated bridge.
      virtualisation.libvirtd.allowedBridges = lib.mkAfter [ cfg.bridgeName ];

      environment.systemPackages = [
        pkgs.qemu_kvm
        pkgs.libvirt
        pkgs.virt-manager
        pkgs.xorriso
        pkgs.jq
        pkgs.curl
        ciPkg
      ];

      # Prefer explicit mkdir over tmpfiles for /data/ci (parent /data may be user-owned).
      system.activationScripts.ci-runner-dirs = lib.stringAfter [ "users" ] ''
        mkdir -p ${ciRoot}/base ${ciRoot}/overlays ${ciRoot}/seeds ${ciRoot}/state ${ciRoot}/logs
        chmod 0750 ${ciRoot} || true
        chmod 0750 ${ciRoot}/base ${ciRoot}/logs || true
        chmod 0700 ${ciRoot}/overlays ${ciRoot}/seeds ${ciRoot}/state || true
        mkdir -p /persist/etc/secrets/ci-runner
        chmod 0700 /persist/etc/secrets/ci-runner || true
      '';
    }
  );
}
