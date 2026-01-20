#!/bin/bash

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
PROXY_CRATE_MANIFEST="${ROLLUP_STARTER_DIR}/crates/utils/proxy/Cargo.toml"

echo "Checking for git... $BRANCH_NAME"
if ! command -v git >/dev/null 2>&1; then
   echo "Installing git..."
   yum install -y git
fi

yum install -y gcc gcc-c++
echo "Checking for git... $BRANCH_NAME $DB_SECRET_ARN $DB_HOST $DB_PORT $DB_NAME" 

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
  # Install Rust toolchain for building proxy binary
  echo "Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi


yum install -y gcc gcc-c++
if [ ! -d "${ROLLUP_STARTER_DIR}/.git" ]; then
  echo "Cloning rollup-starter repo..."
  echo "Checking for git... $BRANCH_NAME $DATABASE_URL"
  echo "Checking for git... $BRANCH_NAME $DB_SECRET_ARN $DB_HOST $DB_PORT $DB_NAME $DATABASE_URL" 

  git clone "${ROLLUP_STARTER_REPO}" "${ROLLUP_STARTER_DIR}"
fi


git -C "${ROLLUP_STARTER_DIR}" fetch origin "${ROLLUP_STARTER_BRANCH}"
git -C "${ROLLUP_STARTER_DIR}" checkout "${BRANCH_NAME}"

echo "Building cluster info binary..."
cargo build --release --manifest-path "${PROXY_CRATE_MANIFEST}"

echo "Installing binary to /usr/local/bin..."
cp "${ROLLUP_STARTER_DIR}/target/release/proxy" /usr/local/bin/
