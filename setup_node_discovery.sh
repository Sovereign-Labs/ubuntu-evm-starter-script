#!/bin/bash
#
# setup_node_discovery.sh - Installs and configures the node-discovery service
#
# This script builds the node-discovery binary from the rollup-starter repository
# and sets it up as a systemd service. The service queries a PostgreSQL database
# for cluster information and writes it to a file that nginx can serve.
#
# Usage:
#   ./setup_node_discovery.sh <branch_name> <db_secret_arn> <region> <db_host> <db_port> <db_name>
#
# Arguments:
#   branch_name    - Git branch to checkout from rollup-starter repo
#   db_secret_arn  - AWS Secrets Manager ARN containing database credentials
#   region         - AWS region for Secrets Manager
#   db_host        - PostgreSQL database host
#   db_port        - PostgreSQL database port
#   db_name        - PostgreSQL database name


set -e

BRANCH_NAME="$1"
DB_SECRET_ARN="$2"
REGION="$3"
DB_HOST="$4"
DB_PORT="$5"
DB_NAME="$6"


export HOME=/root

ROLLUP_STARTER_REPO="https://github.com/Sovereign-Labs/rollup-starter"
ROLLUP_STARTER_DIR="$HOME/rollup-starter"
NODE_DISCOVERY_CRATE_MANIFEST="${ROLLUP_STARTER_DIR}/crates/utils/node-discovery/Cargo.toml"
OUTPUT_FILE="/usr/local/openresty/nginx/conf/cluster_info.txt"

if ! command -v git >/dev/null 2>&1; then
   echo "Installing git..."
   yum install -y git
fi

yum install -y gcc gcc-c++

if ! command -v aws >/dev/null 2>&1; then
  yum install -y awscli
fi

if ! command -v jq >/dev/null 2>&1; then
  yum install -y jq
fi

if [ -z "$DB_SECRET_ARN" ] || [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$DB_NAME" ]; then
  echo "Error: Missing database parameters. Need DB_SECRET_ARN, DB_HOST, DB_PORT, DB_NAME."
  exit 1
fi

echo "Retrieving database credentials..."
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region "$REGION" --query SecretString --output text)
DB_USERNAME=$(echo "$SECRET_JSON" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r .password)

DATABASE_URL="postgresql://$DB_USERNAME:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"
export DATABASE_URL
echo "Database connection string constructed"


if ! command -v cargo >/dev/null 2>&1; then
  # Install Rust toolchain for building node-discovery binary
  echo "Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi

if [ ! -d "${ROLLUP_STARTER_DIR}/.git" ]; then
  echo "Cloning rollup-starter repo: $BRANCH_NAME"
  git clone "${ROLLUP_STARTER_REPO}" "${ROLLUP_STARTER_DIR}"
fi


git -C "${ROLLUP_STARTER_DIR}" fetch origin "${BRANCH_NAME}"
git -C "${ROLLUP_STARTER_DIR}" checkout "${BRANCH_NAME}"

echo "Building cluster info binary..."
cargo build --release --manifest-path "${NODE_DISCOVERY_CRATE_MANIFEST}"

echo "Installing binary to /usr/local/bin..."
cp "${ROLLUP_STARTER_DIR}/target/release/node-discovery" /usr/local/bin/

echo "Ensuring output file exists and is writable..."
install -d -m 0755 "$(dirname "$OUTPUT_FILE")"
if [ ! -f "$OUTPUT_FILE" ]; then
  install -m 0644 /dev/null "$OUTPUT_FILE"
fi

echo "Creating systemd service for ClusterInfo...."
cat > /etc/systemd/system/node-discovery.service << EOF
[Unit]
Description=ClusterInfo
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/node-discovery --database-url "${DATABASE_URL}" --output-file "${OUTPUT_FILE}"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node-discovery
systemctl start node-discovery

if ! systemctl is-active --quiet node-discovery; then
  echo "ERROR: Cluster info failed to start"
  exit 1
fi

echo "ClusterInfo service installed and running"
