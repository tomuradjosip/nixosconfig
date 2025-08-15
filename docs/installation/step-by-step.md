# Step-by-Step Installation

This guide provides detailed instructions for installing NixOS with ZFS mirror and dual ESP (EFI System Partition) setup.

## Step 1: Boot NixOS Installation ISO

1. **Flash the NixOS ISO to a USB drive**
2. **Boot from the USB drive**
3. **Connect to the internet**:

### Ethernet Connection
```bash
# Ethernet should connect automatically
# Verify connection:
ping -c 3 google.com
```

### WiFi Connection
```bash
# Start WiFi services
sudo systemctl start wpa_supplicant

# Configure WiFi
sudo wpa_cli
> add_network
> set_network 0 ssid "Your-WiFi-Name"
> set_network 0 psk "Your-WiFi-Password"
> enable_network 0
> quit

# Verify connection
ping -c 3 google.com
```

## Step 2: Enable SSH Access (Optional but Recommended)

For easier installation (copy/paste commands from another machine):

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

### Format ESP (EFI System Partition) Partitions
```bash
sudo mkfs.fat -F 32 ${DISK1}-part1
sudo mkfs.fat -F 32 ${DISK2}-part1
```

### Create ZFS Mirror Pool
```bash
sudo zpool create -f -o ashift=12 -O mountpoint=none -O atime=off -O compression=lz4 rpool mirror ${DISK1}-part2 ${DISK2}-part2
```

### Create ZFS Datasets
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

# Do not mount ESP (/boot) here, we don't want it in the hardware-configuration.nix
```

## Step 8: Clone Configuration and Prepare Secrets

### Clone the Configuration
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
sudo chown -R 1000:1000 /mnt/persist/home/$USERNAME
```

### Create Secrets Configuration
```bash
# Create the secrets directory
sudo mkdir -p /mnt/persist/etc/secrets/config/

# Copy template to the proper location
sudo cp /mnt/persist/home/$USERNAME/nixosconfig/secrets.nix.template /mnt/persist/etc/secrets/config/secrets.nix

# Set secure permissions
sudo chmod 600 /mnt/persist/etc/secrets/config/secrets.nix
sudo chown root:root /mnt/persist/etc/secrets/config/secrets.nix
```

### Edit Secrets File
```bash
# Edit the secrets file
sudo vi /mnt/persist/etc/secrets/config/secrets.nix
```

**Required changes**:
- Replace `your-username` with your chosen username
- Replace `your-hostname` with your chosen hostname
- Set your timezone (find yours: `timedatectl list-timezones | grep your-region`)
- Add your SSH public keys (for remote access to this machine)
- Set your disk IDs (the ones you noted above)
- Set SSH private key filename (generated locally, for access to e.g. github)
- Generate ZFS host ID: `head -c 8 /etc/machine-id`

### Create Password Hash Files
```bash
# Create password directory
sudo mkdir -p /mnt/persist/etc/secrets/passwords

# Generate password hash for root
echo "Enter root password: "
sudo mkpasswd -m sha-512 | sudo tee /mnt/persist/etc/secrets/passwords/root

# Generate password hash for your user
echo "Enter $USERNAME password: "
sudo mkpasswd -m sha-512 | sudo tee /mnt/persist/etc/secrets/passwords/$USERNAME

# Secure the files
sudo chmod 600 /mnt/persist/etc/secrets/passwords/*
```

## Step 9: Generate Hardware Configuration

```bash
# Generate hardware configuration
sudo nixos-generate-config --root /mnt

# Copy the generated hardware configuration to the secrets directory
sudo cp /mnt/etc/nixos/hardware-configuration.nix /mnt/persist/etc/secrets/config/hardware-configuration.nix

# Set secure permissions
sudo chmod 600 /mnt/persist/etc/secrets/config/hardware-configuration.nix
sudo chown root:root /mnt/persist/etc/secrets/config/hardware-configuration.nix
```

## Step 10: Install NixOS

```bash
# Create a temporary symlink in the host environment for flake evaluation
sudo ln -sf /mnt/persist/etc/secrets /etc/secrets

# Mount primary ESP
sudo mount ${DISK1}-part1 /mnt/boot

# Install using your flake configuration
sudo nixos-install --no-root-passwd --impure --flake /mnt/persist/home/$USERNAME/nixosconfig#$HOSTNAME --root /mnt
```

**Note**: This step may take 30-60 minutes depending on your internet connection.

## Step 11: Reboot and Verify

### Clean Unmount and Reboot
```bash
sudo umount /mnt/boot
sudo umount /mnt/nix
sudo umount /mnt/persist
sudo reboot
```

Proceed to [First Boot Setup](first-boot.md)
