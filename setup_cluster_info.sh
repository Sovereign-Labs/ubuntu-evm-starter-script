ROLLUP_STARTER_REPO="https://github.com/Sovereign-Labs/rollup-starter"
ROLLUP_STARTER_BRANCH="blaze/proxy-utils"
ROLLUP_STARTER_DIR="/tmp/rollup-starter"
PROXY_CRATE_MANIFEST="${ROLLUP_STARTER_DIR}/crates/utils/proxy/Cargo.toml"

if ! command -v git >/dev/null 2>&1; then
   yum install -y git
fi

if ! command -v cargo >/dev/null 2>&1; then
  # Install Rust toolchain for building proxy binary
  echo "Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi

if [ ! -d "${ROLLUP_STARTER_DIR}/.git" ]; then
  git clone "${ROLLUP_STARTER_REPO}" "${ROLLUP_STARTER_DIR}"
fi

git -C "${ROLLUP_STARTER_DIR}" fetch origin "${ROLLUP_STARTER_BRANCH}"
git -C "${ROLLUP_STARTER_DIR}" checkout "${ROLLUP_STARTER_BRANCH}"
cargo build --release --manifest-path "${PROXY_CRATE_MANIFEST}"
