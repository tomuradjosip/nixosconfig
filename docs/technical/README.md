# Technical Details

Deep dive into the technical architecture and design decisions behind this NixOS configuration.

## System Architecture

### Overview
This configuration implements a layered approach to system reliability:

```
┌─────────────────────────────────────────┐
│            User Applications            │
├─────────────────────────────────────────┤
│          NixOS Configuration            │
├─────────────────────────────────────────┤
│         Custom Automation Layer         │
├─────────────────────────────────────────┤
│      ZFS + Dual ESP (Boot Partitions)   │
├─────────────────────────────────────────┤
│            Hardware Layer               │
└─────────────────────────────────────────┘
```

## Design Principles

### Redundancy Strategy
This system eliminates single points of failure through dual disk storage with ZFS mirroring, dual ESP (EFI System Partition) partitions for boot redundancy, and automated ESP synchronization services that ensure consistent boot environments across both drives.

### Security Through Impermanence
The system achieves security through immutable state where the root filesystem is rebuilt on each boot, ensuring only essential data persists with clear separation of concerns. Persistence is handled explicitly through declarative configuration that provides controlled data retention.

### Modularity and Maintainability
Each module handles a single system aspect with clear interfaces between components, enabling independent testing and updates. The entire approach follows configuration-as-code principles with declarative system configuration, version-controlled changes, and reproducible builds.

## Why This Setup?

### Advantages Over Traditional Approaches

**vs. Traditional RAID + GRUB**:
- ✅ No GRUB embedding issues with RAID
- ✅ Native UEFI booting with systemd-boot
- ✅ Automatic ESP synchronization
- ✅ ZFS integrity checking and self-healing

**vs. Standard NixOS Installation**:
- ✅ Enhanced security through impermanence
- ✅ Automated redundancy management
- ✅ Simplified maintenance procedures
- ✅ Better disaster recovery


### Trade-offs and Limitations

**Complexity**:
- Requires understanding of ZFS and UEFI
- More complex initial setup

**Hardware Requirements**:
- Requires two storage devices
- UEFI-only (no BIOS support)
- Minimum RAM requirements for ZFS

**Software Constraints**:
- NixOS-specific solution
- Flake-based configuration required

## Technical Implementation

### Boot Process
The boot sequence follows a reliable path: UEFI firmware selects an available ESP, systemd-boot loads from the chosen partition, the Linux kernel starts with ZFS support, initrd imports the ZFS pool and mounts datasets, systemd initializes with an impermanent root, and finally NixOS activation configures the complete system state.

### Storage Layout
```
Disk 1: /dev/disk/by-id/primary
├── ESP (512MB, FAT32)          # Primary boot partition
└── ZFS (remaining, ZFS)        # Half of mirror

Disk 2: /dev/disk/by-id/secondary
├── ESP (512MB, FAT32)          # Secondary boot partition
└── ZFS (remaining, ZFS)        # Half of mirror

ZFS Pool: rpool (mirror)
├── rpool/nix     → /nix        # Nix store (immutable)
└── rpool/persist → /persist    # Persistent data

Memory:
└── tmpfs         → /           # Temporary root (RAM)
```

### Failure Scenarios and Responses

| Scenario | System Response | Recovery Action |
|----------|----------------|-----------------|
| Primary disk failure | UEFI boots from secondary ESP, ZFS continues degraded | Replace disk, ZFS resilvers automatically |
| Secondary disk failure | System continues normally on primary | Replace disk, ZFS resilvers automatically |
| ESP corruption | UEFI tries other ESP automatically | ESP sync repairs from good ESP |
| ZFS corruption | ZFS self-healing activates | Scrub repairs from redundant data |
| System hang | Safe reboot (impermanent root) | Investigate logs after reboot |
| Config error | Boot older generation from menu | Fix configuration, rebuild |
