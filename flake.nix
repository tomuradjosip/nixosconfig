{
  description = "NixOS configuration with impermanence";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    impermanence.url = "github:nix-community/impermanence";
  };

  outputs =
    { nixpkgs, impermanence, ... }@inputs:
    let
      secrets = import /etc/secrets/config/secrets.nix;
    in
    {
      nixosConfigurations.${secrets.hostname} = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
          impermanence.nixosModules.impermanence
          ./configuration.nix
        ];
      };
    };
}
