# NixOS Installation Guide with ZFS Mirror and Dual ESP Setup

This guide will walk you through installing NixOS with a robust, redundant storage setup using:
- **ZFS mirroring** for data redundancy
- **Dual ESP partitions** for boot redundancy
- **Stable device identifiers** to prevent issues when hardware changes
- **systemd-boot** for modern UEFI booting

## Overview

This setup provides maximum reliability by mirroring both your data (via ZFS) and boot partitions (via dual ESPs). If either disk fails, your system continues working without interruption.

## Prerequisites

Before starting, ensure you have:

1. **Two identical disks** (recommended) or at least two disks of similar size
2. **NixOS installation ISO** - Download from [nixos.org](https://nixos.org/download.html)
3. **UEFI system** (not legacy BIOS)
4. **Network connection** during installation
5. **Your SSH public key** (optional but recommended)

## Step 1: Boot NixOS Installation ISO

1. Flash the NixOS ISO to a USB drive
2. Boot from the USB drive
3. Connect to the internet:
   ```bash
   # For Ethernet, it should connect automatically

   # For WiFi:
   sudo systemctl start wpa_supplicant
   sudo wpa_cli
   > add_network
   > set_network 0 ssid "Your-WiFi-Name"
   > set_network 0 psk "Your-WiFi-Password"
   > enable_network 0
   > quit
   ```

## Step 2: Enable SSH Access (Optional but Recommended)

For easier installation (copy/paste commands):

```bash
# Set password for the nixos user
sudo passwd nixos

# Start SSH service
sudo systemctl start sshd

# Find your IP address
ip addr show | grep "inet " | grep -v 127.0.0.1

# Now you can SSH from another machine:
# ssh nixos@<ip-address>
```

## Step 3: Identify Your Disks

Find your disks using stable identifiers that won't change:

```bash
# List all disks with stable identifiers
ls -la /dev/disk/by-id/

# Note down your disk IDs - they look like:
# ata-Samsung_SSD_970_EVO_Plus_1TB_S4XXXXXXXXXXXX
# ata-WDC_WD10EZEX-08WN4A0_WD-WCXXXXXXXXXX
```

**Important**: Write down these exact IDs - you'll need them throughout the installation.

## Step 4: Set Environment Variables

**Set environment variables** (replace with your values):
```bash
USERNAME="your-username"     # Your desired username
HOSTNAME="your-hostname"     # Your system hostname
DISK1="/dev/disk/by-id/your-primary-disk-id"     # First disk ID
DISK2="/dev/disk/by-id/your-secondary-disk-id"   # Second disk ID
```

## Step 5: Partition the Disks

Create identical partition layouts on both disks:

```bash
# Partition the first disk
sudo parted $DISK1 -- mklabel gpt
sudo parted $DISK1 -- mkpart ESP fat32 1MiB 512MiB
sudo parted $DISK1 -- set 1 esp on
sudo parted $DISK1 -- mkpart primary 512MiB 100%

# Partition the second disk
sudo parted $DISK2 -- mklabel gpt
sudo parted $DISK2 -- mkpart ESP fat32 1MiB 512MiB
sudo parted $DISK2 -- set 1 esp on
sudo parted $DISK2 -- mkpart primary 512MiB 100%
```

## Step 6: Format and Create Filesystems

1. **Format both ESP partitions**:
   ```bash
   sudo mkfs.fat -F 32 ${DISK1}-part1
   sudo mkfs.fat -F 32 ${DISK2}-part1
   ```

2. **Create ZFS mirror pool**:
   ```bash
   sudo zpool create -f -o ashift=12 -O mountpoint=none -O atime=off -O compression=lz4 rpool mirror ${DISK1}-part2 ${DISK2}-part2
   ```

3. **Create ZFS datasets**:
   ```bash
   sudo zfs create -o mountpoint=legacy rpool/nix
   sudo zfs create -o mountpoint=legacy rpool/persist
   ```

## Step 7: Mount Filesystems

```bash
# Create mount points
sudo mkdir -p /mnt/{nix,persist,boot}

# Mount ZFS datasets
sudo mount -t zfs rpool/nix /mnt/nix
sudo mount -t zfs rpool/persist /mnt/persist

# Mount primary ESP
sudo mount ${DISK1}-part1 /mnt/boot
```

## Step 8: Clone Configuration and Prepare Secrets

1. **Clone this configuration directly to the mounted system**:
   ```bash
   # Create the user's home directory
   sudo mkdir -p /mnt/persist/home/$USERNAME

   # Clone directly to the final location
   sudo git clone https://github.com/yourusername/nixosconfig.git /mnt/persist/home/$USERNAME/nixosconfig

   # Alternative: Download without git
   # cd /mnt/persist/home/$USERNAME
   # sudo wget https://github.com/yourusername/nixosconfig/archive/main.zip
   # sudo unzip main.zip
   # sudo mv nixosconfig-main nixosconfig

   # Set proper ownership
   sudo chown -R 1000:1000 /mnt/persist/home/$USERNAME/nixosconfig
   ```

2. **Create your secrets file**:
   ```bash
   # Create the secrets directory
   sudo mkdir -p /etc/secrets/config/

   # Copy template to the proper location
   sudo cp /mnt/persist/home/$USERNAME/nixosconfig/secrets.nix.template /etc/secrets/config/secrets.nix

   # Set secure permissions
   sudo chmod 600 /etc/secrets/config/secrets.nix
   sudo chown root:root /etc/secrets/config/secrets.nix
   ```

3. **Edit `/etc/secrets/config/secrets.nix`** with your information:
   ```bash
   # Edit the secrets file
   sudo vi /etc/secrets/config/secrets.nix
   ```
   - Replace `your-username` with your chosen username
   - Replace `your-hostname` with your chosen hostname
   - Set your timezone (find yours: `timedatectl list-timezones | grep your-region`)
   - Add your SSH public keys
   - Set your disk IDs (the ones you noted above)
   - Generate ZFS host ID: `head -c 8 /etc/machine-id`

4. **Create password hash files** (more secure than plain text):
   ```bash
   # Create password directory
   sudo mkdir -p /mnt/persist/etc/secrets/passwords

   # Generate password hash for root
   echo "Enter password for root user:"
   sudo mkpasswd -m sha-512 | sudo tee /mnt/persist/etc/secrets/passwords/root

   # Generate password hash for your user
   echo "Enter password for $USERNAME:"
   sudo mkpasswd -m sha-512 | sudo tee /mnt/persist/etc/secrets/passwords/$USERNAME

   # Secure the files
   sudo chmod 600 /mnt/persist/etc/secrets/passwords/*
   ```

## Step 9: Generate Hardware Configuration

```bash
# Generate hardware configuration
sudo nixos-generate-config --root /mnt

# Copy the generated hardware configuration to the secrets directory
sudo cp /mnt/etc/nixos/hardware-configuration.nix /etc/secrets/config/hardware-configuration.nix

# Set secure permissions
sudo chmod 600 /etc/secrets/config/hardware-configuration.nix
sudo chown root:root /etc/secrets/config/hardware-configuration.nix
```

## Step 10: Install NixOS

```bash
# Install using your flake configuration
sudo nixos-install --flake /mnt/persist/home/$USERNAME/nixosconfig#$HOSTNAME --root /mnt
```

## Step 11: Reboot and Verify

1. **Clean unmount and reboot**:
   ```bash
   sudo umount /mnt/boot
   sudo umount /mnt/nix
   sudo umount /mnt/persist
   sudo umount /mnt
   sudo reboot
   ```

2. **After first boot, verify the setup**:
   ```bash
   # Check ZFS status
   sudo zpool status rpool

   # Check ESP sync service
   sudo systemctl status sync-esp.service

   # Verify both ESPs are in sync
   sudo mkdir /tmp/esp-check
   sudo mount ${DISK2}-part1 /tmp/esp-check
   diff -r /boot/ /tmp/esp-check/
   sudo umount /tmp/esp-check && sudo rmdir /tmp/esp-check
   ```

## Post-Installation

Your system is now installed with full redundancy:

- **Data redundancy**: ZFS automatically mirrors all your data across both disks
- **Boot redundancy**: The sync-esp service keeps both ESP partitions identical
- **Hardware stability**: Using device IDs means disk order changes won't break your system

### Managing Your System

- **Update system**: `sudo nixos-rebuild switch --flake .#$HOSTNAME`
- **Add packages**: Edit `modules/packages.nix` and rebuild
- **Modify config**: Edit the appropriate module files and rebuild

### Testing Redundancy

To verify your redundancy works:
1. Shut down and physically disconnect one drive
2. Boot from the remaining drive - it should work normally
3. Reconnect the drive and ZFS will automatically resilver

---

## Technical Details

### Why This Setup?

**Advantages over traditional RAID + GRUB:**
- No GRUB embedding issues with RAID
- Native UEFI booting with systemd-boot
- Automatic ESP synchronization
- ZFS handles data integrity and mirroring
- Stable device identifiers prevent boot issues

### How Redundancy Works

- **Primary ESP**: `/boot` mounted from first disk
- **Secondary ESP**: Automatically synced after system updates
- **Data mirroring**: ZFS mirrors all data across both disks
- **Boot fallback**: UEFI can boot from either ESP if one fails

### Failure Scenarios

| Failure | System Response |
|---------|----------------|
| Disk 1 fails | Boot from Disk 2 ESP, ZFS continues with remaining disk |
| Disk 2 fails | Continue with Disk 1 ESP, ZFS continues with remaining disk |
| ESP corruption | Switch to backup ESP via UEFI boot menu |

### Device Stability

The `/dev/disk/by-id/` identifiers used in this setup are permanent and won't change even if you:
- Replug the disks
- Add/remove other storage devices
- Change UEFI boot order
- Hot-plug drives

This prevents the common issue where `/dev/sda` becomes `/dev/sdb` after hardware changes.
