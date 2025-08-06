{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # System packages
  environment.systemPackages = with pkgs; [
    rsync
    zfs
    vim
    wget
    git
    nixfmt-rfc-style # For formatting nix files
    htop
    pre-commit
    oh-my-posh
  ];

  # Need this for vscode-server
  programs.nix-ld.enable = true;
}
