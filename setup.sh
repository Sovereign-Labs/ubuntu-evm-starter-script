#!/bin/bash
# Set up a fresh ubuntu 22.04 instance to run the rollup
#
# Usage: setup.sh [POSTGRES_CONNECTION_STRING]
#   If POSTGRES_CONNECTION_STRING is provided, skip local postgres setup
#   Example: setup.sh "postgres://user:pass@host:5432/dbname"

# Exit on any error
set -e

# Parse arguments
POSTGRES_CONN_STRING="${1:-}"

# Set file descriptor limit
ulimit -n 65536
sudo tee -a /etc/security/limits.conf > /dev/null << 'EOF'
  *               soft    nofile          65536
  *               hard    nofile          65536
EOF

# Install system dependencies
sudo apt update
sudo apt install -y clang make llvm-dev libclang-dev libssl-dev pkg-config docker.io docker-compose jq
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y # Install Rust
. "$HOME/.cargo/env"

# Setup starter repo
cd /home/ubuntu
git clone https://github.com/Sovereign-Labs/rollup-starter.git
cd rollup-starter
git switch preston/evm-starter

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
if [ -d /home/ubuntu/rollup-starter/rollup-state ] && [ "$(ls -A /home/ubuntu/rollup-starter/rollup-state)" ]; then
    echo "Error: /home/ubuntu/rollup-starter/rollup-state exists and is not empty. Aborting to prevent data loss."
    exit 1
fi
# Remove the directory if it exists (but is empty)
rm -rf /home/ubuntu/rollup-starter/rollup-state
sudo mkfs.ext4 -F "$DEVICE" && sudo mkdir -p /home/ubuntu/rollup-starter/rollup-state && sudo mount -o noatime "$DEVICE" /home/ubuntu/rollup-starter/rollup-state
# Add the new directory to /etc/fstab
echo "$DEVICE /home/ubuntu/rollup-starter/rollup-state ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo chown -R $USER /home/ubuntu/rollup-starter/rollup-state


# Put docker's data on our newly mounted disk
mkdir -p /home/ubuntu/rollup-starter/rollup-state/docker
# Set docker data dir to
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
	"data-root": "/home/ubuntu/rollup-starter/rollup-state/docker"
}
EOF

# Restart docker to pick up the new data-root configuration
echo "Restarting docker to apply new data-root configuration"
sudo systemctl restart docker

# Add user to docker group
echo "Adding user to docker group"
sudo usermod -aG docker $USER

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
	# Update postgres connection string in rollup-starter config files
	echo "Updating postgres connection string in config files"
	cd /home/ubuntu/rollup-starter
	find . -name "*.toml" -type f -exec sed -i "s|postgres://postgres:sequencerdb@localhost:5432/rollup|$POSTGRES_CONN_STRING|g" {} \;
fi


# Build the rollup
cd /home/ubuntu/rollup-starter
echo "Building rollup"
cargo build --release
cd /home/ubuntu
 
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


# Setup the observability stack
git clone https://github.com/Sovereign-Labs/sov-observability.git
cd sov-observability
make start # Now your grafana is at localhost:3000. Username: admin, passwor: admin123

sudo mkdir -p /etc/systemd/journald.conf.d && sudo tee /etc/systemd/journald.conf.d/rollup.conf > /dev/null << 'EOF'
[Journal]
SystemMaxUse=50G
SystemKeepFree=10G
MaxRetentionSec=30day
EOF
sudo systemctl restart systemd-journald

sudo tee /etc/systemd/system/rollup.service > /dev/null << 'EOF'
[Unit]
Description=Rollup Service
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/rollup-starter
ExecStart=/home/ubuntu/rollup-starter/target/release/rollup
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable rollup && sudo systemctl start rollup
