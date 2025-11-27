#!/bin/bash
# Usage: setup_mock_da.sh [OPTIONS]
#   --postgres-conn-string <string>      : Postgres connection string (optional, default: local postgres)
#


# Exit on any error
set -e

# Parse arguments
HOSTNAME=""
BRANCH_NAME="main"
MOCK_DA_CONNECTION_STRING=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --branch-name)
            BRANCH_NAME="$2"
            shift 2
            ;;
        --mock-da-connection-string)
            MOCK_DA_CONNECTION_STRING="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: setup.sh [OPTIONS]"
            echo "  --mock-da-connection-string <string> : Postgres connection string for mock DA server"
            echo "  --branch-name <string>               : Branch name to checkout (optional)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [ -z "$MOCK_DA_CONNECTION_STRING" ]; then
    echo "No connection string provided. Exiting"
    exit 1
fi

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
sudo -u $TARGET_USER git switch "$BRANCH_NAME"


# Build the rollup as target user
cd /home/$TARGET_USER/rollup-starter
echo "Building mock da as $TARGET_USER"
sudo -u $TARGET_USER bash -c 'source $HOME/.cargo/env && cargo build --release --bin mock-da-server --no-default-features --features=mock_da_external,mock_zkvm'
cd /home/$TARGET_USER

echo "Creating systemd service for mock-da"
sudo tee /etc/systemd/system/mock-da.service > /dev/null << EOF
[Unit]
Description=Mock DA Service
After=network.target

[Service]
Type=simple
User=$TARGET_USER
WorkingDirectory=/home/$TARGET_USER/rollup-starter
ExecStart=/home/$TARGET_USER/rollup-starter/target/release/mock-da-server --host 0.0.0.0 --db "${MOCK_DA_CONNECTION_STRING}"
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable mock-da && sudo systemctl start mock-da
echo "Setup complete! mock-da-server service is running."
