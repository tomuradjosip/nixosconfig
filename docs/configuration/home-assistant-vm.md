# Home Assistant OS VM (libvirt on `br0`)

This assumes the host already uses scripted networking with **`br0`** (see [`modules/networking.nix`](../../modules/networking.nix)) and [`virtualisation.libvirtd.allowedBridges`](../../modules/virtualization.nix) includes **`br0`**.

## Prerequisites

- A Home Assistant OS disk image converted or installed to a qcow2 file (example path below: **`/data/homeassistant.qcow2`** — change if yours differs).
- The physical NIC is not held by another VM; stop/remove any old domain that used macvtap on the same link before changing networking.
- To **recreate** the VM from an existing disk, remove the old definition first:

```bash
sudo virsh destroy homeassistant 2>/dev/null || true
sudo virsh undefine homeassistant --nvram 2>/dev/null || true
```

## Import and start

```bash
sudo virt-install \
  --connect qemu:///system \
  --name homeassistant \
  --description "Home Assistant OS" \
  --os-variant=generic \
  --ram=4096 \
  --vcpus=2 \
  --disk /data/homeassistant.qcow2,bus=scsi \
  --controller type=scsi,model=virtio-scsi \
  --import \
  --graphics none \
  --boot uefi \
  --network bridge=br0,model=virtio \
  --noautoconsole
```

Start on boot:

```bash
sudo virsh autostart homeassistant
```

## Useful checks

```bash
sudo virsh list --all
sudo virsh domifaddr homeassistant
```
