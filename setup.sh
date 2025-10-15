#!/bin/bash
# Set up a fresh ubuntu 22.04 instance to run the rollup

# Install system dependencies
sudo apt update
sudo apt install -y clang make llvm-dev libclang-dev libssl-dev pkg-config docker.io docker-compose
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y # Install Rust
. "$HOME/.cargo/env"

# Check that docker works and start local postgres
sudo usermod -aG docker $USER
newgrp docker
docker run --name postgres -e POSTGRES_PASSWORD=sequencerdb -p 5432:5432 -d postgres
docker exec -it postgres psql -U postgres -c "CREATE DATABASE rollup;"
 
# ---------- INSTALL DOCKER COMPOSE ----------
# Add Docker's official GPG key and repository (if not already done)
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update and install the Compose plugin
sudo apt-get update
sudo apt-get install docker-compose-plugin
# ------------- END DOCKER COMPOSE -----------

# Setup starter repo
git clone https://github.com/Sovereign-Labs/rollup-starter.git
cd rollup-starter
git switch preston/evm-starter
cargo build --release
cd ..

# Setup the observability stack
git clone https://github.com/Sovereign-Labs/sov-observability.git
cd sov-observability
make start # Now your grafana is at localhost:3000. Username: admin, passwor: admin123

sudo mkdir -p /etc/systemd/journald.conf.d && sudo tee /etc/systemd/journald.conf.d/rollup.conf > /dev/null << 'EOF'
[Journal]
SystemMaxUse=50G
SystemKeepFree=10G
MaxRetentionSec=30day
EOF
sudo systemctl restart systemd-journald

sudo tee /etc/systemd/system/rollup.service > /dev/null << 'EOF'
[Unit]
Description=Rollup Service
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/rollup-starter
ExecStart=/home/ubuntu/rollup-starter/target/release/rollup
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable rollup && sudo systemctl start rollup
