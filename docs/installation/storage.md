# Advanced Storage Configurations

Add additional storage tiers to your NixOS system for enhanced performance and capacity.

> **📋 Prerequisites**: Complete the [Step-by-Step Installation](step-by-step.md) first, then return here to add storage tiers.

## 🎯 What You Can Add

Choose the storage tiers that fit your needs:

| **Tier** | **Hardware** | **Purpose** | **Technology** |
|----------|-------------|-------------|----------------|
| **Tier 2: Hot Data** | 2x NVMe drives | Active projects, frequently accessed files | ZFS mirror |
| **Tier 3: Bulk Storage** | 4x HDDs | Media, archives, backups | MergerFS + SnapRAID |

**Your existing setup:**
- **Tier 1**: 2x SSDs (OS/applications) - already configured

## 🧠 How It Works

Your system's storage is managed by `modules/storage.nix`, which automatically:

- **Detects available drives** based on your `secrets.nix` configuration
- **Creates mount points** for each tier you've configured
- **Sets up services** for SnapRAID sync/scrub (if HDDs are present)
- **Manages filesystems** (ZFS pools, MergerFS unions, etc.)

**When you add drives to `secrets.nix` and rebuild, the system automatically:**
1. Imports ZFS pools (if NVMe drives are configured)
2. Mounts MergerFS union (if HDDs are configured)
3. Starts background maintenance services
4. Creates directory structures (if configured)

## 🔧 Adding Storage Tiers

### Step 1: Identify Additional Drives

```bash
# List all storage devices
ls -la /dev/disk/by-id/

# Identify your additional drives:
# nvme-Samsung_SSD_980_PRO_2TB_S111111    # NVMe 1 (optional)
# nvme-Samsung_SSD_980_PRO_2TB_S222222    # NVMe 2 (optional)
# ata-WDC_WD40EZRZ-00GXCB0_WD-WCC123456  # HDD 1 (optional)
# ata-WDC_WD40EZRZ-00GXCB0_WD-WCC234567  # HDD 2 (optional)
# ata-WDC_WD40EZRZ-00GXCB0_WD-WCC345678  # HDD 3 (optional)
# ata-WDC_WD40EZRZ-00GXCB0_WD-WCC456789  # HDD 4 (optional)
```

### Step 2: Partition Additional Drives

Set environment variables and partition (only for drives you're adding):

#### For NVMe Drives (Tier 2)
```bash
# Set variables
DATA_DISK1="/dev/disk/by-id/your-first-nvme-id"
DATA_DISK2="/dev/disk/by-id/your-second-nvme-id"

# Partition NVMe drives
sudo parted $DATA_DISK1 -- mklabel gpt
sudo parted $DATA_DISK1 -- mkpart primary 1MiB 100%
sudo parted $DATA_DISK2 -- mklabel gpt
sudo parted $DATA_DISK2 -- mkpart primary 1MiB 100%
```

#### For HDDs (Tier 3)
```bash
# Set variables
BULK_DISK1="/dev/disk/by-id/your-first-hdd-id"
BULK_DISK2="/dev/disk/by-id/your-second-hdd-id"
BULK_DISK3="/dev/disk/by-id/your-third-hdd-id"
BULK_DISK4="/dev/disk/by-id/your-fourth-hdd-id"

# Partition HDDs
for disk in "$BULK_DISK1" "$BULK_DISK2" "$BULK_DISK3" "$BULK_DISK4"; do
  sudo parted "$disk" -- mklabel gpt
  sudo parted "$disk" -- mkpart primary 1MiB 100%
done
```

### Step 3: Create Filesystems

#### Tier 2: NVMe Hot Data (Optional)
```bash
# Create ZFS pool for hot data
sudo zpool create -f -o ashift=12 -O mountpoint=none -O atime=off -O compression=lz4 \
  dpool mirror ${DATA_DISK1}-part1 ${DATA_DISK2}-part1

# Create datasets
sudo zfs create -o mountpoint=legacy dpool/data
```

#### Tier 3: Bulk Storage (Optional)
```bash
# Format and mount HDDs
for i in {1..4}; do
  disk_var="BULK_DISK$i"
  disk_path="${!disk_var}-part1"
  sudo mkfs.ext4 -F "$disk_path"
  sudo mkdir -p "/mnt/disk$i"
  sudo mount "$disk_path" "/mnt/disk$i"
done
```

### Step 4: Update Secrets Configuration

Edit your secrets file to include the new drives:

```bash
sudo vi /etc/secrets/config/secrets.nix
```

**Add your additional disk IDs:**
- **For Tier 2 (NVMe)**: Add `dataPrimary` and `dataSecondary` with your NVMe disk IDs
- **For Tier 3 (HDDs)**: Add `bulk = [...]` with your HDD disk IDs (use the exact IDs from Step 1)
- **For bulk directories**: Add `bulkStorageDirectories = [...]` with your preferred directory names (optional)

### Step 5: Apply Configuration

Rebuild your system to activate the new storage configuration:

```bash
rb
```

The system will automatically configure your additional storage tiers.

## 🎮 After Installation

### Storage Layout

Your system will have:

```
/                    # Temporary root (tmpfs)
├── nix/             # Nix store (Tier 1: SSD)
├── persist/         # Persistent data (Tier 1: SSD)
├── data/            # Hot data (Tier 2: NVMe) - if configured
├── bulk/            # Bulk storage (Tier 3: HDDs) - if configured
│   ├── Media/       # Example configurable directories
│   ├── Archive/
│   └── Downloads/
│   └── Backup/
```

### Management Commands

```bash
# Check all storage
bulk-storage status

# ZFS operations
sudo zpool status
sudo zfs list

# Bulk storage operations (if configured)
bulk-storage sync     # Update SnapRAID parity
bulk-storage scrub    # Verify integrity
bulk-storage usage    # Usage report
```

### Automated Maintenance

The system handles:
- **Daily**: SnapRAID parity updates
- **Weekly**: Data integrity checks on all tiers
- **Weekly**: SSD/NVMe trim operations

## 🚨 Troubleshooting

**Bulk storage not mounting:**
```bash
sudo systemctl status setup-bulk-disks
ls -la /dev/disk/by-id/ata-*
```

**SnapRAID issues:**
```bash
bulk-storage sync
cat /etc/snapraid.conf
```

## 📖 Related Documentation

- **[Step-by-Step Installation](step-by-step.md)** - Start here for basic setup
- **[First Boot Setup](first-boot.md)** - Post-installation configuration
