{ pkgs, ... }:

{
  environment.systemPackages = [ pkgs.virt-manager ];

  boot.kernelModules = [ "kvm-intel" ];

  virtualisation.libvirtd = {
    enable = true;
    qemu.package = pkgs.qemu_kvm;
    allowedBridges = [
      "virbr0"
      "br0"
    ];
  };
}
