# NixOS Configuration with ZFS Mirror and Dual ESP

A NixOS setup with ZFS mirroring and dual ESP (EFI System Partition) boot partitions for redundancy, plus an impermanent root filesystem.

## ✨ Features

- **🔄 ZFS Mirroring** - Automatic data redundancy across two disks
- **🚀 Dual ESP Setup** - Boot redundancy with automatic ESP synchronization
- **🛡️ Impermanent Root** - Fresh system state on every boot for enhanced security
- **⚙️ Custom Management Tools** - Automated system maintenance and monitoring
- **📦 Modular Configuration** - Easy to understand and customize

## 🚀 Quick Start

### New Installation
1. **[📋 Check Prerequisites](docs/installation/prerequisites.md)** - Ensure you have everything needed
2. **[📖 Follow Installation Guide](docs/installation/step-by-step.md)** - Complete step-by-step process
3. **[⚡ Complete First Boot Setup](docs/installation/first-boot.md)** - Post-installation configuration

## Daily Usage

```bash
# Rebuild system
rb

# Test changes safely
rbt

# Check zfs mirror health
sudo zpool status rpool
```

## 📚 Documentation

- **[Installation](docs/installation/)** - How to set this up
- **[Configuration](docs/configuration/)** - How to customize it
- **[Technical Details](docs/technical/)** - How it all works

## 🔍 Key Files

```
configuration.nix     # Main config
modules/              # System modules
├── storage.nix       # ZFS and boot setup
├── networking.nix    # Network config
├── users.nix         # User accounts
├── packages.nix      # Installed software
├── shell.nix         # Shell setup
├── persistence.nix   # What survives reboots
└── localization.nix  # Timezone/locale
```

## 🤔 Why This Setup?

**Reliability**: If a disk dies, your system keeps running. ZFS handles the data, dual ESPs handle booting.

**Security**: Fresh filesystem on every boot means no persistent malware or config drift.

**Simplicity**: Automated tools handle the complex parts like ESP syncing and system maintenance.
