#!/bin/bash
# Setup script for OpenResty with nginx-vts and Telegraf monitoring
# This script is intended to be hosted externally and curl'd by setup-proxy.sh
set -e

MONITORING_URL="$1"
INFLUX_TOKEN="$2"
INFLUX_ORG="$3"
INFLUX_BUCKET="$4"
INSTANCE_ID="$5"
DEPLOYMENT_NAME="$6"
GEOIP_ACCOUNT="$7"
GEOIP_LICENSE="$8"

GEOIP_ENABLED=0
if [ -n "$GEOIP_ACCOUNT" ] && [ -n "$GEOIP_LICENSE" ]; then
  GEOIP_ENABLED=1
elif [ -n "$GEOIP_ACCOUNT" ] || [ -n "$GEOIP_LICENSE" ]; then
  echo "WARNING: GeoIP disabled because both GEOIP_ACCOUNT and GEOIP_LICENSE are required."
fi

# Validate required parameters
if [ -z "$MONITORING_URL" ] || [ -z "$INFLUX_TOKEN" ] || [ -z "$INFLUX_ORG" ] || [ -z "$INFLUX_BUCKET" ] || [ -z "$INSTANCE_ID" ] || [ -z "$DEPLOYMENT_NAME" ]; then
  echo "Usage: $0 <MONITORING_URL> <INFLUX_TOKEN> <INFLUX_ORG> <INFLUX_BUCKET> <INSTANCE_ID> <DEPLOYMENT_NAME> [GEOIP_ACCOUNT] [GEOIP_LICENSE]"
  echo "ERROR: Missing required monitoring parameters"
  exit 1
fi


yum groupinstall -y "Development Tools"
# Use openssl11-devel for OpenSSL 1.1 (required by OpenResty 1.27+)
yum install -y pcre-devel openssl11-devel zlib-devel perl perl-Data-Dumper git wget

if [ "$GEOIP_ENABLED" -eq 1 ]; then
  # Install libmaxminddb for the geoip2 module
  echo "Building libmaxminddb for the geoip module..."
  cd /tmp
  LIBMAXMINDDB_VERSION="1.12.2"
  wget "https://github.com/maxmind/libmaxminddb/releases/download/${LIBMAXMINDDB_VERSION}/libmaxminddb-${LIBMAXMINDDB_VERSION}.tar.gz"
  tar -xzf libmaxminddb-${LIBMAXMINDDB_VERSION}.tar.gz
  cd libmaxminddb-${LIBMAXMINDDB_VERSION}
  ./configure
  make
  make install
  echo "/usr/local/lib"  >> /etc/ld.so.conf.d/local.conf
  ldconfig

  # Download GeoIP DBs using the helper script expected in /opt
  echo "Downloading MaxMind GeoIP2 database..."
  /opt/update-geoip-dbs.sh "$GEOIP_ACCOUNT" "$GEOIP_LICENSE"
  # And set up a cron job to refresh GeoIP DBs twice a week (Mon/Thu at 03:15)
  cat > /etc/cron.d/update-geoip-dbs <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 3 * * 1,4 root /opt/update-geoip-dbs.sh "$GEOIP_ACCOUNT" "$GEOIP_LICENSE" >/var/log/geoip-db-update.log 2>&1
EOF
  chmod 600 /etc/cron.d/update-geoip-dbs
  echo "Enabled bi-weekly database update cron."
  cp /tmp/conf.d/geoip-setup-ENABLED.conf /tmp/conf.d/geoip-setup.conf
else
  echo "Skipping GeoIP2 setup: GEOIP_ACCOUNT and GEOIP_LICENSE not both provided."
  cp /tmp/conf.d/geoip-setup-DISABLED.conf /tmp/conf.d/geoip-setup.conf
fi

echo "Building OpenResty with nginx-vts module..."

cd /tmp
OPENRESTY_VERSION="1.27.1.2"
wget -q https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz
tar -xzf openresty-${OPENRESTY_VERSION}.tar.gz
cd openresty-${OPENRESTY_VERSION}

git clone --depth 1 https://github.com/vozlt/nginx-module-vts.git
if [ "$GEOIP_ENABLED" -eq 1 ]; then
  git clone --depth 1 https://github.com/leev/ngx_http_geoip2_module.git
fi

# Configure with OpenSSL 1.1 paths (Amazon Linux 2)
CONFIGURE_ARGS=(
  --prefix=/usr/local/openresty
  --with-http_v2_module
  --with-http_realip_module
  --with-http_gzip_static_module
  --with-http_stub_status_module
  --with-cc-opt="-I/usr/include/openssl11"
  --with-ld-opt="-L/usr/lib64/openssl11 -Wl,-rpath,/usr/lib64/openssl11"
  --add-module=./nginx-module-vts
)
if [ "$GEOIP_ENABLED" -eq 1 ]; then
  CONFIGURE_ARGS+=(--add-module=./ngx_http_geoip2_module)
fi
./configure "${CONFIGURE_ARGS[@]}"

make -j$(nproc)
make install

cd /
rm -rf /tmp/openresty-${OPENRESTY_VERSION}*

# Create systemd service file for OpenResty (not included when building from source)
cat > /etc/systemd/system/openresty.service << 'SYSTEMD_EOF'
[Unit]
Description=The OpenResty Application Platform
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/usr/local/openresty/nginx/logs/nginx.pid
ExecStartPre=/usr/local/openresty/nginx/sbin/nginx -t
ExecStart=/usr/local/openresty/nginx/sbin/nginx
ExecStartPost=/bin/sleep 1
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
RuntimeDirectory=openresty
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload

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
[global_tags]
  deployment_name = "$DEPLOYMENT_NAME"
  environment = "sov-aws-dev"

[agent]
  interval = "10s"
  hostname = "$INSTANCE_ID"

[[inputs.socket_listener]]
  service_address = "udp4://127.0.0.1:8094"
  data_format = "influx"

[[inputs.nginx_vts]]
  urls = ["http://127.0.0.1:8080/vts_status/format/json"]

[[outputs.influxdb_v2]]
  urls = ["$MONITORING_URL"]
  token = "$INFLUX_TOKEN"
  organization = "$INFLUX_ORG"
  bucket = "$INFLUX_BUCKET"

# Basic
[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false
  core_tags = false
[[inputs.mem]]

# Storage
[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs", "nsfs", "efivarfs"]
[[inputs.diskio]]

TELEGRAF_EOF

systemctl enable telegraf
systemctl start telegraf

if ! systemctl is-active --quiet telegraf; then
  echo "ERROR: Telegraf failed to start"
  exit 1
fi

echo "OpenResty and Telegraf setup completed successfully"
