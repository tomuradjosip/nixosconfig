# Installation Guide

This guide will walk you through installing NixOS with a robust, redundant storage setup featuring ZFS mirroring and dual ESP (EFI System Partition) boot redundancy.

## What You'll Get

- **ZFS mirroring** for data redundancy
- **Dual ESP partitions** for boot redundancy
- **Stable device identifiers** to prevent issues when hardware changes
- **systemd-boot** for modern UEFI booting
- **Impermanent root filesystem** for enhanced security

## Installation Process

1. **[Prerequisites](prerequisites.md)** - Check system requirements
2. **[Step-by-Step Installation](step-by-step.md)** - Complete installation process
3. **[First Boot Setup](first-boot.md)** - Post-installation configuration

## Overview

This setup provides maximum reliability by mirroring both your data (via ZFS) and boot partitions (via dual ESPs). If either disk fails, your system continues working without interruption.

The installation process involves:
- Partitioning two disks identically
- Setting up ZFS mirror for data storage
- Creating dual ESP partitions for boot redundancy
- Installing NixOS with impermanence configuration
- Configuring automatic ESP synchronization
