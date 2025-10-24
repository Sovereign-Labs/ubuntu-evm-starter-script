# Set up a fresh ubuntu 22.04 instance to run the rollup
#
# Usage: setup_celestia.sh [TARGET_USER] [QUICKNODE_API_TOKEN] [QUICKNODE_ENDPOINT] [CELESTIA_KEY_SEED] [ROLLUP_GENESIS_DIR]


set -e

# Parse arguments
TARGET_USER="${1:-}"
QUICKNODE_API_TOKEN="${2:-}"
QUICKNODE_ENDPOINT="${3:-}"
CELESTIA_KEY_SEED="${4:-}"
ROLLUP_GENESIS_DIR="${5:-}"
ROLLUP_KEY_NAME="rollup-key"

# TODO: Check docker, curl, jq

cd /home/"$TARGET_USER"

# Setup celestia binary
yes "1" | bash -c "$(curl -sL https://raw.githubusercontent.com/celestiaorg/docs/main/public/celestia-node.sh)" -- -v v0.27.5-mocha
sudo cp celestia-node-temp/celestia /usr/local/bin
celestia version

# Prepare Quicknode quth
mkdir -p /home/"$TARGET_USER"/.celestia-auth
tee > /home/"$TARGET_USER"/.celestia-auth/xtoken.json << 'EOF'
{
 "x-token": "$QUICKNODE_API_TOKEN"
}
EOF
chmod 600 /home/"$TARGET_USER"/.celestia-auth/xtoken.json

celestia light init --p2p.network mocha
# Config
read -r TRUSTED_HEIGHT TRUSTED_HASH <<<"$(curl -s "${QUICKNODE_ENDPOINT}"header | jq -r '.result.header | "\(.height) \(.last_block_id.hash)"')" && export TRUSTED_HEIGHT TRUSTED_HASH && echo "Height: $TRUSTED_HEIGHT" && echo "Hash:   $TRUSTED_HASH"

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

CELESTIA_ADDRESS=$(docker run \
  -v /home/"$TARGET_USER"/.celestia-light-mocha-4/keys:/mnt/keyring \
  -v /home/"$TARGET_USER"/.celestia-app:/.celestia-app \
  -i \
  ghcr.io/celestiaorg/celestia-node:v0.28.2-arabica \
    cel-key \
    --keyring-dir /mnt/keyring list --output json \
    | grep -v '^Starting Celestia' \
    | grep -v '^cel-key --keyring-dir' \
    | grep -v '^$' \
    | jq -r '.[] | select(.name == "$ROLLUP_KEY_NAME") | .address')
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
  --core.ip "$QUICKNODE_ENDPOINT" \
  --core.port 9090 \
  --core.tls \
  --core.xtoken.path /home/"$TARGET_USER"/.celestia-auth

# TODO: Systemd for celestia node