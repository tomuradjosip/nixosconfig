# Configuration Guide

Learn how to customize and configure your NixOS system to meet your specific needs.

## Overview

This NixOS configuration is built with modularity in mind. Each aspect of the system is organized into focused modules that can be easily customized without affecting other components.

## Configuration Structure

```
configuration.nix           # Main system configuration entry point
modules/                    # Modular system configuration
├── storage.nix            # ZFS, boot, and ESP (boot partition) sync setup
├── networking.nix         # Network and SSH configuration
├── users.nix              # User accounts and SSH setup
├── packages.nix           # System and custom packages
├── shell.nix              # Shell configuration and aliases
├── persistence.nix        # Impermanence directory persistence
└── localization.nix       # Timezone and locale settings
```

## Quick Start Guides

- **[Module Overview](modules.md)** - Understand each module's purpose
- **[Customization Guide](customization.md)** - How to modify the configuration
- **[Secrets Management](secrets.md)** - Managing sensitive configuration

## Common Customizations

### Adding Software
When you need to install new software, you'll typically work with [`modules/packages.nix`](../../modules/packages.nix) for system-wide packages. Development tools can either be added there or organized into user-specific modules for better organization. Any services you want to run should be configured in their most appropriate module.

### Modifying Behavior
The beauty of this modular setup is that behavioral changes are straightforward to make. Shell settings and aliases live in [`modules/shell.nix`](../../modules/shell.nix), while network configurations and SSH settings are handled in [`modules/networking.nix`](../../modules/networking.nix). If you need to adjust what files and directories persist across reboots, you'll want to update the rules in [`modules/persistence.nix`](../../modules/persistence.nix). User account settings and permissions are managed through [`modules/users.nix`](../../modules/users.nix).

### System Settings
Core system configuration is spread across a few key files. Boot-related settings, including ZFS and ESP (EFI System Partition) sync configuration, are handled in [`modules/storage.nix`](../../modules/storage.nix). Timezone and locale preferences can be adjusted in [`modules/localization.nix`](../../modules/localization.nix), while hardware-specific settings should be updated in your [`hardware-configuration.nix`](../../hardware-configuration.nix) file.

## Configuration Workflow

1. **Edit** relevant module files
2. **Test** changes with `rbt`
3. **Apply** changes with `rb`
4. **Commit** changes to git

## Key Concepts

### Flakes
This configuration leverages Nix flakes to ensure your system builds are completely reproducible, no matter when or where you rebuild them. Flakes also handle dependency management automatically and provide proper system versioning, making it easy to track changes and roll back if needed.

### Impermanence
One of the most interesting aspects of this setup is that the root filesystem is completely temporary and gets reset on every boot. This means only the `/persist` and `/nix` directories survive reboots, with everything else starting fresh each time. Your configuration files determine exactly what data persists, enabling easier maintenance by limiting the accumulation of custom files and settings and forcing you to make changes through the configuration.

### Modularity
The entire system is designed around separation of concerns, with each aspect of your NixOS setup living in its own focused module. This approach makes the configuration much easier to understand and modify, since changes to one area won't unexpectedly affect others. It also means you can reuse components or share specific modules with other systems.
