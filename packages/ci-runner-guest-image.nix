# Builds a disposable NixOS CI runner base qcow2 image.
#
# githubRunner is injected from a newer nixpkgs (unstable) because GitHub
# deprecates old runner versions and refuses connections from them, while the
# runner in the immutable /nix/store cannot self-update. Pinning a current
# runner here + --disableupdate in the guest avoids both failure modes.
{
  pkgs,
  lib,
  githubRunner,
}:

let
  pkgsGuest = pkgs.extend (_final: _prev: { github-runner = githubRunner; });
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
