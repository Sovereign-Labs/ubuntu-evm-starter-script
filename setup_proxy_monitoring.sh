#!/bin/bash
# Setup script for OpenResty with nginx-vts and Telegraf monitoring
# This script is intended to be hosted externally and curl'd by setup-proxy.sh
set -e

MONITORING_URL="$1"
INFLUX_TOKEN="$2"
INFLUX_ORG="$3"
INFLUX_BUCKET="$4"
INSTANCE_ID="$5"

# Validate required parameters
if [ -z "$MONITORING_URL" ] || [ -z "$INFLUX_TOKEN" ] || [ -z "$INFLUX_ORG" ] || [ -z "$INFLUX_BUCKET" ] || [ -z "$INSTANCE_ID" ]; then
  echo "Usage: $0 <MONITORING_URL> <INFLUX_TOKEN> <INFLUX_ORG> <INFLUX_BUCKET> <INSTANCE_ID>"
  echo "ERROR: Missing required monitoring parameters"
  exit 1
fi

echo "Building OpenResty with nginx-vts module..."

yum groupinstall -y "Development Tools"
# Use openssl11-devel for OpenSSL 1.1 (required by OpenResty 1.27+)
yum install -y pcre-devel openssl11-devel zlib-devel perl perl-Data-Dumper git wget

cd /tmp
OPENRESTY_VERSION="1.27.1.2"
wget -q https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz
tar -xzf openresty-${OPENRESTY_VERSION}.tar.gz
cd openresty-${OPENRESTY_VERSION}

git clone --depth 1 https://github.com/vozlt/nginx-module-vts.git

# Configure with OpenSSL 1.1 paths (Amazon Linux 2)
./configure \
  --prefix=/usr/local/openresty \
  --with-http_v2_module \
  --with-http_realip_module \
  --with-http_gzip_static_module \
  --with-http_stub_status_module \
  --with-cc-opt="-I/usr/include/openssl11" \
  --with-ld-opt="-L/usr/lib64/openssl11 -Wl,-rpath,/usr/lib64/openssl11" \
  --add-module=./nginx-module-vts

make -j$(nproc)
make install

cd /
rm -rf /tmp/openresty-${OPENRESTY_VERSION}*

echo "Installing Telegraf..."

# Import InfluxData GPG key (exp2029 key for current packages)
rpm --import https://repos.influxdata.com/influxdata-archive_compat-exp2029.key

cat <<EOF | tee /etc/yum.repos.d/influxdata.repo
[influxdata]
name = InfluxData Repository - Stable
baseurl = https://repos.influxdata.com/stable/\$basearch/main
enabled = 1
gpgcheck = 1
gpgkey = https://repos.influxdata.com/influxdata-archive_compat-exp2029.key
EOF
yum install -y telegraf

echo "Configuring Telegraf for nginx-vts metrics..."

cat > /etc/telegraf/telegraf.conf << TELEGRAF_EOF
[agent]
  interval = "10s"
  hostname = "$INSTANCE_ID"

[[inputs.nginx_vts]]
  urls = ["http://127.0.0.1/vts_status/format/json"]

[[outputs.influxdb_v2]]
  urls = ["$MONITORING_URL"]
  token = "$INFLUX_TOKEN"
  organization = "$INFLUX_ORG"
  bucket = "$INFLUX_BUCKET"
TELEGRAF_EOF

systemctl enable telegraf
systemctl start telegraf

if ! systemctl is-active --quiet telegraf; then
  echo "ERROR: Telegraf failed to start"
  exit 1
fi

echo "OpenResty and Telegraf setup completed successfully"
