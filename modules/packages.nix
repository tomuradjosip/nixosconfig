{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  environment.systemPackages =
    with pkgs;
    [
      # System packages
      rsync
      zfs
      vim
      wget
      git
      nixfmt-rfc-style # For formatting nix files
      htop
      pre-commit
      oh-my-posh
    ]
    ++ [
      # Custom packages
      (pkgs.callPackage ../packages/nixos-rebuild-with-esp.nix { inherit secrets; })
    ];

  # Need this for vscode-server
  programs.nix-ld.enable = true;
}
