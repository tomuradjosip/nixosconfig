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
  ];

  # Need this for vscode-server
  programs.nix-ld.enable = true;

  # Shell configuration
  programs.bash = {
    shellAliases = {
      rb = "sudo nixos-rebuild switch --impure --flake /home/${secrets.username}/nixosconfig#${secrets.hostname}";
      rbt = "sudo nixos-rebuild test --impure --flake /home/${secrets.username}/nixosconfig#${secrets.hostname}";
    };
  };
}
