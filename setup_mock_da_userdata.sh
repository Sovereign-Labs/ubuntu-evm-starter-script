#!/bin/bash
set -e

# Mock DA Server Setup Script
# This script is meant to be curled and executed on EC2 instance boot
#
# Usage:
#   curl -L <url>/setup_mock_da_userdata.sh | bash -s -- \
#     --secret-arn <arn> \
#     --region <region> \
#     --db-host <host> \
#     --db-port <port> \
#     --db-name <name> \
#     [--branch-name <branch>]

# Parse arguments
SECRET_ARN=""
REGION=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
BRANCH_NAME="main"

while [[ $# -gt 0 ]]; do
  case $1 in
    --secret-arn)
      SECRET_ARN="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --db-host)
      DB_HOST="$2"
      shift 2
      ;;
    --db-port)
      DB_PORT="$2"
      shift 2
      ;;
    --db-name)
      DB_NAME="$2"
      shift 2
      ;;
    --branch-name)
      BRANCH_NAME="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: setup_mock_da_userdata.sh [OPTIONS]"
      echo "  --secret-arn <arn>     : AWS Secrets Manager ARN for DB credentials"
      echo "  --region <region>      : AWS region"
      echo "  --db-host <host>       : Database host"
      echo "  --db-port <port>       : Database port"
      echo "  --db-name <name>       : Database name"
      echo "  --branch-name <branch> : Branch name to checkout (optional, default: main)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$SECRET_ARN" ] || [ -z "$REGION" ] || [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$DB_NAME" ]; then
  echo "Error: Missing required arguments"
  echo "Required: --secret-arn, --region, --db-host, --db-port, --db-name"
  exit 1
fi

# Log all output to file for debugging
exec > >(tee -a /var/log/user-data.log)
exec 2>&1

echo "Starting Mock DA setup script at $(date)"

# Install system dependencies
sudo apt-get update
sudo apt-get install -y git curl awscli jq clang make llvm-dev libclang-dev libssl-dev pkg-config

# Retrieve database credentials from AWS Secrets Manager
echo "Retrieving mock database credentials..."
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" --query SecretString --output text)
DB_USERNAME=$(echo "$SECRET_JSON" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r .password)

MOCK_DA_CONNECTION_STRING="postgresql://$DB_USERNAME:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"
echo "Mock DA database connection string constructed"

# Determine the target user (ubuntu if running as root, otherwise current user)
if [ "$EUID" -eq 0 ]; then
    TARGET_USER="ubuntu"
else
    TARGET_USER="$USER"
fi
echo "Running setup for user: $TARGET_USER"

# Set file descriptor limit
sudo tee -a /etc/security/limits.conf > /dev/null << 'EOF'
  *               soft    nofile          65536
  *               hard    nofile          65536
EOF

# Install Rust as the target user
echo "Installing Rust as $TARGET_USER"
sudo -H -u $TARGET_USER bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'

# Setup starter repo as target user
echo "Cloning rollup-starter as $TARGET_USER"
sudo -H -u $TARGET_USER git clone https://github.com/Sovereign-Labs/rollup-starter.git /home/$TARGET_USER/rollup-starter
sudo -H -u $TARGET_USER git -C /home/$TARGET_USER/rollup-starter switch "$BRANCH_NAME"

# Build the rollup as target user
echo "Building mock da as $TARGET_USER"
sudo -H -u $TARGET_USER bash -c 'source $HOME/.cargo/env && cargo build --manifest-path /home/'"$TARGET_USER"'/rollup-starter/Cargo.toml --release --bin mock-da-server --no-default-features --features=mock_da_external,mock_zkvm'

echo "Creating systemd service for mock-da"
sudo tee /etc/systemd/system/mock-da.service > /dev/null << EOF
[Unit]
Description=Mock DA Service
After=network.target

[Service]
Type=simple
User=$TARGET_USER
WorkingDirectory=/home/$TARGET_USER/rollup-starter
ExecStart=/home/$TARGET_USER/rollup-starter/target/release/mock-da-server --host 0.0.0.0 --db "${MOCK_DA_CONNECTION_STRING}" --block-time-ms=6000
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable mock-da && sudo systemctl start mock-da

echo "Mock DA setup complete at $(date)! mock-da-server service is running."
