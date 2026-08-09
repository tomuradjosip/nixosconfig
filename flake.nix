{
  description = "NixOS configuration with impermanence";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    # CI guest OS: current supported stable NixOS. Kept as a dedicated input so the
    # disposable guest tracks a supported stable release (26.05 "Yarara") independently
    # of the host's upgrade cadence. 25.05 "Warbler" reached end-of-support 2025-12-31.
    nixpkgs-guest.url = "github:nixos/nixpkgs/nixos-26.05";
    # Used ONLY for the CI guest image's github-runner: GitHub deprecates old runner
    # versions (a self-hosted runner must be within 30 days of the latest release), and
    # even current stable lags (26.05 ships 2.335.1 vs latest 2.336.0). unstable provides
    # a sufficiently current runner without moving the whole guest OS off stable.
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
        # Built from the guest (stable 26.05) package set; only the runner comes from unstable.
        ci-runner-guest-image = guestPkgs.callPackage ./packages/ci-runner-guest-image.nix {
          githubRunner = runnerPkg;
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
          # Flake package default mirrors the architectural ceiling; the live NixOS
          # module default is evidence-based (see services.ciRunner.maxGuests).
          maxGuests = 10;
          guestMemoryMiB = 4096;
          guestVcpus = 2;
          lanProbeTarget = "192.168.10.7";
          provisioningGraceSec = 300;
          githubEnable = false;
          githubOwner = "";
          githubRepo = "";
          githubAppId = "";
          githubInstallationId = "";
          githubPrivateKeyFile = "/persist/etc/secrets/ci-runner/github-app.pem";
          textfileDir = "/var/lib/node_exporter_textfile";
        };
      };
    };
}
