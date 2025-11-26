#!/bin/bash

set -euo pipefail

SOURCE_URL="https://raw.githubusercontent.com/Sovereign-Labs/rollup-starter/546c07d1210c3e6c378feab5b3a8468643eff9d3/configs/celestia/evm_pinned_cache.json"

usage() {
    echo "Usage: $0 <file_location> <addresses> <owner>"
    echo ""
    echo "Arguments:"
    echo "  file_location  - Path where the JSON file will be saved"
    echo "  addresses      - Comma-separated list of addresses (e.g., '0x123,0x456')"
    echo "  owner          - User who should own the file"
    exit 1
}

if [[ $# -ne 3 ]]; then
    usage
fi

FILE_LOCATION="$1"
ADDRESSES="$2"
OWNER="$3"

# Download the source JSON
echo "Downloading pinned addresses config to ${FILE_LOCATION}..."
curl -sSfL "${SOURCE_URL}" -o "${FILE_LOCATION}"

# Convert comma-separated addresses to JSON array and update the file
echo "Setting privileged_deployer_addresses..."
if [[ -z "${ADDRESSES}" ]]; then
    ADDRESSES_JSON="[]"
else
    ADDRESSES_JSON=$(echo "${ADDRESSES}" | jq -R 'split(",")')
fi
jq --argjson addrs "${ADDRESSES_JSON}" '.privileged_deployer_addresses = $addrs' "${FILE_LOCATION}" > "${FILE_LOCATION}.tmp"
mv "${FILE_LOCATION}.tmp" "${FILE_LOCATION}"

# Set ownership
echo "Setting ownership to ${OWNER}..."
chown "${OWNER}" "${FILE_LOCATION}"

echo "Done. File saved to ${FILE_LOCATION}"
