# Builds a disposable NixOS CI runner base qcow2 image.
#
# pkgs is the guest package set (nixpkgs-guest = current supported stable NixOS),
# so the guest OS tracks a supported stable release. Narrow unstable injections:
#   - githubRunner: GitHub deprecates old runner versions and refuses connections
#     from them (a self-hosted runner must stay within 30 days of the latest
#     release), while the runner in the immutable /nix/store cannot self-update.
#     Pinning a current runner here + --disableupdate in the guest avoids both
#     failure modes.
#   - podmanCompose: nixos-26.05 ships podman-compose 1.5.0, which lacks
#     `podman compose up -d --wait`. Unstable provides 1.6.0 without moving the
#     whole guest OS off stable.
{
  pkgs,
  lib,
  githubRunner,
  podmanCompose,
}:

let
  pkgsGuest = pkgs.extend (_final: _prev: {
    github-runner = githubRunner;
    podman-compose = podmanCompose;
  });
  eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.system;
    modules = [
      ../modules/ci-runner-guest.nix
      {
        nixpkgs.pkgs = pkgsGuest;
        # Avoid pulling interactive docs into the image.
        documentation.enable = false;
        documentation.nixos.enable = false;
        documentation.doc.enable = false;
        documentation.info.enable = false;
        documentation.man.enable = false;
      }
    ];
  };
in
import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
  inherit lib pkgs;
  inherit (eval) config;
  name = "ci-runner-guest-image";
  baseName = "ci-runner-base";
  format = "qcow2-compressed";
  partitionTableType = "legacy";
  diskSize = "auto";
  additionalSpace = "8G";
  copyChannel = false;
  memSize = 2048;
  label = "nixos";
}
