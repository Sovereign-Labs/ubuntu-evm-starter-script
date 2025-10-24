#!/bin/bash
# Set up a fresh ubuntu 22.04 instance to run the rollup
#
# Usage: setup.sh [POSTGRES_CONNECTION_STRING] [QUICKNODE_API_TOKEN] [QUICKNODE_HOST] [CELESTIA_KEY_SEED]
#   POSTGRES_CONNECTION_STRING: If provided, skip local postgres setup (optional)
#   QUICKNODE_API_TOKEN: Quicknode API token for Celestia (optional)
#   QUICKNODE_HOST: Quicknode hostname for Celestia (optional)
#   CELESTIA_KEY_SEED: Celestia key seed phrase for recovery (optional)
#
#   Example: setup.sh "postgres://user:pass@host:5432/dbname" "abc123" "restless-black-isle.celestia-mocha.quiknode.pro" "word1 word2 ..."

# Exit on any error
set -e

# Parse arguments
POSTGRES_CONN_STRING="${1:-}"
QUICKNODE_API_TOKEN="${2:-}"
QUICKNODE_HOST="${3:-}"
CELESTIA_KEY_SEED="${4:-}"

# Determine the target user (ubuntu if running as root, otherwise current user)
if [ "$EUID" -eq 0 ]; then
    TARGET_USER="ubuntu"
else
    TARGET_USER="$USER"
fi
echo "Running setup for user: $TARGET_USER"

# Set file descriptor limit
#ulimit -n 65536
sudo tee -a /etc/security/limits.conf > /dev/null << 'EOF'
  *               soft    nofile          65536
  *               hard    nofile          65536
EOF

# Install system dependencies
sudo apt update
sudo apt install -y clang make llvm-dev libclang-dev libssl-dev pkg-config docker.io docker-compose jq

# Install Rust as the target user
echo "Installing Rust as $TARGET_USER"
sudo -u $TARGET_USER bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
export PATH="/home/$TARGET_USER/.cargo/bin:$PATH"

# Setup starter repo as target user
echo "Cloning rollup-starter as $TARGET_USER"
cd /home/$TARGET_USER
sudo -u $TARGET_USER git clone https://github.com/Sovereign-Labs/rollup-starter.git
cd rollup-starter
sudo -u $TARGET_USER git switch preston/evm-starter

# Find the largest unmounted block device for rollup state storage
# This avoids hardcoding nvme1n1 which might be the root volume on some AWS instances
LARGEST_UNMOUNTED=$(lsblk -ndo NAME,SIZE,MOUNTPOINT,TYPE | \
    awk 'NF==3 && $3=="disk" {print $2,$1}' | \
    sort -hr | head -n1 | awk '{print $2}')

if [ -z "$LARGEST_UNMOUNTED" ]; then
    echo "Error: No unmounted block devices found. Cannot set up rollup-state storage."
    exit 1
fi

DEVICE="/dev/$LARGEST_UNMOUNTED"
echo "Using $DEVICE (largest unmounted block device) for rollup-state storage"

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
sudo mkfs.ext4 -F "$DEVICE" && sudo mkdir -p "$ROLLUP_STATE_DIR" && sudo mount -o noatime "$DEVICE" "$ROLLUP_STATE_DIR"
# Add the new directory to /etc/fstab
echo "$DEVICE $ROLLUP_STATE_DIR ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo chown -R $TARGET_USER:$TARGET_USER "$ROLLUP_STATE_DIR"


# Put docker's data on our newly mounted disk
DOCKER_DATA_DIR="$ROLLUP_STATE_DIR/docker"
mkdir -p "$DOCKER_DATA_DIR"
# Docker daemon runs as root, but we need to ensure proper permissions
# The docker data directory should be owned by root since docker daemon runs as root
# sudo chown -R root:root "$DOCKER_DATA_DIR"
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
# Reapply usermod
exec newgrp docker

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
find . -name "*.toml" -type f -exec sed -i "s|postgres://postgres:sequencerdb@localhost:5432/rollup|$POSTGRES_CONN_STRING|g" {} \;
find . -name "*.toml" -type f -exec sed -i "s|# postgres://postgres:sequencerdb@localhost:5432/rollup|$POSTGRES_CONN_STRING|g" {} \; # Still replace if the line is commented out

# Build the rollup as target user
cd /home/$TARGET_USER/rollup-starter
echo "Building rollup as $TARGET_USER"
sudo -u $TARGET_USER bash -c 'source $HOME/.cargo/env && cargo build --release'
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

# ---------- Install Celestia -----------
if [ -z "$QUICKNODE_API_TOKEN" ] || [ -z "$QUICKNODE_HOST" ] || [ -z "$CELESTIA_KEY_SEED" ]; then
	echo "No QuickNode API token provided, skipping Celestia setup"
else
	# TODO: determine genesis and config file paths
  #	ROLLUP_GENESIS_FILE="/home/$TARGET_USER/rollup-starter/genesis/genesis.json"
  #	ROLLUP_CONFIG_FILE="/home/$TARGET_USER/rollup-starter/rollup_config.toml"

	# Run the Celestia setup script
	bash "$(dirname "$0")/setup_celestia_quicknode.sh" \
		"$TARGET_USER" \
		"$QUICKNODE_API_TOKEN" \
		"$QUICKNODE_HOST" \
		"$CELESTIA_KEY_SEED"
fi


# Setup the observability stack as target user
cd /home/$TARGET_USER
sudo -u $TARGET_USER git clone https://github.com/Sovereign-Labs/sov-observability.git
cd sov-observability
sudo -u $TARGET_USER make start # Now your grafana is at localhost:3000. Username: admin, passwor: admin123

sudo mkdir -p /etc/systemd/journald.conf.d && sudo tee /etc/systemd/journald.conf.d/rollup.conf > /dev/null << 'EOF'
[Journal]
SystemMaxUse=50G
SystemKeepFree=10G
MaxRetentionSec=30day
EOF
sudo systemctl restart systemd-journald

sudo tee /etc/systemd/system/rollup.service > /dev/null << EOF
[Unit]
Description=Rollup Service
After=network.target

[Service]
Type=simple
User=$TARGET_USER
WorkingDirectory=/home/$TARGET_USER/rollup-starter
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
