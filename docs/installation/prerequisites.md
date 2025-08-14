# Prerequisites

Before starting the installation, ensure you have everything needed for a successful setup.

## Hardware Requirements

### Required Hardware

1. **Two identical disks** (recommended) or at least two disks of similar size

2. **UEFI system** (not legacy BIOS)


## Software Requirements

### Installation Media

1. **NixOS installation ISO**
   - Download from [nixos.org](https://nixos.org/download.html)
   - Use the latest stable release
   - Verify the download checksum

2. **USB drive** (8GB or larger)
   - For creating bootable installation media
   - Will be completely erased during flash process

### Preparation Tools

- **Disk flashing software**:
  - Linux: `dd`, `cp`, or GUI tools like Balena Etcher
  - Windows: Rufus, Balena Etcher
  - macOS: `dd`, Balena Etcher

## Important Notes

### Data Loss Warning

⚠️ **This installation will completely erase both target disks**

- Back up any important data before proceeding
- Double-check disk identifiers to avoid mistakes
- Ensure you're targeting the correct disks

### Disk Identification

- The installation uses `/dev/disk/by-id/` identifiers
- These provide stable device naming that won't change
- Have your disk IDs ready before starting installation
- Find them with: `ls -la /dev/disk/by-id/`

## Next Steps

Once you've confirmed all prerequisites:
- Continue to [Step-by-Step Installation](step-by-step.md)
