#!/bin/bash
set -e

# Mock DA Server User Data Bootstrap Script
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
BRANCH_NAME=""

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
    *)
      echo "Unknown option: $1"
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

echo "Starting Mock DA user data script at $(date)"

# Install dependencies
apt-get update
apt-get install -y git curl awscli jq

# Get EC2 instance ID for hostname

echo "Downloading setup scripts from GitHub..."
curl -L https://raw.githubusercontent.com/Sovereign-Labs/ubuntu-evm-starter-script/nikolai/mock-da-server-scripts/setup_mock_da.sh -o /tmp/setup.sh
chmod +x /tmp/setup.sh
chown ubuntu:ubuntu /tmp/setup.sh

echo "Retrieving mock database credentials..."
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" --query SecretString --output text)
DB_USERNAME=$(echo "$SECRET_JSON" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r .password)

export MOCK_DA_DATABASE_URL="postgresql://$DB_USERNAME:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"
echo "Mock DA database connection string constructed $MOCK_DA_DATABASE_URL"

SETUP_ARGS=" --mock-da-connection-string \"$MOCK_DA_DATABASE_URL\""

if [ -n "$BRANCH_NAME" ]; then
  SETUP_ARGS="$SETUP_ARGS --branch-name \"$BRANCH_NAME\""
fi

# Execute the setup script as ubuntu user with sudo privileges
echo "Executing mock DA setup script as ubuntu user..."

sudo -u ubuntu -H MOCK_DA_DATABASE_URL="$MOCK_DA_DATABASE_URL" bash -c "sudo /tmp/setup.sh $SETUP_ARGS"

echo "Mock DA user data script completed at $(date)"
