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
MONITORING_URL=""
INFLUX_TOKEN=""
HOSTNAME=""
ALLOY_PASSWORD=""
BRANCH_NAME="preston/update-to-nightly"
MONITORING_URL=""
MOCK_DA_CONNECTION_STRING=""

while [[ $# -gt 0 ]]; do
    case $1 in
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
		--monitoring-url)
			MONITORING_URL="$2"
			shift 2
			;;
        -h|--help)
            echo "Usage: setup.sh [OPTIONS]"
            echo "  --monitoring-url <string>            : Monitoring instance URL for metrics (optional, do not include http://)"
            echo "  --influx-token <string>              : InfluxDB authentication token (optional)"
            echo "  --hostname <string>                  : Hostname of this box for metrics reporting (optional)"
            echo "  --alloy-password <string>            : Grafana Alloy password for central config (optional)"
            echo "  --branch-name <string>               : Branch name to checkout (optional)"
            echo "  --mock-da-connection-string <string> : Postgres connection string for mock DA (optional)"
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


# Build the rollup as target user
cd /home/$TARGET_USER/rollup-starter
echo "Building mock da as $TARGET_USER"
sudo -u $TARGET_USER bash -c 'source $HOME/.cargo/env && cargo build --release --bin mock-da-server'
cd /home/$TARGET_USER

# Check that the mock da connection string was provided
if [ -z "$MOCK_DA_CONNECTION_STRING" ]; then
    echo "No connection string provided. Exiting"
    exit 1
fi

echo "Creating systemd service for mock-da"
sudo tee /etc/systemd/system/mock-da.service > /dev/null << EOF
[Unit]
Description=Mock DA Service
After=network.target

[Service]
Type=simple
User=$TARGET_USER
WorkingDirectory=/home/$TARGET_USER/rollup-starter
ExecStart=/home/$TARGET_USER/rollup-starter/target/release/mock-da-server --db "${MOCK_DA_CONNECTION_STRING}"
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable mock-da && sudo systemctl start mock-da
echo "Setup complete! mock-da service is running."
