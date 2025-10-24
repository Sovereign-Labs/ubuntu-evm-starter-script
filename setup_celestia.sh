# Set up a fresh ubuntu 22.04 instance to run the rollup
#
# Usage: setup_celestia.sh [TARGET_USER] [QUICKNODE_API_TOKEN] [QUICKNODE_HOST] [CELESTIA_KEY_SEED] [ROLLUP_GENESIS_DIR]
# https://www.quicknode.com/guides/infrastructure/node-setup/run-a-celestia-light-node

set -e

# Parse arguments
TARGET_USER="${1:-}"
QUICKNODE_API_TOKEN="${2:-}"
QUICKNODE_HOST="${3:-}"
CELESTIA_KEY_SEED="${4:-}"
ROLLUP_GENESIS_DIR="${5:-}"
ROLLUP_KEY_NAME="rollup-key"

# Validate that QUICKNODE_HOST is a hostname, not a full URL
if [[ "$QUICKNODE_HOST" =~ ^https?:// ]]; then
    echo "Error: QUICKNODE_HOST should be a hostname only, not a full URL."
    echo "Example: restless-black-isle.celestia-mocha.quiknode.pro"
    echo "NOT: https://restless-black-isle.celestia-mocha.quiknode.pro/..."
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

echo "-----------------"
echo "KEY IMPORTED"

# Get the key list and extract address
# Redirect stderr to avoid pollution and use grep to extract only JSON array lines
CELESTIA_ADDRESS=$(docker run \
  -v /home/"$TARGET_USER"/.celestia-light-mocha-4/keys:/mnt/keyring \
  -v /home/"$TARGET_USER"/.celestia-app:/.celestia-app \
  -i \
  ghcr.io/celestiaorg/celestia-node:v0.28.2-arabica \
    cel-key \
    --keyring-dir /mnt/keyring list --output json 2>/dev/null \
    | grep '^\[' \
    | jq -r --arg keyname "$ROLLUP_KEY_NAME" '.[] | select(.name == $keyname) | .address')
echo "-----------------"
echo "ADDRESS: ${CELESTIA_ADDRESS}"

# Updating genesis
sed -i "s|celestia1[a-z0-9]\{38,\}|${CELESTIA_ADDRESS}|g" "${ROLLUP_GENESIS_DIR}"/genesis.json
# TODO: Update rollup_config.toml

# TODO: PARAMS FROM THE BOTTOM INTO CONFIG

# Start celestia light node
echo "Starting celestia light node"
celestia light start \
  --p2p.network mocha \
  --core.ip "$QUICKNODE_HOST" \
  --core.port 9090 \
  --core.tls \
  --core.xtoken.path /home/"$TARGET_USER"/.celestia-auth

# TODO: Systemd for celestia node