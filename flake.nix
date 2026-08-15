{
  description = "NixOS configuration with impermanence";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    # CI guest OS: current supported stable NixOS. Kept as a dedicated input so the
    # disposable guest tracks a supported stable release (26.05 "Yarara") independently
    # of the host's upgrade cadence. 25.05 "Warbler" reached end-of-support 2025-12-31.
    nixpkgs-guest.url = "github:nixos/nixpkgs/nixos-26.05";
    # Used ONLY for narrow CI guest pins that stable lacks:
    #   - github-runner: GitHub deprecates old runner versions (must be within 30 days of
    #     latest); even current stable lags (26.05 ships 2.335.1 vs latest 2.336.0).
    #   - podman-compose: 26.05 ships 1.5.0 (no `up --wait`); unstable has 1.6.0.
    # Do not move the whole guest OS onto unstable.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    impermanence.url = "github:nix-community/impermanence";
    aliases = {
      url = "github:tomuradjosip/aliases";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-guest,
      nixpkgs-unstable,
      impermanence,
      aliases,
      ...
    }@inputs:
    let
      secrets = import /etc/secrets/config/secrets.nix;
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      # Guest package set: current supported stable NixOS for the disposable CI image.
      guestPkgs = import nixpkgs-guest { inherit system; };
      unstablePkgs = import nixpkgs-unstable { inherit system; };
      # Single source of truth for the github-runner pinned into the guest image.
      runnerPkg = unstablePkgs.github-runner;
      # Compose provider for `podman compose` inside disposable guests (1.6.0+ for --wait).
      podmanComposePkg = unstablePkgs.podman-compose;
    in
    {
      nixosConfigurations.${secrets.hostname} = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs;
          # Baked runner version, threaded to the freshness monitor on the host.
          ciRunnerVersion = runnerPkg.version;
        };

        modules = [
          impermanence.nixosModules.impermanence
          ./configuration.nix
        ];
      };

      packages.${system} = {
        # Built from the guest (stable 26.05) package set; github-runner and
        # podman-compose are the only unstable injections.
        ci-runner-guest-image = guestPkgs.callPackage ./packages/ci-runner-guest-image.nix {
          githubRunner = runnerPkg;
          podmanCompose = podmanComposePkg;
        };
        ci-runner-provisioner = pkgs.callPackage ./packages/ci-runner-provisioner.nix {
          runnerVersion = runnerPkg.version;
          dataDir = "/data/ci";
          networkName = "ci-net";
          bridgeName = "virbr-ci";
          domainPrefix = "ci-ephemeral-";
          candidatePrefix = "ci-candidate-";
          runnerLabel = "nixos-ephemeral-ci";
          desiredIdleCapacity = 1;
          maxGuests = 3;
          hostMaxGuests = 3;
          guestMemoryMiB = 4096;
          guestVcpus = 2;
          lanProbeTarget = "192.168.10.7";
          provisioningGraceSec = 300;
          validationUrls = [ ];
          githubEnable = false;
          githubOwner = "";
          githubRepo = "";
          githubAppId = "";
          githubInstallationId = "";
          githubPrivateKeyFile = "/persist/etc/secrets/ci-runner/github-app.pem";
          textfileDir = "/var/lib/node_exporter_textfile";
          pools = [
            {
              id = "ci";
              enable = true;
              prefix = "ci-ephemeral-";
              candidate_prefix = "ci-candidate-";
              runner_label = "nixos-ephemeral-ci";
              desired_idle = 1;
              max_guests = 3;
              reserved_host_slots = 2;
              priority = 100;
              guest_memory_mib = 4096;
              guest_vcpus = 2;
              github_enable = false;
              github_owner = "";
              github_repo = "";
            }
            {
              id = "agent";
              enable = true;
              prefix = "agent-ephemeral-";
              candidate_prefix = "agent-candidate-";
              runner_label = "nixos-ephemeral-agent";
              desired_idle = 1;
              max_guests = 1;
              reserved_host_slots = 0;
              priority = 50;
              guest_memory_mib = 4096;
              guest_vcpus = 2;
              github_enable = false;
              github_owner = "";
              github_repo = "";
            }
          ];
        };
      };
    };
}
