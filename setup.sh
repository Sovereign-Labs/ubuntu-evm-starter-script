#!/bin/bash
# Set up a fresh ubuntu 22.04 instance to run the rollup
#
# Usage: setup.sh [OPTIONS]
#   --postgres-conn-string <string>      : Postgres connection string (optional, default: local postgres)
#   --quicknode-token <string>           : Quicknode API token for Celestia (optional)
#   --quicknode-host <string>            : Quicknode hostname for Celestia (optional)
#   --celestia-seed <string>             : Celestia key seed phrase for recovery (optional)
#   --monitoring-url <string>            : Monitoring URL for metrics (optional, do not include http://)
#   --influx-token <string>              : InfluxDB authentication token (optional)
#   --hostname <string>                  : Hostname for metrics reporting (optional)
#   --alloy-password <string>            : Grafana Alloy password for central config (optional)
#   --mock-da-connection-string <string> : Postgres connection string for mock DA (optional)
#
#   Example: setup.sh --quicknode-token "abc123" --quicknode-host "restless-black-isle.celestia-mocha.quiknode.pro" --celestia-seed "word1 word2 ..."
#   Example: setup.sh --postgres-conn-string "postgres://user:pass@host:5432/dbname" --quicknode-token "abc123" --quicknode-host "host" --celestia-seed "seed"
#   Example: setup.sh --monitoring-url "influx.example.com" --influx-token "mytoken123" --hostname "rollup-node-1" --alloy-password "mypassword"

# Exit on any error
set -e

# Parse arguments
POSTGRES_CONN_STRING=""
QUICKNODE_API_TOKEN=""
QUICKNODE_HOST=""
CELESTIA_KEY_SEED=""
MONITORING_URL=""
INFLUX_TOKEN=""
HOSTNAME=""
ALLOY_PASSWORD=""
BRANCH_NAME="theodore/update"
MOCK_DA_CONNECTION_STRING=""
IS_PRIMARY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --postgres-conn-string)
            POSTGRES_CONN_STRING="$2"
            shift 2
            ;;
        --quicknode-token)
            QUICKNODE_API_TOKEN="$2"
            shift 2
            ;;
        --quicknode-host)
            QUICKNODE_HOST="$2"
            shift 2
            ;;
        --celestia-seed)
            CELESTIA_KEY_SEED="$2"
            shift 2
            ;;
        --monitoring-url)
            MONITORING_URL="$2"
            shift 2
            ;;
        --influx-token)
            INFLUX_TOKEN="$2"
            shift 2
            ;;
        --hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        --alloy-password)
            ALLOY_PASSWORD="$2"
            shift 2
            ;;
        --branch-name)
            BRANCH_NAME="$2"
            shift 2
            ;;
        --mock-da-connection-string)
            MOCK_DA_CONNECTION_STRING="$2"
            shift 2
            ;;
        --is-primary)
            IS_PRIMARY=true
            shift
            ;;
        -h|--help)
            echo "Usage: setup.sh [OPTIONS]"
            echo "  --postgres-conn-string <string>      : Postgres connection string (optional)"
            echo "  --quicknode-token <string>           : Quicknode API token (optional)"
            echo "  --quicknode-host <string>            : Quicknode hostname (optional)"
            echo "  --celestia-seed <string>             : Celestia key seed phrase (optional)"
            echo "  --monitoring-url <string>            : Monitoring instance URL for metrics (optional, do not include http://)"
            echo "  --influx-token <string>              : InfluxDB authentication token (optional)"
            echo "  --hostname <string>                  : Hostname of this box for metrics reporting (optional)"
            echo "  --alloy-password <string>            : Grafana Alloy password for central config (optional)"
            echo "  --branch-name <string>               : Branch name to checkout (optional)"
            echo "  --mock-da-connection-string <string> : Postgres connection string for mock DA (optional)"
            echo "  --is-primary                         : Set this node as primary (optional, default: replica)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Determine the target user (ubuntu if running as root, otherwise current user)
if [ "$EUID" -eq 0 ]; then
    TARGET_USER="ubuntu"
else
    TARGET_USER="$USER"
fi
echo "Running setup for user: $TARGET_USER"

# Determine if Celestia should be set up
SETUP_CELESTIA=false
if [ -n "$QUICKNODE_API_TOKEN" ] && [ -n "$QUICKNODE_HOST" ] && [ -n "$CELESTIA_KEY_SEED" ]; then
    echo "Celestia parameters provided. Setting up celestia token: ${QUICKNODE_API_TOKEN}, host: ${QUICKNODE_HOST}, seed: ${CELESTIA_KEY_SEED}"
    SETUP_CELESTIA=true
else
    echo "Celestia parameters not fully provided, skipping Celestia setup. token: ${QUICKNODE_API_TOKEN}, host: ${QUICKNODE_HOST}, seed: ${CELESTIA_KEY_SEED}"
fi

# Set file descriptor limit
#ulimit -n 65536
sudo tee -a /etc/security/limits.conf > /dev/null << 'EOF'
  *               soft    nofile          65536
  *               hard    nofile          65536
EOF

# Install system dependencies
sudo apt update
sudo apt install -y clang make llvm-dev libclang-dev libssl-dev pkg-config docker.io docker-compose jq nvme-cli pv bcache-tools

# Install Rust as the target user
echo "Installing Rust as $TARGET_USER"
sudo -u $TARGET_USER bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
export PATH="/home/$TARGET_USER/.cargo/bin:$PATH"

# Setup starter repo as target user
echo "Cloning rollup-starter as $TARGET_USER"
cd /home/$TARGET_USER
sudo -u $TARGET_USER git clone https://github.com/Sovereign-Labs/rollup-starter.git
cd rollup-starter
echo "Checking out branch $BRANCH_NAME"
sudo -u $TARGET_USER git switch $BRANCH_NAME

# Detect EBS volumes and NVMe instance storage separately
# EBS volumes have serial numbers starting with "vol-"
# NVMe instance storage has serial numbers like "AWS[instance-id][disk-number]"

echo "Detecting storage devices..."

# Find all EBS volumes (sorted by size, largest first)
EBS_DEVICES=$(lsblk -nbdo NAME,SIZE,TYPE | \
    awk '$3=="disk" {print $2,$1}' | \
    while read size name; do
        if [[ "$name" == nvme* ]]; then
            SERIAL=$(sudo nvme id-ctrl -v /dev/$name 2>/dev/null | grep -i "^sn" | awk '{print $3}' | tr -d ' ')
            if [[ "$SERIAL" == vol* ]]; then
                echo "$size $name"
            fi
        fi
    done | sort -hr)

# Get largest EBS volume (this will be our backing store, not the small root volume)
LARGEST_EBS=$(echo "$EBS_DEVICES" | head -n1 | awk '{print $2}')

if [ -n "$LARGEST_EBS" ]; then
    EBS_DEVICE="/dev/$LARGEST_EBS"
    EBS_SIZE=$(echo "$EBS_DEVICES" | head -n1 | awk '{print $1}')
    echo "Found EBS backing volume: $EBS_DEVICE (size: $(numfmt --to=iec-i --suffix=B $EBS_SIZE))"
else
    EBS_DEVICE=""
    echo "Warning: No EBS backing volume found."
fi

# Find NVMe instance storage devices (exclude all EBS volumes)
NVME_DEVICES=$(lsblk -nbdo NAME,SIZE,TYPE | \
    awk '$3=="disk" {print $2,$1}' | \
    while read size name; do
        if [[ "$name" == nvme* ]]; then
            SERIAL=$(sudo nvme id-ctrl -v /dev/$name 2>/dev/null | grep -i "^sn" | awk '{print $3}' | tr -d ' ')
            # Include only instance storage (exclude EBS volumes with vol-* serial)
            if [[ "$SERIAL" != vol-* ]]; then
                echo "$size $name"
            fi
        fi
    done | sort -hr)

LARGEST_NVME=$(echo "$NVME_DEVICES" | head -n1 | awk '{print $2}')
SECOND_LARGEST_NVME=$(echo "$NVME_DEVICES" | head -n2 | tail -n1 | awk '{print $2}')

if [ -z "$LARGEST_NVME" ]; then
    echo "Error: No NVMe instance storage found. Cannot set up rollup-state storage."
    exit 1
fi

if [ -z "$SECOND_LARGEST_NVME" ]; then
    echo "Error: No second NVMe instance storage found for logs storage."
    exit 1
fi

# Primary data storage will use dm-writecache with NVMe as fast cache and EBS as backing store
CACHE_DEVICE="/dev/$LARGEST_NVME"
LOGS_DEVICE="/dev/$SECOND_LARGEST_NVME"
echo "Using $CACHE_DEVICE (NVMe instance storage) for fast cache layer"
echo "Using $LOGS_DEVICE (NVMe instance storage) for logs storage"

# This will be the device we mount at rollup-state (either dm-writecache or plain NVMe)
DEVICE="$CACHE_DEVICE"

# Mount the logs device and move all syslogging to it.
sudo mkdir -p /mnt/logs && sudo mkfs.ext4 -F "$LOGS_DEVICE" && sudo mount "$LOGS_DEVICE" /mnt/logs
# Get UUID of the logs device for stable fstab entry
LOGS_UUID=$(sudo blkid -s UUID -o value "$LOGS_DEVICE")
if ! grep -q "/mnt/logs" /etc/fstab; then
    echo "UUID=$LOGS_UUID /mnt/logs ext4 defaults 0 2" | sudo tee -a /etc/fstab
fi
sudo rsync -av /var/log/ /mnt/logs/

# Set proper permissions for /mnt/logs and common log files. Don't fail if the files don't exist
sudo chown root:syslog /mnt/logs
sudo chmod 755 /mnt/logs
sudo chown -R syslog:adm /mnt/logs/syslog* 2>/dev/null || true
sudo chown -R syslog:adm /mnt/logs/auth.log* 2>/dev/null || true
sudo chown -R syslog:adm /mnt/logs/kern.log* 2>/dev/null || true
sudo chown -R syslog:adm /mnt/logs/daemon.log* 2>/dev/null || true
sudo chown -R syslog:adm /mnt/logs/user.log* 2>/dev/null || true
sudo chown -R syslog:adm /mnt/logs/messages* 2>/dev/null || true
sudo chmod 640 /mnt/logs/*.log* 2>/dev/null || true

sudo sed -i 's|/var/log/|/mnt/logs/|g' /etc/rsyslog.d/50-default.conf
sudo sed -i 's|/var/log/|/mnt/logs/|g' /etc/logrotate.d/rsyslog
sudo systemctl restart rsyslog


# Check if rollup-state exists and is non-empty - if so, fail to prevent data loss
ROLLUP_STATE_DIR="/home/$TARGET_USER/rollup-starter/rollup-state"
if [ -d "$ROLLUP_STATE_DIR" ]; then
    # Count files other than .gitkeep
    FILE_COUNT=$(find "$ROLLUP_STATE_DIR" -mindepth 1 ! -name '.gitkeep' | wc -l)
    if [ "$FILE_COUNT" -gt 0 ]; then
        echo "Error: $ROLLUP_STATE_DIR exists and contains files other than .gitkeep. Aborting to prevent data loss."
        exit 1
    fi
    # Remove the directory if it exists (but only contains .gitkeep or is empty)
    rm -rf "$ROLLUP_STATE_DIR"
fi

# Set up storage with bcache if EBS backing store is available
if [ -n "$EBS_DEVICE" ]; then
    echo "Setting up bcache with NVMe cache and EBS backing store..."

    # Safety check: ensure EBS is empty (fresh install only)
    if sudo blkid "$EBS_DEVICE" | grep -q "TYPE="; then
        echo "Error: EBS volume $EBS_DEVICE already has a filesystem or superblock!"
        echo "This setup script is for fresh installations only."
        echo "To restore from an existing volume, use restore-from-volume.sh instead."
        sudo blkid "$EBS_DEVICE"
        exit 1
    fi

    echo "EBS volume is empty - proceeding with fresh bcache setup"

    # Create bcache backing device (EBS - 940GB)
    echo "Creating bcache backing device on $EBS_DEVICE..."
    sudo make-bcache -B "$EBS_DEVICE" --wipe-bcache

    # Create bcache cache device (NVMe - 950GB)
    echo "Creating bcache cache device on $CACHE_DEVICE..."
    sudo make-bcache -C "$CACHE_DEVICE" --wipe-bcache

    # Wait for bcache devices to appear
    echo "Waiting for bcache devices to initialize..."
    sleep 3

    # Find the bcache backing device (should be /dev/bcache0)
    BCACHE_DEV=$(ls /dev/bcache* 2>/dev/null | head -n1)
    if [ -z "$BCACHE_DEV" ]; then
        echo "Error: bcache device not found after creation"
        exit 1
    fi
    echo "bcache backing device created: $BCACHE_DEV"

    # Attach cache to backing device
    CACHE_SET_UUID=$(sudo bcache-super-show "$CACHE_DEVICE" | grep "cset.uuid" | awk '{print $2}')
    if [ -z "$CACHE_SET_UUID" ]; then
        echo "Error: Could not get cache set UUID"
        exit 1
    fi
    echo "Attaching cache (UUID: $CACHE_SET_UUID) to backing device..."
    echo "$CACHE_SET_UUID" | sudo tee /sys/block/$(basename $BCACHE_DEV)/bcache/attach

    # Wait for attachment
    sleep 2

    # Configure bcache for optimal performance and safety
    echo "Configuring bcache settings..."
    BCACHE_SYSFS="/sys/block/$(basename $BCACHE_DEV)/bcache"

    # Set writeback mode (writes go to cache, async writeback to backing)
    echo writeback | sudo tee $BCACHE_SYSFS/cache_mode

    # Disable sequential cutoff (prevent bypass of cache for large sequential reads)
    echo 0 | sudo tee $BCACHE_SYSFS/sequential_cutoff

    echo 10 | sudo tee $BCACHE_SYSFS/writeback_percent     # Trigger writeback at 10% dirty
    echo 30 | sudo tee $BCACHE_SYSFS/writeback_delay       # 30 second delay before writeback
    echo 8000 | sudo tee $BCACHE_SYSFS/writeback_rate_minimum  # Minimum writeback rate (KB/s)

    echo "bcache configured: writeback mode, no sequential bypass, 10% dirty threshold, 8MB/s min writeback"

    # Create ext4 filesystem on bcache device
    echo "Creating ext4 filesystem on bcache device..."
    sudo mkfs.ext4 -F "$BCACHE_DEV"

    # Mount bcache device
    DEVICE="$BCACHE_DEV"
    sudo mkdir -p "$ROLLUP_STATE_DIR"
    sudo mount -o noatime "$DEVICE" "$ROLLUP_STATE_DIR"

    # Add to fstab using bcache device path
    if ! grep -q "$ROLLUP_STATE_DIR" /etc/fstab; then
        echo "$BCACHE_DEV $ROLLUP_STATE_DIR ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
    fi

    echo "bcache setup complete - all I/O goes through NVMe with async writeback to EBS"
else
    # No EBS backing store - use NVMe directly (legacy behavior)
    echo "No EBS backing store found - using NVMe directly without replication"
    sudo mkfs.ext4 -F "$DEVICE"
    sudo mkdir -p "$ROLLUP_STATE_DIR"
    sudo mount -o noatime "$DEVICE" "$ROLLUP_STATE_DIR"

    ROLLUP_STATE_UUID=$(sudo blkid -s UUID -o value "$DEVICE")
    if ! grep -q "$ROLLUP_STATE_DIR" /etc/fstab; then
        echo "UUID=$ROLLUP_STATE_UUID $ROLLUP_STATE_DIR ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
    fi
fi

sudo systemctl daemon-reload
sudo chown -R $TARGET_USER:$TARGET_USER "$ROLLUP_STATE_DIR"



# Put docker's data on our newly mounted disk
DOCKER_DATA_DIR="$ROLLUP_STATE_DIR/docker"
sudo mkdir -p "$DOCKER_DATA_DIR"
# Docker daemon runs as root, so ensure proper ownership
sudo chown root:root "$DOCKER_DATA_DIR"
# Set docker data dir to
sudo tee /etc/docker/daemon.json > /dev/null << EOF
{
	"data-root": "$DOCKER_DATA_DIR"
}
EOF

# Restart docker to pick up the new data-root configuration
echo "Restarting docker to apply new data-root configuration"
sudo systemctl restart docker

# Add user to docker group
echo "Adding $TARGET_USER to docker group"
sudo usermod -aG docker $TARGET_USER

# Setup postgres - either local or remote
if [ -z "$POSTGRES_CONN_STRING" ]; then
    echo "No postgres connection string provided, setting up local postgres"
    echo "Starting postgres container"
    sg docker -c "docker run --name postgres -e POSTGRES_PASSWORD=sequencerdb -p 5432:5432 -d --restart=always postgres"
    echo "Waiting for postgres to be ready"
    sleep 3
    until sg docker -c "docker exec postgres pg_isready -U postgres" > /dev/null 2>&1; do
        echo "Waiting for postgres..."
        sleep 1
    done
    echo "Creating rollup database"
    sg docker -c "docker exec postgres psql -U postgres -c 'CREATE DATABASE rollup;'"
    POSTGRES_CONN_STRING="postgres://postgres:sequencerdb@localhost:5432/rollup"
else
    echo "Using remote postgres: $POSTGRES_CONN_STRING"
fi

# Update postgres connection string in rollup-starter config files
echo "Updating postgres connection string in config files"
cd /home/$TARGET_USER/rollup-starter
sudo find ./configs/ -name "*.toml" -type f -exec sed -i "s|postgres://postgres:sequencerdb@localhost:5432/rollup|$POSTGRES_CONN_STRING|g" {} \;
sudo find ./configs/ -name "*.toml" -type f -exec sed -i "s|# postgres_connection_string|postgres_connection_string|g" {} \; # Uncomment the postgres connection string
if [ -n "$MOCK_DA_CONNECTION_STRING" ]; then
    echo "Updating mock DA connection string in config files"
    sudo find ./configs/ -name "*.toml" -type f -exec sed -i "s|connection_string = \"sqlite://rollup-state/mock_da.sqlite?mode=rwc\"|connection_string = \"$MOCK_DA_CONNECTION_STRING\"|g" {} \; 
fi

# Update is_replica setting based on --is-primary flag
if [ "$IS_PRIMARY" = true ]; then
    echo "Configuring node as primary (is_replica=false)"
    sudo find ./configs/ -name "*.toml" -type f -exec sed -i "s|is_replica = true|is_replica = false|g" {} \;
else
    echo "Configuring node as replica (is_replica=true)"
fi

# Build the rollup as target user
cd /home/$TARGET_USER/rollup-starter
echo "Building rollup as $TARGET_USER"
if [ "$SETUP_CELESTIA" = true ]; then
    echo "Building with celestia_da feature"
    sudo -u $TARGET_USER bash -c 'source $HOME/.cargo/env && cargo build --release --features celestia_da --features mock_zkvm --no-default-features'
else
    echo "Building without celestia_da feature"
    sudo -u $TARGET_USER bash -c 'source $HOME/.cargo/env && cargo build --release'
fi
cd /home/$TARGET_USER
 
# ---------- INSTALL DOCKER COMPOSE ----------
# Add Docker's official GPG key and repository (if not already done)
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update and install the Compose plugin
sudo apt-get update
sudo apt-get install -y docker-compose-plugin
# ------------- END DOCKER COMPOSE -----------

# Configure systemd journal to use the larger mounted disk
# Use bind mount to redirect journal to larger disk
JOURNAL_DIR="/mnt/logs/journal"

echo "Configuring journal to use larger disk"
sudo mkdir -p "$JOURNAL_DIR"
sudo chown root:systemd-journal "$JOURNAL_DIR"
sudo chmod 2755 "$JOURNAL_DIR"

if [ ! -L /var/log/journal ]; then
    sudo ln -s $JOURNAL_DIR /var/log/journal
    echo "Created symlink from /var/log/journal to $JOURNAL_DIR"
else
    echo "ERROR: Symlink /var/log/journal already exists"
    exit 1
fi

# Configure journal limits - 50G is safe on the large mounted disk
echo "Restarting journald"
sudo mkdir -p /etc/systemd/journald.conf.d && sudo tee /etc/systemd/journald.conf.d/rollup.conf > /dev/null << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50G
SystemKeepFree=10G
MaxRetentionSec=30day
EOF
sudo systemctl restart systemd-journald
echo "Journald configured."


# ---------- Install Celestia -----------
if [ "$SETUP_CELESTIA" = false ]; then
	echo "Celestia parameters not provided, skipping Celestia setup"
else
  echo "Setting up celestia"
	# TODO: determine genesis and config file paths.
	# This probably work, but needs to be double checked
    ROLLUP_GENESIS_FILE="/home/$TARGET_USER/rollup-starter/configs/celestia/genesis.json"
    ROLLUP_CONFIG_FILE="/home/$TARGET_USER/rollup-starter/configs/celestia/rollup.toml"
    CELESTIA_DATA_DIR="/home/$TARGET_USER/rollup-starter/rollup-state/celestia-data"
    mkdir -p "$CELESTIA_DATA_DIR"

	# Run the Celestia setup script (use absolute path)
	CELESTIA_SCRIPT="$(cd "$(dirname "$0")" && pwd)/setup_celestia_quicknode.sh"
	sg docker -c "bash \"$CELESTIA_SCRIPT\" \"$TARGET_USER\" \"$QUICKNODE_API_TOKEN\" \"$QUICKNODE_HOST\" \"$CELESTIA_KEY_SEED\" \"$ROLLUP_GENESIS_FILE\" \"$ROLLUP_CONFIG_FILE\" \"$CELESTIA_DATA_DIR\""
fi


# Setup the observability stack as target user
echo "Setting up observability stack as $TARGET_USER"
cd /home/$TARGET_USER
sudo -u $TARGET_USER git clone https://github.com/Sovereign-Labs/sov-observability.git
cd sov-observability

# Configure telegraf with provided parameters
if [ -n "$MONITORING_URL" ] && [ -n "$INFLUX_TOKEN" ] && [ -n "$HOSTNAME" ]; then
    echo "Configuring telegraf with provided parameters"
    sudo -u $TARGET_USER git checkout preston/cfn-template
    sudo sed -i "s|{MONITORING_URL}|$MONITORING_URL|g" telegraf/telegraf.conf
    sudo sed -i "s|{INFLUX_TOKEN}|$INFLUX_TOKEN|g" telegraf/telegraf.conf
    sudo sed -i "s|{HOSTNAME}|$HOSTNAME|g" telegraf/telegraf.conf
else
    echo "Warning: Telegraf parameters not fully provided, using defaults from config file"
fi

# Configure Grafana Alloy with central config if password provided
if [ -n "$ALLOY_PASSWORD" ] && [ -n "$HOSTNAME" ]; then
    echo "Configuring Grafana Alloy with central config"
    sudo -u $TARGET_USER git checkout preston/cfn-template
    sudo sed -i "s|config.local.alloy|config.central.alloy|g" docker-compose.yml
    sudo sed -i "s|{ALLOY_PASSWORD}|$ALLOY_PASSWORD|g" grafana-alloy/config.central.alloy
    sudo sed -i "s|{HOSTNAME}|$HOSTNAME|g" grafana-alloy/config.central.alloy
else
    echo "Alloy password not provided (or missing monitoring hostname), using local config"
fi

sudo -u $TARGET_USER sg docker -c 'make start' # Now your grafana is at localhost:3000. Username: admin, passwor: admin123


echo "Creating systemd service for rollup"
sudo tee /etc/systemd/system/rollup.service > /dev/null << EOF
[Unit]
Description=Rollup Service
After=network.target

[Service]
Type=simple
User=$TARGET_USER
WorkingDirectory=/home/$TARGET_USER/rollup-starter
Environment="OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317"
Environment="SOV_ENVIRONMENT_NAME=$HOSTNAME"
ExecStart=/home/$TARGET_USER/rollup-starter/target/release/rollup
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable rollup && sudo systemctl start rollup
echo "Setup complete! Rollup service is running."
