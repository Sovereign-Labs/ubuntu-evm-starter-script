#!/bin/bash

set -e

BRANCH_NAME="$1"

ROLLUP_STARTER_REPO="https://github.com/Sovereign-Labs/rollup-starter"
ROLLUP_STARTER_DIR="/tmp/rollup-starter"
PROXY_CRATE_MANIFEST="${ROLLUP_STARTER_DIR}/crates/utils/proxy/Cargo.toml"

echo "Checking for git... $BRANCH_NAME"

export HOME=/root
if ! command -v git >/dev/null 2>&1; then
   echo "Installing git..."
   yum install -y git
fi

yum install -y gcc gcc-c++

if ! command -v cargo >/dev/null 2>&1; then
  # Install Rust toolchain for building proxy binary
  echo "Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi

if [ ! -d "${ROLLUP_STARTER_DIR}/.git" ]; then
  echo "Cloning rollup-starter repo..."
  git clone "${ROLLUP_STARTER_REPO}" "${ROLLUP_STARTER_DIR}"
fi


git -C "${ROLLUP_STARTER_DIR}" fetch origin "${ROLLUP_STARTER_BRANCH}"
git -C "${ROLLUP_STARTER_DIR}" checkout "${BRANCH_NAME}"

echo "Building cluster info binary..."
cargo build --release --manifest-path "${PROXY_CRATE_MANIFEST}"
