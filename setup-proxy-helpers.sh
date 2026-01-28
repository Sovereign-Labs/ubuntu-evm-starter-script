#!/bin/bash
# Helper functions for setup-proxy.sh - sourced at runtime
# This file is downloaded from NGINX_BASE_URL to reduce userdata size

get_asg_ip() {
  local asg_type="$1"
  local asg_name=$(aws autoscaling describe-auto-scaling-groups \
    --region ${REGION} \
    --query "AutoScalingGroups[?Tags[?Key=='Stack' && Value=='${STACK_NAME}'] && Tags[?Key=='ASGType' && Value=='${asg_type}']].AutoScalingGroupName" \
    --output text | head -1)
  if [ -n "$asg_name" ]; then
    local instance_id=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$asg_name" \
      --region ${REGION} \
      --query "AutoScalingGroups[0].Instances[0].InstanceId" \
      --output text)
    if [ "$instance_id" != "None" ] && [ -n "$instance_id" ]; then
      aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region ${REGION} \
        --query "Reservations[0].Instances[0].PrivateIpAddress" \
        --output text
    fi
  fi
}

wait_for_asg_ip() {
  local asg_type="$1"
  local ip=""
  for i in {1..30}; do
    ip=$(get_asg_ip "$asg_type")
    if [ -n "$ip" ] && [ "$ip" != "None" ]; then
      echo "$ip"
      return 0
    fi
    echo "Waiting for ${asg_type} ASG instance... (attempt $i/30)" >&2
    sleep 10
  done
  echo "ERROR: Could not find ${asg_type} ASG instance IP" >&2
  return 1
}

generate_whitelists() {
  # IP exemption whitelist
  IP_EXEMPT_WHITELIST=""
  if [ -n "$PROXY_GEO_IP_IGNORE_IPS" ]; then
    IFS=',' read -ra IPS <<< "$PROXY_GEO_IP_IGNORE_IPS"
    for ip in "${IPS[@]}"; do
      ip=$(echo "$ip" | xargs)
      [ -n "$ip" ] && IP_EXEMPT_WHITELIST="${IP_EXEMPT_WHITELIST}    ${ip} 1;\n"
    done
  fi

  # Host exemption whitelist
  HOST_EXEMPT_WHITELIST=""
  if [ -n "$SECURE_DOMAIN_NAMES" ]; then
    IFS=',' read -ra DOMAINS <<< "$SECURE_DOMAIN_NAMES"
    for domain in "${DOMAINS[@]}"; do
      domain=$(echo "$domain" | xargs)
      [ -n "$domain" ] && HOST_EXEMPT_WHITELIST="${HOST_EXEMPT_WHITELIST}    \"${domain}\" 1;\n"
    done
  fi

  # Geoblock list
  GEOBLOCK_LIST=""
  if [ -n "$GEOIP_BLOCKED_COUNTRIES" ]; then
    IFS=',' read -ra COUNTRY <<< "$GEOIP_BLOCKED_COUNTRIES"
    for country in "${COUNTRY[@]}"; do
      country=$(echo "$country" | xargs)
      if [ -n "$country" ]; then
        if ! [[ "$country" =~ ^[A-Z]{2}$ ]]; then
          echo "ERROR: Invalid country code \"$country\" (expected 2 uppercase letters)"
          exit 1
        fi
        GEOBLOCK_LIST="${GEOBLOCK_LIST}    \"${country}\" 1;\n"
      fi
    done
  fi

  # API key entries
  API_KEY_ENTRIES=""
  if [ -n "$API_KEYS" ]; then
    IFS=',' read -ra KEYS <<< "$API_KEYS"
    for key in "${KEYS[@]}"; do
      key=$(echo "$key" | xargs)
      [ -n "$key" ] && API_KEY_ENTRIES="${API_KEY_ENTRIES}    ~^/rpc/${key}(/|\\\\?|$) 1;\n"
    done
  fi
}

apply_whitelists() {
  [ -n "$IP_EXEMPT_WHITELIST" ] && sed -i "s|# IP_EXEMPT_PLACEHOLDER|${IP_EXEMPT_WHITELIST}# IP_EXEMPT_PLACEHOLDER|" /tmp/conf.d/http-base.conf
  [ -n "$HOST_EXEMPT_WHITELIST" ] && sed -i "s|# HOST_EXEMPT_PLACEHOLDER|${HOST_EXEMPT_WHITELIST}# HOST_EXEMPT_PLACEHOLDER|" /tmp/conf.d/http-base.conf
  [ -n "$GEOBLOCK_LIST" ] && sed -i "s|# GEOBLOCK_PLACEHOLDER|${GEOBLOCK_LIST}# GEOBLOCK_PLACEHOLDER|" /tmp/conf.d/geoip-setup.conf
  if [ -n "$API_KEY_ENTRIES" ]; then
    sed -i "s#{{API_KEYS}}#${API_KEY_ENTRIES}#" /tmp/conf.d/http-base.conf
  else
    sed -i "s#{{API_KEYS}}##" /tmp/conf.d/http-base.conf
  fi
}

try_restore_certs() {
  CERT_RESTORED=false
  if [ -n "$DOMAIN_NAME" ] && [ -n "$CERT_BUCKET_NAME" ]; then
    mkdir -p /etc/letsencrypt
    if aws s3 sync "s3://$CERT_BUCKET_NAME/letsencrypt/" /etc/letsencrypt/ --region $REGION --quiet; then
      if [ -d "/etc/letsencrypt/live/$DOMAIN_NAME" ]; then
        if openssl x509 -checkend $((30*24*60*60)) -noout -in "/etc/letsencrypt/live/$DOMAIN_NAME/cert.pem" 2>/dev/null; then
          echo "Successfully restored valid certificate from S3"
          CERT_RESTORED=true
        else
          echo "Certificate from S3 is expired or expiring soon, will request new one"
          rm -rf /etc/letsencrypt/live/$DOMAIN_NAME
        fi
      fi
    fi
  fi
}

switch_to_https() {
  echo "Switching to HTTPS configuration..."
  curl -L ${NGINX_BASE_URL}/nginx-https-v2.conf -o /tmp/nginx-https.conf
  sudo cp /tmp/nginx-https.conf /usr/local/openresty/nginx/conf/nginx.conf
  sudo sed -i "s/{{DOMAIN_NAME}}/$DOMAIN_NAME/g" /usr/local/openresty/nginx/conf/nginx.conf
  sudo sed -i "s/{{SECURE_DOMAIN_NAMES}}/$SECURE_DOMAIN_NAMES/g" /usr/local/openresty/nginx/conf/nginx.conf
  sudo systemctl restart openresty
  echo "SSL certificate configured and nginx restarted with HTTPS"
}

provision_certificate() {
  if [ -n "$DOMAIN_NAME" ] && [ "$CERT_RESTORED" = "false" ]; then
    echo "Requesting new certificate from Let's Encrypt..."
    CERT_DOMAINS="$DOMAIN_NAME"
    [ -n "$SECURE_DOMAIN_NAMES" ] && CERT_DOMAINS="$DOMAIN_NAME,$SECURE_DOMAIN_NAMES"
    if certbot certonly --webroot --webroot-path=/var/www/certbot --non-interactive --agree-tos --email info@sovlabs.io --domains $CERT_DOMAINS --keep-until-expiring; then
      echo "Certificate obtained successfully!"
      if [ -n "$CERT_BUCKET_NAME" ]; then
        aws s3 sync /etc/letsencrypt/ "s3://$CERT_BUCKET_NAME/letsencrypt/" --region $REGION --quiet --exclude "*.log" --exclude "accounts/*"
      fi
      [ -d "/etc/letsencrypt/live/$DOMAIN_NAME" ] && switch_to_https
    else
      echo "ERROR: Failed to obtain SSL certificate from Let's Encrypt"
      exit 1
    fi
  fi
}

setup_cert_renewal() {
  if [ -n "$DOMAIN_NAME" ] && [ -n "$CERT_BUCKET_NAME" ]; then
    mkdir -p /etc/letsencrypt/renewal-hooks/post
    cat > /etc/letsencrypt/renewal-hooks/post/upload-to-s3.sh << EOF
#!/bin/bash
aws s3 sync /etc/letsencrypt/ "s3://$CERT_BUCKET_NAME/letsencrypt/" --region $REGION --quiet --exclude "*.log" --exclude "accounts/*"
systemctl reload openresty
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/post/upload-to-s3.sh
    echo "0 3 * * * root certbot renew --quiet" >> /etc/crontab
  elif [ -n "$DOMAIN_NAME" ]; then
    echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload openresty'" >> /etc/crontab
  fi
}
