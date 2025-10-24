# Set up Celestia light node with Quicknode
#
# This script installs and configures a Celestia light node that connects to Quicknode.
# It will:
#   1. Install celestia binary
#   2. Configure authentication with Quicknode
#   3. Import a Celestia key from a seed phrase
#   4. Update the Celestia config with Core settings (IP, TLS, auth token)
#   5. Optionally update genesis.json and rollup_config.toml with Celestia credentials
#   6. Start the Celestia light node
#
# Usage: setup_celestia_quicknode.sh TARGET_USER QUICKNODE_API_TOKEN QUICKNODE_HOST CELESTIA_KEY_SEED [ROLLUP_GENESIS_FILE] [ROLLUP_CONFIG_FILE]
#
# Required arguments:
#   TARGET_USER: The user to run the Celestia node as (e.g., "ubuntu")
#   QUICKNODE_API_TOKEN: Your Quicknode API token
#   QUICKNODE_HOST: Quicknode hostname (without https://)
#   CELESTIA_KEY_SEED: The 24-word seed phrase for your Celestia key
#
# Optional arguments:
#   ROLLUP_GENESIS_FILE: Path to genesis.json to update with Celestia address (e.g., "/home/ubuntu/rollup-starter/genesis/genesis.json")
#   ROLLUP_CONFIG_FILE: Path to rollup_config.toml to update with Celestia credentials (e.g., "/home/ubuntu/rollup-starter/rollup_config.toml")
#
# Example:
#   ./setup_celestia_quicknode.sh \
#     ubuntu \
#     abc123def456 \
#     restless-black-isle.celestia-mocha.quiknode.pro \
#     "word1 word2 word3 ... word24" \
#     /home/ubuntu/rollup-starter/genesis/genesis.json \
#     /home/ubuntu/rollup-starter/rollup_config.toml
#
# References:
#   https://www.quicknode.com/guides/infrastructure/node-setup/run-a-celestia-light-node

set -e

# Parse arguments
TARGET_USER="${1:-}"
QUICKNODE_API_TOKEN="${2:-}"
QUICKNODE_HOST="${3:-}"
CELESTIA_KEY_SEED="${4:-}"
ROLLUP_GENESIS_FILE="${5:-}"
ROLLUP_CONFIG_FILE="${6:-}"
ROLLUP_KEY_NAME="rollup-key"

# Validate that QUICKNODE_HOST is a hostname, not a full URL
if [[ "$QUICKNODE_HOST" =~ ^https?:// ]]; then
    echo "Error: QUICKNODE_HOST should be a hostname only, not a full URL."
    echo "Example: a-b-c.celestia-mocha.quiknode.pro"
    echo "NOT: https://a-b-c.celestia-mocha.quiknode.pro/..."
    exit 1
fi

QUICKNODE_API_ENDPOINT="https://${QUICKNODE_HOST}/${QUICKNODE_API_TOKEN}/"

# TODO: Check docker, curl, jq

cd /home/"$TARGET_USER"

# Setup celestia binary
yes "1" | bash -c "$(curl -sL https://raw.githubusercontent.com/celestiaorg/docs/main/public/celestia-node.sh)" -- -v v0.27.5-mocha
sudo cp celestia-node-temp/celestia /usr/local/bin
celestia version

# Prepare Quicknode auth
mkdir -p /home/"$TARGET_USER"/.celestia-auth
tee > /home/"$TARGET_USER"/.celestia-auth/xtoken.json << EOF
{
 "x-token": "$QUICKNODE_API_TOKEN"
}
EOF
chmod 600 /home/"$TARGET_USER"/.celestia-auth/xtoken.json

celestia light init --p2p.network mocha
# Config
# TODO: CHECK
read -r TRUSTED_HEIGHT TRUSTED_HASH <<<"$(curl -s "${QUICKNODE_API_ENDPOINT}header" | jq -r '.result.header | "\(.height) \(.last_block_id.hash)"')" && export TRUSTED_HEIGHT TRUSTED_HASH && echo "Height: $TRUSTED_HEIGHT" && echo "Hash:   $TRUSTED_HASH"

# Update celestia config with trusted height and hash
echo "Updating celestia config with trusted height=${TRUSTED_HEIGHT} and hash=${TRUSTED_HASH}"
CELESTIA_CONFIG="/home/$TARGET_USER/.celestia-light-mocha-4/config.toml"
sed -i "s|SyncFromHeight = 0|SyncFromHeight = ${TRUSTED_HEIGHT}|g" "$CELESTIA_CONFIG"
sed -i "s|SyncFromHash = \"\"|SyncFromHash = \"${TRUSTED_HASH}\"|g" "$CELESTIA_CONFIG"
sed -i "s|DefaultKeyName.*|DefaultKeyName =\"${ROLLUP_KEY_NAME}\"|g" "$CELESTIA_CONFIG"

# Update Core settings in config
echo "Updating celestia config with Core settings"
sed -i "s|IP = \"\"|IP = \"${QUICKNODE_HOST}\"|g" "$CELESTIA_CONFIG"
sed -i "s|TLSEnabled = false|TLSEnabled = true|g" "$CELESTIA_CONFIG"
sed -i "s|XTokenPath = \"\"|XTokenPath = \"/home/${TARGET_USER}/.celestia-auth\"|g" "$CELESTIA_CONFIG"

# Celestia Keys. Note: test keyring backend
rm -r /home/"$TARGET_USER"/.celestia-light-mocha-4/keys
mkdir -p /home/"$TARGET_USER"/.celestia-light-mocha-4/keys
mkdir -p /home/"$TARGET_USER"/.celestia-app
chown -R "$TARGET_USER" /home/"$TARGET_USER"/.celestia-light-mocha-4/keys
echo "-----------------"
echo "$CELESTIA_KEY_SEED" | docker run \
  -v /home/"$TARGET_USER"/.celestia-light-mocha-4/keys:/mnt/keyring \
  -v /home/"$TARGET_USER"/.celestia-app:/.celestia-app \
  -i \
  --user $(id -u):$(id -g) \
  ghcr.io/celestiaorg/celestia-node:v0.28.2-arabica \
  cel-key --keyring-dir /mnt/keyring add $ROLLUP_KEY_NAME --recover

CELESTIA_ADDRESS=$(docker run \
  -v /home/"$TARGET_USER"/.celestia-light-mocha-4/keys:/mnt/keyring \
  -v /home/"$TARGET_USER"/.celestia-app:/.celestia-app \
  -i \
  --user $(id -u):$(id -g) \
  ghcr.io/celestiaorg/celestia-node:v0.28.2-arabica \
    cel-key \
    --keyring-dir /mnt/keyring list --output json \
    | grep -v '^Starting Celestia' | grep -v '^cel-key --keyring-dir' | grep -v '^$' \
    | jq -r ".[] | select(.name == \"$ROLLUP_KEY_NAME\") | .address" )
echo "-----------------"
echo "Imported address for sequencer: ${CELESTIA_ADDRESS}"

# Update genesis file if provided
if [ -n "$ROLLUP_GENESIS_FILE" ]; then
    echo "Updating genesis file with Celestia address"
    sed -i "s|celestia1[a-z0-9]\{38,\}|${CELESTIA_ADDRESS}|g" "${ROLLUP_GENESIS_FILE}"
else
    echo "No genesis file provided, skipping genesis update"
fi

# Generate light node API key
LIGHT_NODE_API_KEY=$(celestia light auth admin --p2p.network mocha)

# Update rollup config file if provided
if [ -n "$ROLLUP_CONFIG_FILE" ]; then
    echo "Updating rollup_config.toml celestia_rpc_auth_token and signer_address"
    sed -i "s|celestia_rpc_auth_token = \".*\"|celestia_rpc_auth_token = \"${LIGHT_NODE_API_KEY}\"|g" "${ROLLUP_CONFIG_FILE}"
    sed -i "s|signer_address = \"celestia1[a-z0-9]\{38,\}\"|signer_address = \"${CELESTIA_ADDRESS}\"|g" "${ROLLUP_CONFIG_FILE}"
else
    echo "No config file provided, skipping config update"
fi


# Start celestia light node
echo "Starting celestia light node"
celestia light start --p2p.network mocha

# TODO: Systemd for celestia node
echo "Done"