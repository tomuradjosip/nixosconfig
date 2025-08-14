# First Boot Setup

Complete your system setup after the initial installation and first boot.

## Initial System Verification

After your first boot, verify that all systems are working correctly:

### Check System Status
```bash
# Check ZFS pool status
sudo zpool status rpool

# Check ESP (EFI System Partition) sync service
sudo systemctl status sync-esp.service

# Verify system generation
nixos-rebuild list-generations

# Check system logs for any errors
journalctl --since "1 hour ago" --priority=err
```

### Verify ESP Synchronization
```bash
# Check that both ESPs are in sync
sudo mkdir /tmp/esp-check
sudo mount /dev/disk/by-id/your-secondary-disk-part1 /tmp/esp-check
diff -r /boot/ /tmp/esp-check/
sudo umount /tmp/esp-check && sudo rmdir /tmp/esp-check

# Should show no differences if sync is working
```

## System Configuration Verification

### Test System Rebuild
```bash
# Test rebuild without changing system
sudo nixos-rebuild test --flake ~/nixosconfig#$(hostname)
# Or use the alias:
rbt

# If test successful, switch to new configuration
sudo nixos-rebuild switch --flake ~/nixosconfig#$(hostname)
# Or use the alias:
rb
```

## Install Additional Software

### Add System Packages
Edit `modules/packages.nix` and add desired packages:

```nix
environment.systemPackages = with pkgs; [
  # Add your packages here
  firefox
  code-server
  docker
];
```

Then rebuild using the `rb` command.

### Enable Additional Services
Edit appropriate module files to enable services:

```nix
# In modules/networking.nix for network services
# In configuration.nix for system services
services.docker.enable = true;  # Example
```

Then rebuild using the `rb` command.
