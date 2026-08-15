# Host prerequisites for the ephemeral GitHub Actions runner platform:
# Directories, packages, libvirt bridge allowlist, multi-pool options.
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
  secretsCi = secrets.ciRunner or { };
  secretsAgent = secrets.agentRunner or { };

  poolSubmodule =
    {
      name,
      defaultPrefix,
      defaultCandidate,
      defaultLabel,
      defaultDesiredIdle,
      defaultMax,
      defaultReserved,
      defaultPriority,
      defaultOwner,
      defaultRepo,
    }:
    lib.types.submodule {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = name == "ci";
          description = "Enable the ${name} runner pool.";
        };
        domainPrefix = lib.mkOption {
          type = lib.types.str;
          default = defaultPrefix;
        };
        candidatePrefix = lib.mkOption {
          type = lib.types.str;
          default = defaultCandidate;
        };
        runnerLabel = lib.mkOption {
          type = lib.types.str;
          default = defaultLabel;
        };
        desiredIdleCapacity = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = defaultDesiredIdle;
          description = ''
            Desired healthy online idle runners (busy=false). 0 disables idle
            replenishment (polling pools typically use 1).
          '';
        };
        maxGuests = lib.mkOption {
          type = lib.types.ints.positive;
          default = defaultMax;
        };
        reservedHostSlots = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = defaultReserved;
          description = ''
            Host guest slots reserved for this pool that lower-priority pools may
            not consume (CI starvation protection when an agent is busy).
          '';
        };
        priority = lib.mkOption {
          type = lib.types.int;
          default = defaultPriority;
          description = "Higher priority pools provision first under host contention.";
        };
        guestMemoryMiB = lib.mkOption {
          type = lib.types.ints.positive;
          default = 4096;
        };
        guestVcpus = lib.mkOption {
          type = lib.types.ints.positive;
          default = 2;
        };
        github = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable GitHub registration for this pool (also gated by services.ciRunner.github.enable).";
          };
          owner = lib.mkOption {
            type = lib.types.str;
            default = defaultOwner;
          };
          repo = lib.mkOption {
            type = lib.types.str;
            default = defaultRepo;
          };
        };
      };
    };
in
{
  options.services.ciRunner = {
    enable = lib.mkEnableOption "ephemeral GitHub Actions runner platform (libvirt VMs)";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/data/ci";
      description = "Root directory for base images, overlays, seeds, and state.";
    };

    networkName = lib.mkOption {
      type = lib.types.str;
      default = "ci-net";
      description = "libvirt network name shared by all runner pools.";
    };

    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "virbr-ci";
    };

    subnetCidr = lib.mkOption {
      type = lib.types.str;
      default = "192.168.67.0/24";
    };

    gatewayAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.67.1";
    };

    dhcpRangeStart = lib.mkOption {
      type = lib.types.str;
      default = "192.168.67.10";
    };

    dhcpRangeEnd = lib.mkOption {
      type = lib.types.str;
      default = "192.168.67.50";
    };

    hostMaxGuests = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Hard ceiling on concurrent managed production guests across ALL pools.
        Per-pool maxGuests cannot bypass this limit. Evidence-based for this host
        (HA VM + dense Podman; swap pressure already observed at 3×4 GiB guests).
      '';
    };

    runnerVersion = lib.mkOption {
      type = lib.types.str;
      default = ciRunnerVersion;
    };

    provisioningGraceSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
    };

    lanCidr = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.0/24";
    };

    lanProbeTarget = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.7";
    };

    # Top-level GitHub App identity (host-only key). Enables registration for
    # every pool that has owner/repo when github.enable is true.
    github = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Master switch: enable GitHub App registration for configured pools.";
      };
      appId = lib.mkOption {
        type = lib.types.str;
        default = secretsCi.githubAppId or "";
      };
      installationId = lib.mkOption {
        type = lib.types.str;
        default = secretsCi.githubAppInstallationId or "";
      };
      privateKeyFile = lib.mkOption {
        type = lib.types.path;
        default = "/persist/etc/secrets/ci-runner/github-app.pem";
        description = "Host-only GitHub App private key (never injected into guests).";
      };
      # Legacy flat owner/repo — applied to the CI pool when pools.ci.github.* unset.
      owner = lib.mkOption {
        type = lib.types.str;
        default = secretsCi.githubOwner or "";
        description = "Legacy alias for pools.ci.github.owner.";
      };
      repo = lib.mkOption {
        type = lib.types.str;
        default = secretsCi.githubRepo or "";
        description = "Legacy alias for pools.ci.github.repo.";
      };
    };

    # Legacy top-level CI pool aliases (existing configuration.nix).
    domainPrefix = lib.mkOption {
      type = lib.types.str;
      default = "ci-ephemeral-";
    };
    candidatePrefix = lib.mkOption {
      type = lib.types.str;
      default = "ci-candidate-";
    };
    runnerLabel = lib.mkOption {
      type = lib.types.str;
      default = "nixos-ephemeral-ci";
    };
    desiredIdleCapacity = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
    };
    maxGuests = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
    };
    guestMemoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
    };
    guestVcpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
    };

    pools = {
      ci = lib.mkOption {
        type = poolSubmodule {
          name = "ci";
          defaultPrefix = "ci-ephemeral-";
          defaultCandidate = "ci-candidate-";
          defaultLabel = "nixos-ephemeral-ci";
          defaultDesiredIdle = 1;
          defaultMax = 3;
          defaultReserved = 2;
          defaultPriority = 100;
          defaultOwner = secretsCi.githubOwner or "";
          defaultRepo = secretsCi.githubRepo or "";
        };
        default = { };
        description = "CI disposable runner pool (label nixos-ephemeral-ci).";
      };
      agent = lib.mkOption {
        type = poolSubmodule {
          name = "agent";
          defaultPrefix = "agent-ephemeral-";
          defaultCandidate = "agent-candidate-";
          defaultLabel = "nixos-ephemeral-agent";
          defaultDesiredIdle = 1;
          defaultMax = 1;
          defaultReserved = 0;
          defaultPriority = 50;
          defaultOwner = secretsAgent.githubOwner or secretsCi.githubOwner or "";
          defaultRepo = secretsAgent.githubRepo or secretsCi.githubRepo or "";
        };
        default = { };
        description = "Agent disposable runner pool (label nixos-ephemeral-agent).";
      };
    };

    internalDnsHosts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            address = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = [ ];
    };

    hostAllowTcp = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            address = lib.mkOption { type = lib.types.str; };
            port = lib.mkOption { type = lib.types.port; };
          };
        }
      );
      default = [ ];
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
    };

    validationUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };

    package = lib.mkOption {
      type = lib.types.package;
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable (
    let
      # Merge legacy top-level CI aliases + github.owner/repo into the CI pool.
      ciEffective = cfg.pools.ci // {
        domainPrefix = cfg.domainPrefix;
        candidatePrefix = cfg.candidatePrefix;
        runnerLabel = cfg.runnerLabel;
        desiredIdleCapacity = cfg.desiredIdleCapacity;
        maxGuests = cfg.maxGuests;
        guestMemoryMiB = cfg.guestMemoryMiB;
        guestVcpus = cfg.guestVcpus;
        github = cfg.pools.ci.github // {
          owner =
            if cfg.pools.ci.github.owner != "" then
              cfg.pools.ci.github.owner
            else
              cfg.github.owner;
          repo =
            if cfg.pools.ci.github.repo != "" then
              cfg.pools.ci.github.repo
            else
              cfg.github.repo;
          enable = cfg.github.enable || cfg.pools.ci.github.enable;
        };
      };

      agentEffective = cfg.pools.agent // {
        github = cfg.pools.agent.github // {
          owner =
            if cfg.pools.agent.github.owner != "" then
              cfg.pools.agent.github.owner
            else
              cfg.github.owner;
          repo =
            if cfg.pools.agent.github.repo != "" then
              cfg.pools.agent.github.repo
            else
              cfg.github.repo;
          enable = cfg.github.enable || cfg.pools.agent.github.enable;
        };
      };

      effectivePools = {
        ci = ciEffective;
      }
      // lib.optionalAttrs agentEffective.enable { agent = agentEffective; };

      poolList = lib.mapAttrsToList (id: p: {
        id = id;
        enable = true;
        prefix = p.domainPrefix;
        candidate_prefix = p.candidatePrefix;
        runner_label = p.runnerLabel;
        desired_idle = p.desiredIdleCapacity;
        max_guests = p.maxGuests;
        reserved_host_slots = p.reservedHostSlots;
        priority = p.priority;
        guest_memory_mib = p.guestMemoryMiB;
        guest_vcpus = p.guestVcpus;
        github_enable = p.github.enable;
        github_owner = p.github.owner;
        github_repo = p.github.repo;
      }) effectivePools;

      ciPkg = pkgs.callPackage ../packages/ci-runner-provisioner.nix {
        inherit (cfg)
          dataDir
          networkName
          bridgeName
          runnerVersion
          lanProbeTarget
          provisioningGraceSec
          validationUrls
          ;
        hostMaxGuests = cfg.hostMaxGuests;
        pools = poolList;
        # Legacy single-pool fields (CI) kept for flake package defaults / scripts.
        domainPrefix = ciEffective.domainPrefix;
        candidatePrefix = ciEffective.candidatePrefix;
        runnerLabel = ciEffective.runnerLabel;
        desiredIdleCapacity = ciEffective.desiredIdleCapacity;
        maxGuests = ciEffective.maxGuests;
        guestMemoryMiB = ciEffective.guestMemoryMiB;
        guestVcpus = ciEffective.guestVcpus;
        githubEnable = cfg.github.enable;
        githubOwner = ciEffective.github.owner;
        githubRepo = ciEffective.github.repo;
        githubAppId = cfg.github.appId;
        githubInstallationId = cfg.github.installationId;
        githubPrivateKeyFile = cfg.github.privateKeyFile;
        textfileDir = "/var/lib/node_exporter_textfile";
      };

      prefixPairs = lib.mapAttrsToList (_: p: {
        prod = p.domainPrefix;
        cand = p.candidatePrefix;
      }) effectivePools;
    in
    {
      assertions = [
        {
          assertion = cfg.hostMaxGuests >= 1;
          message = "services.ciRunner.hostMaxGuests must be >= 1";
        }
        {
          assertion = builtins.all (
            p: p.desiredIdleCapacity <= p.maxGuests
          ) (lib.attrValues effectivePools);
          message = "each pool's desiredIdleCapacity must be <= maxGuests";
        }
        {
          assertion = builtins.all (
            p: p.reservedHostSlots <= cfg.hostMaxGuests
          ) (lib.attrValues effectivePools);
          message = "reservedHostSlots must be <= hostMaxGuests";
        }
        {
          assertion =
            (lib.length (lib.attrValues effectivePools))
            == (lib.length (lib.unique (map (p: p.domainPrefix) (lib.attrValues effectivePools))));
          message = "services.ciRunner pool domainPrefix values must be unique";
        }
        {
          assertion = builtins.all (
            pair:
            pair.prod != pair.cand
            && !(lib.hasPrefix pair.prod pair.cand)
            && !(lib.hasPrefix pair.cand pair.prod)
          ) prefixPairs;
          message = "each pool's domain/candidate prefixes must be distinct and non-overlapping";
        }
        {
          assertion =
            !(cfg.github.enable)
            || (
              cfg.github.appId != ""
              && cfg.github.installationId != ""
              && builtins.all (
                p: !(p.github.enable) || (p.github.owner != "" && p.github.repo != "")
              ) (lib.attrValues effectivePools)
            );
          message = "services.ciRunner.github.enable requires appId/installationId and owner/repo for each GitHub-enabled pool";
        }
      ];

      services.ciRunner.package = ciPkg;

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

      system.activationScripts.ci-runner-dirs = lib.stringAfter [ "users" ] ''
        mkdir -p ${ciRoot}/base ${ciRoot}/overlays ${ciRoot}/seeds ${ciRoot}/state/guests ${ciRoot}/logs
        chmod 0750 ${ciRoot} || true
        chmod 0750 ${ciRoot}/base ${ciRoot}/logs || true
        chmod 0700 ${ciRoot}/overlays ${ciRoot}/seeds ${ciRoot}/state ${ciRoot}/state/guests || true
        mkdir -p /persist/etc/secrets/ci-runner
        chmod 0700 /persist/etc/secrets/ci-runner || true
      '';
    }
  );
}
