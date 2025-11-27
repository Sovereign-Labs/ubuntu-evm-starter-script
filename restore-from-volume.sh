#!/bin/bash
# Restore rollup data from an EBS volume or snapshot
#
# Usage: restore-from-volume.sh <volume-id-or-snapshot-id>
#   volume-id: Existing EBS volume to restore from (e.g., vol-abc123)
#   snapshot-id: EBS snapshot to create volume from and restore (e.g., snap-abc123)
#
# This script will:
# 1. Stop the rollup service and observability stack
# 2. Detach current EBS backing volume
# 3. Attach specified volume (or create from snapshot)
# 4. Re-establish bcache with new backing device
# 5. Pre-warm the cache by reading all data through bcache
# 6. Restart services

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <volume-id-or-snapshot-id>"
    echo "  volume-id: Existing EBS volume (e.g., vol-abc123)"
    echo "  snapshot-id: EBS snapshot to restore from (e.g., snap-abc123)"
    exit 1
fi

RESTORE_FROM="$1"
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

echo "========================================="
echo "Rollup Data Restoration Script"
echo "========================================="
echo "Instance ID: $INSTANCE_ID"
echo "Region: $REGION"
echo "Availability Zone: $AZ"
echo "Restore from: $RESTORE_FROM"
echo ""

# Detect if input is a snapshot or volume
if [[ "$RESTORE_FROM" == snap-* ]]; then
    echo "Detected snapshot ID. Will create new volume from snapshot."
    SNAPSHOT_ID="$RESTORE_FROM"
    RESTORE_VOLUME_ID=""
elif [[ "$RESTORE_FROM" == vol-* ]]; then
    echo "Detected volume ID. Will attach existing volume."
    RESTORE_VOLUME_ID="$RESTORE_FROM"
    SNAPSHOT_ID=""
else
    echo "Error: Invalid input. Must be volume-id (vol-*) or snapshot-id (snap-*)"
    exit 1
fi

# Confirm before proceeding
echo ""
echo "WARNING: This will:"
echo "  1. Stop the rollup service"
echo "  2. Detach current EBS volume"
echo "  3. Attach and restore from $RESTORE_FROM"
echo "  4. Pre-warm NVMe cache (may take 20-30 minutes)"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Step 1: Stopping services..."
sudo systemctl stop rollup
cd /home/ubuntu/sov-observability && sudo -u ubuntu sg docker -c 'make stop' || true
cd /home/ubuntu

echo ""
echo "Step 2: Finding current storage devices from bcache..."

# Find bcache device
BCACHE_DEV=$(ls /dev/bcache* 2>/dev/null | head -n1)
if [ -z "$BCACHE_DEV" ]; then
    echo "Error: No bcache device found. Is the system set up correctly?"
    exit 1
fi
echo "Current bcache device: $BCACHE_DEV"

# Get backing device and cache device from bcache
BCACHE_NAME=$(basename $BCACHE_DEV)
BCACHE_SYSFS="/sys/block/$BCACHE_NAME/bcache"

if [ ! -d "$BCACHE_SYSFS" ]; then
    echo "Error: bcache sysfs not found at $BCACHE_SYSFS"
    exit 1
fi

# Find backing device (EBS)
BACKING_DEV_NAME=$(basename $(readlink -f /sys/block/$BCACHE_NAME/bcache/backing_dev_name))
CURRENT_EBS="/dev/$BACKING_DEV_NAME"
echo "Current EBS backing device: $CURRENT_EBS"

# Get current EBS volume ID
CURRENT_VOLUME_ID=$(sudo nvme id-ctrl -v "$CURRENT_EBS" 2>/dev/null | grep "^sn" | awk '{print $3}' | tr -d ' ')
if [ -z "$CURRENT_VOLUME_ID" ] || [[ "$CURRENT_VOLUME_ID" != vol-* ]]; then
    echo "Error: Could not get volume ID from $CURRENT_EBS"
    exit 1
fi
echo "Current volume ID: $CURRENT_VOLUME_ID"

# Find cache device (NVMe)
# Get cache set UUID from bcache
CACHE_SET_UUID=$(cat $BCACHE_SYSFS/cache/set 2>/dev/null | cut -d/ -f6)
if [ -z "$CACHE_SET_UUID" ]; then
    echo "Error: Could not find cache set UUID"
    exit 1
fi
echo "Cache set UUID: $CACHE_SET_UUID"

# Find the cache device by checking which device has this cache set
CACHE_DEVICE=""
for cache_dir in /sys/fs/bcache/$CACHE_SET_UUID/cache*; do
    if [ -d "$cache_dir" ]; then
        # The directory name is like "cache0", and there's a symlink "block" pointing to the device
        CACHE_DEV_NAME=$(basename $(readlink -f $cache_dir/dev))
        CACHE_DEVICE="/dev/$CACHE_DEV_NAME"
        break
    fi
done

if [ -z "$CACHE_DEVICE" ]; then
    echo "Error: Could not find NVMe cache device"
    exit 1
fi
echo "Current NVMe cache device: $CACHE_DEVICE"

echo ""
echo "Step 3: Unmounting and disabling bcache..."
sudo umount /home/ubuntu/rollup-starter/rollup-state || true

# Detach cache from backing device
echo "Detaching cache from backing device..."
if [ -d "$BCACHE_SYSFS/cache" ]; then
    echo 1 | sudo tee $BCACHE_SYSFS/detach || true
    sleep 2
fi

# Stop bcache backing device
echo "Stopping bcache backing device..."
echo 1 | sudo tee /sys/block/$BCACHE_NAME/bcache/stop || true
sleep 2

# Unregister bcache cache device (we'll recreate it for a fresh cache)
echo "Unregistering bcache cache device..."
if [ -d "/sys/fs/bcache/$CACHE_SET_UUID" ]; then
    echo 1 | sudo tee /sys/fs/bcache/$CACHE_SET_UUID/unregister || true
fi
sleep 2

echo "bcache disabled"

echo ""
echo "Step 4: Detaching current EBS volume..."
aws ec2 detach-volume --volume-id "$CURRENT_VOLUME_ID" --region "$REGION"
echo "Waiting for volume to detach..."
aws ec2 wait volume-available --volume-ids "$CURRENT_VOLUME_ID" --region "$REGION"
echo "Current volume detached: $CURRENT_VOLUME_ID"

# Tag the old volume for potential cleanup
aws ec2 create-tags --resources "$CURRENT_VOLUME_ID" --region "$REGION" --tags \
    "Key=Status,Value=Detached" \
    "Key=DetachedAt,Value=$(date -Iseconds)" \
    "Key=ReplacedBy,Value=$RESTORE_FROM"

echo ""
if [ -n "$SNAPSHOT_ID" ]; then
    echo "Step 5: Creating new volume from snapshot..."
    NEW_VOLUME_ID=$(aws ec2 create-volume \
        --snapshot-id "$SNAPSHOT_ID" \
        --availability-zone "$AZ" \
        --volume-type gp3 \
        --iops 16000 \
        --throughput 1000 \
        --encrypted \
        --region "$REGION" \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=restored-from-$SNAPSHOT_ID},{Key=InstanceId,Value=$INSTANCE_ID},{Key=RestoredAt,Value=$(date -Iseconds)}]" \
        --query 'VolumeId' \
        --output text)

    echo "New volume created: $NEW_VOLUME_ID"
    echo "Waiting for volume to be available..."
    aws ec2 wait volume-available --volume-ids "$NEW_VOLUME_ID" --region "$REGION"
    RESTORE_VOLUME_ID="$NEW_VOLUME_ID"
else
    echo "Step 5: Using existing volume: $RESTORE_VOLUME_ID"
fi

echo ""
echo "Step 6: Attaching restore volume..."
aws ec2 attach-volume \
    --volume-id "$RESTORE_VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device /dev/sdf \
    --region "$REGION"

echo "Waiting for volume to attach..."
sleep 5
# Wait for device to appear
for i in {1..30}; do
    if lsblk -ndo NAME,SERIAL 2>/dev/null | grep -q "$RESTORE_VOLUME_ID"; then
        echo "Volume attached successfully"
        break
    fi
    sleep 2
done

# Find the new EBS device path
NEW_EBS_DEVICE=$(lsblk -ndo NAME,SERIAL 2>/dev/null | grep "$RESTORE_VOLUME_ID" | awk '{print "/dev/"$1}')
if [ -z "$NEW_EBS_DEVICE" ]; then
    echo "Error: Could not find newly attached EBS device"
    exit 1
fi
echo "New EBS device path: $NEW_EBS_DEVICE"

echo ""
echo "Step 7: Setting up bcache with new backing device and fresh cache..."

# Wipe the NVMe cache device and create fresh bcache cache
echo "Creating fresh bcache cache on NVMe (this resets the cache to empty)..."
sudo wipefs -a "$CACHE_DEVICE"
sudo make-bcache -C "$CACHE_DEVICE" --wipe-bcache

# The EBS volume should already have bcache superblock from previous setup
# Register it as backing device
echo "Registering EBS backing device..."
echo "$NEW_EBS_DEVICE" | sudo tee /sys/fs/bcache/register
sleep 3

# Find the bcache device that was created
BCACHE_DEV=$(ls /dev/bcache* 2>/dev/null | head -n1)
if [ -z "$BCACHE_DEV" ]; then
    echo "Error: bcache device not found after registering backing device"
    exit 1
fi
echo "bcache device: $BCACHE_DEV"

# Attach cache to backing device
CACHE_SET_UUID=$(sudo bcache-super-show "$CACHE_DEVICE" | grep "cset.uuid" | awk '{print $2}')
if [ -z "$CACHE_SET_UUID" ]; then
    echo "Error: Could not get cache set UUID"
    exit 1
fi
echo "Attaching cache (UUID: $CACHE_SET_UUID) to backing device..."
echo "$CACHE_SET_UUID" | sudo tee /sys/block/$(basename $BCACHE_DEV)/bcache/attach
sleep 2

# Configure bcache for optimal performance
echo "Configuring bcache settings..."
BCACHE_SYSFS="/sys/block/$(basename $BCACHE_DEV)/bcache"
echo writeback | sudo tee $BCACHE_SYSFS/cache_mode
echo 0 | sudo tee $BCACHE_SYSFS/sequential_cutoff
echo 10 | sudo tee $BCACHE_SYSFS/writeback_percent
echo 30 | sudo tee $BCACHE_SYSFS/writeback_delay
echo 8000 | sudo tee $BCACHE_SYSFS/writeback_rate_minimum

echo "bcache setup complete"

echo ""
echo "Step 8: Mounting filesystem..."
sudo mount -o noatime "$BCACHE_DEV" /home/ubuntu/rollup-starter/rollup-state
sudo chown -R ubuntu:ubuntu /home/ubuntu/rollup-starter/rollup-state
echo "Filesystem mounted"

echo ""
echo "Step 9: Pre-warming NVMe cache (this will take time)..."
echo "Reading all data through bcache to populate NVMe cache..."
echo "This ensures full NVMe performance when the rollup starts."
echo ""

# Use dd to read the entire bcache device sequentially
# This populates the cache with all data from the backing device
DEVICE_SIZE=$(blockdev --getsize64 "$BCACHE_DEV")
DEVICE_SIZE_GB=$((DEVICE_SIZE / 1024 / 1024 / 1024))
echo "Reading $DEVICE_SIZE_GB GB through bcache cache..."

# Use pv if available for progress, otherwise use dd with status=progress
if command -v pv >/dev/null 2>&1; then
    sudo dd if="$BCACHE_DEV" bs=1M iflag=direct | pv -s "$DEVICE_SIZE" > /dev/null
else
    sudo dd if="$BCACHE_DEV" of=/dev/null bs=1M iflag=direct status=progress
fi

echo ""
echo "Cache pre-warming complete! Verifying cache performance..."

# Clear all stats from warming phase (not meaningful for actual usage)
echo 1 | sudo tee $BCACHE_SYSFS/clear_stats > /dev/null

# Do test read to verify cache is working (read a couple of GB)
echo "Running test read to verify cache hit rate..."
sudo dd if="$BCACHE_DEV" of=/dev/null bs=1M count=2048 iflag=direct 2>/dev/null

# Check cache hit rate (should be ~100% since data is now in cache)
if [ -f "$BCACHE_SYSFS/stats_total/cache_hits" ]; then
    CACHE_HITS=$(cat $BCACHE_SYSFS/stats_total/cache_hits)
    CACHE_MISSES=$(cat $BCACHE_SYSFS/stats_total/cache_misses)
    TOTAL=$((CACHE_HITS + CACHE_MISSES))
    if [ $TOTAL -gt 0 ]; then
        HIT_RATE=$((CACHE_HITS * 100 / TOTAL))
        echo "✓ Cache verification: $CACHE_HITS hits, $CACHE_MISSES misses ($HIT_RATE% hit rate)"
        if [ $HIT_RATE -gt 99 ]; then
            echo "✓ Cache is working optimally!"
        else
            echo "⚠ Warning: Cache hit rate is lower than expected. May need investigation."
        fi
    fi
fi

echo ""
echo "Step 10: Restarting services..."
cd /home/ubuntu/sov-observability && sudo -u ubuntu sg docker -c 'make start'
sudo systemctl start rollup
cd /home/ubuntu

echo ""
echo "========================================="
echo "Restoration complete!"
echo "========================================="
echo "Old volume: $CURRENT_VOLUME_ID (detached, tagged for cleanup)"
echo "New volume: $RESTORE_VOLUME_ID (attached)"
echo "NVMe cache: Pre-warmed with all data"
echo "Services: Restarted"
echo ""
echo "The rollup should now have full NVMe performance from the start."
echo ""
echo "Check rollup service status: sudo systemctl status rollup"
echo "Check rollup logs: sudo journalctl -u rollup -f"
