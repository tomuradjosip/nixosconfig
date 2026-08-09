{
  description = "NixOS configuration with impermanence";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    # Used ONLY for the CI guest image's github-runner: GitHub rejects deprecated
    # runner versions, and 25.05 lags behind the required minimum.
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
      nixpkgs-unstable,
      impermanence,
      aliases,
      ...
    }@inputs:
    let
      secrets = import /etc/secrets/config/secrets.nix;
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      unstablePkgs = import nixpkgs-unstable { inherit system; };
    in
    {
      nixosConfigurations.${secrets.hostname} = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };

        modules = [
          impermanence.nixosModules.impermanence
          ./configuration.nix
        ];
      };

      packages.${system} = {
        ci-runner-guest-image = pkgs.callPackage ./packages/ci-runner-guest-image.nix {
          githubRunner = unstablePkgs.github-runner;
        };
        ci-runner-provisioner = pkgs.callPackage ./packages/ci-runner-provisioner.nix {
          dataDir = "/data/ci";
          networkName = "ci-net";
          bridgeName = "virbr-ci";
          domainPrefix = "ci-ephemeral-";
          runnerLabel = "nixos-ephemeral-ci";
          desiredCleanCapacity = 1;
          maxGuests = 1;
          guestMemoryMiB = 4096;
          guestVcpus = 2;
          lanProbeTarget = "192.168.10.7";
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
