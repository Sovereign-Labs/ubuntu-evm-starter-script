#!/bin/bash
# Downloads MaxMind GeoIP2 databases and installs them in /usr/share/GeoIP (must have write permissions there)
# Idempotent, intended to be used in a cron job. Mind the daily download limits for a free MaxMind account.
set -euo pipefail

ACCOUNT_ID="$1"
LICENSE_KEY="$2"

cd /tmp
wget --content-disposition --user=$ACCOUNT_ID --password=$LICENSE_KEY "https://download.maxmind.com/geoip/databases/GeoLite2-Country/download?suffix=tar.gz" -O GeoLite2-Country.tar.gz
tar xzf GeoLite2-Country.tar.gz
mkdir -p /usr/share/GeoIP
cp GeoLite2-Country_*/GeoLite2-Country.mmdb /usr/share/GeoIP/
