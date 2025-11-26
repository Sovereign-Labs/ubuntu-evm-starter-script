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
CELESTIA_GENESIS_DA_HEIGHT=""
CELESTIA_BATCH_NAMESPACE=""
MONITORING_URL=""
INFLUX_TOKEN=""
HOSTNAME=""
ALLOY_PASSWORD=""
BRANCH_NAME="main"
MOCK_DA_CONNECTION_STRING=""
IS_PRIMARY=false
EVM_PINNED_ADDRESSES=""

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
        --celestia-genesis-da-height)
            CELESTIA_GENESIS_DA_HEIGHT="$2"
            shift 2
            ;;
        --celestia-batch-namespace)
            CELESTIA_BATCH_NAMESPACE="$2"
            shift 2
            ;;
        --is-primary)
            IS_PRIMARY=true
            shift
            ;;
        --evm-pinned-addresses)
            EVM_PINNED_ADDRESSES="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: setup.sh [OPTIONS]"
            echo "  --postgres-conn-string <string>       : Postgres connection string (optional)"
            echo "  --quicknode-token <string>            : Quicknode API token (optional)"
            echo "  --quicknode-host <string>             : Quicknode hostname (optional)"
            echo "  --celestia-seed <string>              : Celestia key seed phrase (optional)"
            echo "  --monitoring-url <string>             : Monitoring instance URL for metrics (optional, do not include http://)"
            echo "  --influx-token <string>               : InfluxDB authentication token (optional)"
            echo "  --hostname <string>                   : Hostname of this box for metrics reporting (optional)"
            echo "  --alloy-password <string>             : Grafana Alloy password for central config (optional)"
            echo "  --branch-name <string>                : Branch name to checkout (optional)"
            echo "  --mock-da-connection-string <string>  : Postgres connection string for mock DA (optional)"
            echo "  --celestia-genesis-da-height <string> : Celestia height"
            echo "  --celestia-batch-namespace <string>   : Batch namespace name"
            echo "  --is-primary                          : Set this node as primary (optional, default: replica)"
            echo "  --evm-pinned-addresses                : List of comma separated EVM address for RAM pinning. (optional) for example --evm-pinned-addresses 0x006e4eb63413050681079338404e07a1d72ab697,0xe7d2b7610d1574610cbd903ea896c59d17470633"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done



echo "OBS PARAMETERS:"
echo "MONITORING_URL $MONITORING_URL"
echo "HOSTNAME $HOSTNAME"
echo "POSTGRES_CONN_STRING $POSTGRES_CONN_STRING"
echo "IS_PRIMARY $IS_PRIMARY"

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
    echo "Celestia parameters not fully provided, skipping Celestia setup. host: ${QUICKNODE_HOST}"
fi

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
sudo -u $TARGET_USER git switch $BRANCH_NAME

# Find the largest and second largest unmounted block devices
# This avoids hardcoding nvme1n1 which might be the root volume on some AWS instances
UNMOUNTED_DEVICES=$(lsblk -ndo NAME,SIZE,MOUNTPOINT,TYPE | \
    awk 'NF==3 && $3=="disk" {print $2,$1}' | \
    sort -hr)

LARGEST_UNMOUNTED=$(echo "$UNMOUNTED_DEVICES" | head -n1 | awk '{print $2}')
SECOND_LARGEST_UNMOUNTED=$(echo "$UNMOUNTED_DEVICES" | head -n2 | tail -n1 | awk '{print $2}')

if [ -z "$LARGEST_UNMOUNTED" ]; then
    echo "Error: No unmounted block devices found. Cannot set up rollup-state storage."
    exit 1
fi
if [ -z "$SECOND_LARGEST_UNMOUNTED" ]; then
    echo "Error: No second unmounted block device found. Logs will be stored on the root volume."
    exit 1
fi

DEVICE="/dev/$LARGEST_UNMOUNTED"
echo "Using $DEVICE (largest unmounted block device) for rollup-state storage"
LOGS_DEVICE="/dev/$SECOND_LARGEST_UNMOUNTED"
echo "Using $LOGS_DEVICE (second largest unmounted block device) for logs storage"

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

sudo mkfs.ext4 -F "$DEVICE" && sudo mkdir -p "$ROLLUP_STATE_DIR" && sudo mount -o noatime "$DEVICE" "$ROLLUP_STATE_DIR"
# Get UUID of the rollup-state device for stable fstab entry
ROLLUP_STATE_UUID=$(sudo blkid -s UUID -o value "$DEVICE")
# Add the new directory to /etc/fstab if not already present
if ! grep -q "$ROLLUP_STATE_DIR" /etc/fstab; then
    echo "UUID=$ROLLUP_STATE_UUID $ROLLUP_STATE_DIR ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
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
    sudo find ./configs/ -name "*.toml" -type f -exec   sed -i "s|127\.0\.0\.1|$MOCK_DA_CONNECTION_STRING|g" {} \;
fi

# Update is_replica setting based on --is-primary flag
if [ "$IS_PRIMARY" = true ]; then
    echo "Configuring node as primary (is_replica=false)"
    sudo find ./configs/ -name "*.toml" -type f -exec sed -i "s|is_replica.*|is_replica = false|g" {} \;
else
    echo "Configuring node as replica (is_replica=true)"
    sudo find ./configs/ -name "*.toml" -type f -exec sed -i "s|is_replica.*|is_replica = true|g" {} \;
fi

# ---------- Setup EVM Pinned addresses -----
ROLLUP_EXEC_CONFIG_FILE_CELESTIA="/home/$TARGET_USER/rollup-starter/configs/celestia/evm_pinned_cache.json"
ROLLUP_EXEC_CONFIG_FILE_MOCK_DA="/home/$TARGET_USER/rollup-starter/configs/mock/evm_pinned_cache.json"
ROLLUP_EXEC_CONFIG_FILE_MOCK_DA_EXTERNAL="/home/$TARGET_USER/rollup-starter/configs/mock_external/evm_pinned_cache.json"


echo "Setting up EVM pinned addresses: '$EVM_PINNED_ADDRESSES'"
echo "Execution config path: $ROLLUP_EXEC_CONFIG_FILE"
PINNED_ADDRESSES_SCRIPT="$(cd "$(dirname "$0")" && pwd)/setup_evm_pinned_addresses.sh"
"$PINNED_ADDRESSES_SCRIPT" "$ROLLUP_EXEC_CONFIG_FILE_CELESTIA" "$EVM_PINNED_ADDRESSES" "$TARGET_USER"
"$PINNED_ADDRESSES_SCRIPT" "$ROLLUP_EXEC_CONFIG_FILE_MOCK_DA" "$EVM_PINNED_ADDRESSES" "$TARGET_USER"
"$PINNED_ADDRESSES_SCRIPT" "$ROLLUP_EXEC_CONFIG_FILE_MOCK_DA_EXTERNAL" "$EVM_PINNED_ADDRESSES" "$TARGET_USER"
echo "Rollup execution configs after setup $ROLLUP_EXEC_CONFIG_FILE_CELESTIA:"
cat "$ROLLUP_EXEC_CONFIG_FILE_CELESTIA"
echo "Rollup execution configs after setup $ROLLUP_EXEC_CONFIG_FILE_MOCK_DA:"
cat "$ROLLUP_EXEC_CONFIG_FILE_MOCK_DA"
echo "Rollup execution configs after setup $ROLLUP_EXEC_CONFIG_FILE_MOCK_DA_EXTERNAL:"
cat "$ROLLUP_EXEC_CONFIG_FILE_MOCK_DA_EXTERNAL"
echo "Set up of EVM pinned addresses is done"
# ---------- END of setup EVM Pinned addresses -----


# ---------- Install Celestia -----------
if [ "$SETUP_CELESTIA" = false ]; then
	echo "Celestia parameters not provided, skipping Celestia setup"
else
  echo "Setting up celestia"
	# TODO: determine genesis and config file paths.
	# This probably work, but needs to be double checked
    ROLLUP_GENESIS_FILE="/home/$TARGET_USER/rollup-starter/configs/celestia/genesis.json"
    ROLLUP_CONFIG_FILE="/home/$TARGET_USER/rollup-starter/configs/celestia/rollup_aws.toml"

    ROLLUP_CONST_FILE="/home/$TARGET_USER/rollup-starter/constants.toml"
    CELESTIA_DATA_DIR="/home/$TARGET_USER/rollup-starter/rollup-state/celestia-data"
    mkdir -p "$CELESTIA_DATA_DIR"

	# Run the Celestia setup script (use absolute path)
	CELESTIA_SCRIPT="$(cd "$(dirname "$0")" && pwd)/setup_celestia_quicknode.sh"

    echo "TARGET_USER: $TARGET_USER"
    echo "QUICKNODE_HOST: $QUICKNODE_HOST"
    echo "ROLLUP_GENESIS_FILE: $ROLLUP_GENESIS_FILE"
    echo "ROLLUP_CONFIG_FILE: $ROLLUP_CONFIG_FILE"

    echo "ROLLUP_CONST_FILE: $ROLLUP_CONST_FILE"
    echo "CELESTIA_DATA_DIR: $CELESTIA_DATA_DIR"
    echo "CELESTIA_GENESIS_DA_HEIGHT: $CELESTIA_GENESIS_DA_HEIGHT"
    echo "CELESTIA_BATCH_NAMESPACE: $CELESTIA_BATCH_NAMESPACE"
    
    echo "START CELESTIA_SCRIPT"
	  sg docker -c "bash \"$CELESTIA_SCRIPT\" \"$TARGET_USER\" \"$QUICKNODE_API_TOKEN\" \"$QUICKNODE_HOST\" \"$CELESTIA_KEY_SEED\" \"$ROLLUP_GENESIS_FILE\" \"$ROLLUP_CONFIG_FILE\" \"$CELESTIA_DATA_DIR\" \"$CELESTIA_GENESIS_DA_HEIGHT\" \"$CELESTIA_BATCH_NAMESPACE\" \"$ROLLUP_CONST_FILE\""
fi


# Setup the observability stack as target user
echo "Setting up observability stack as $TARGET_USER"
cd /home/$TARGET_USER
sudo -u $TARGET_USER git clone https://github.com/Sovereign-Labs/sov-observability.git
cd sov-observability


# Configure Grafana Alloy with central config if password provided
if [ -n "$ALLOY_PASSWORD" ] && [ -n "$HOSTNAME" ]; then
    echo "Configuring Grafana Alloy with central config"
    ALLOY_CONFIG="config.central-template.alloy"
    sudo sed -i "s|config.local.alloy|$ALLOY_CONFIG|g" docker-compose.yml
    sudo sed -i "s|{HOSTNAME}|$HOSTNAME|g" "grafana-alloy/$ALLOY_CONFIG"
    sudo sed -i "s|{ALLOY_USER}|sov-logger|g" "grafana-alloy/$ALLOY_CONFIG"
    sudo sed -i "s|{ALLOY_PASSWORD}|$ALLOY_PASSWORD|g" "grafana-alloy/$ALLOY_CONFIG"
    sudo sed -i "s|{TEMPO_HOST}|tempo.sov-obs.xyz:443|g" "grafana-alloy/$ALLOY_CONFIG"
    sudo sed -i "s|{LOKI_HOST}|loki.sov-obs.xyz|g" "grafana-alloy/$ALLOY_CONFIG"
else
    echo "Alloy password not provided (or missing monitoring hostname), using local config"
fi

sudo -u $TARGET_USER sg docker -c 'make start-alloy-only'

echo "Configure telegraf with provided parameters"

if [ -n "$MONITORING_URL" ] && [ -n "$INFLUX_TOKEN" ] && [ -n "$HOSTNAME" ]; then
    echo "Configuring telegraf with provided parameters"
    wget -q https://repos.influxdata.com/influxdata-archive_compat.key
    echo '393e8779c89ac8d958f81f942f9ad7fb82a25e133faddaf92e15b16e6ac9ce4c influxdata-archive_compat.key' | sha256sum -c && cat influxdata-archive_compat.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg > /dev/null
    echo 'deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] https://repos.influxdata.com/debian stable main' | sudo tee /etc/apt/sources.list.d/influxdata.list
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" telegraf
    sudo -u $TARGET_USER git checkout main

    # Validate and replace hostname
    HOSTNAME_COUNT=$(grep -c "hostname = " telegraf/telegraf.conf || true)
    if [ "$HOSTNAME_COUNT" -ne 1 ]; then
        echo "Error: Expected exactly 1 'hostname = ' line in telegraf.conf, found $HOSTNAME_COUNT"
        exit 1
    fi
    sudo sed -i "s|hostname = .*|hostname = \"$HOSTNAME\"|g" telegraf/telegraf.conf

    # Replace hardcoded InfluxDB URL with monitoring URL
    sudo sed -i "s|urls = \[\"http://influxdb:8086\"\]|urls = [\"http://$MONITORING_URL:8086\"]|g" telegraf/telegraf.conf

    # Validate and replace token
    TOKEN_COUNT=$(grep -c "token = " telegraf/telegraf.conf || true)
    if [ "$TOKEN_COUNT" -ne 1 ]; then
        echo "Error: Expected exactly 1 'token = ' line in telegraf.conf, found $TOKEN_COUNT"
        exit 1
    fi
    sudo sed -i "s|token.*|token = \"$INFLUX_TOKEN\"|g" telegraf/telegraf.conf
    sudo sed -i "s|organization.*|organization = \"Sovereign Labs\"|g" telegraf/telegraf.conf
    sudo sed -i "s|bucket.*|bucket = \"sov-dev\"|g" telegraf/telegraf.conf

    # Validate and set environment tag to sov-testnet
    ENVIRONMENT_COUNT=$(grep -c "environment = " telegraf/telegraf.conf || true)
    if [ "$ENVIRONMENT_COUNT" -ne 1 ]; then
        echo "Error: Expected exactly 1 'environment = ' line in telegraf.conf, found $ENVIRONMENT_COUNT"
        exit 1
    fi
    sudo sed -i 's|environment.*|environment = "sov-testnet"|g' telegraf/telegraf.conf

    # Validate and set directories for filecount monitoring
    DIRECTORIES_COUNT=$(grep -c "directories = " telegraf/telegraf.conf || true)
    if [ "$DIRECTORIES_COUNT" -ne 1 ]; then
        echo "Error: Expected exactly 1 'directories = ' line in telegraf.conf, found $DIRECTORIES_COUNT"
        exit 1
    fi
    sudo sed -i "s|directories = .*|directories = [\"$ROLLUP_STATE_DIR/**\", \"/mnt/logs/**\"]|g" telegraf/telegraf.conf

    sudo cp telegraf/telegraf.conf /etc/telegraf/telegraf.conf
    sudo systemctl start telegraf
    sudo systemctl enable telegraf
else
    echo "Warning: Telegraf parameters not fully provided, using defaults from config file"
fi




# Build the rollup as target user
cd /home/$TARGET_USER/rollup-starter
echo "Building rollup as $TARGET_USER"
if [ "$SETUP_CELESTIA" = true ]; then
    echo "Building with celestia_da feature"
    sudo -u $TARGET_USER bash -c 'source $HOME/.cargo/env && cargo build --release --features celestia_da --features mock_zkvm --no-default-features'
else
    echo "Building without mock_da feature"
    sudo -u $TARGET_USER bash -c 'source $HOME/.cargo/env && cargo build --release --no-default-features --features=mock_da_external,mock_zkvm'
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


if [ -n "$MOCK_DA_CONNECTION_STRING" ]; then
    ROLLUP_CONFIG_FILE="/home/$TARGET_USER/rollup-starter/configs/mock_external/rollup_aws.toml"
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
ExecStart=/home/$TARGET_USER/rollup-starter/target/release/rollup --rollup-config-path $ROLLUP_CONFIG_FILE
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
