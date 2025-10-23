# OpenResty Proxy Runbook

This document provides operational procedures for managing the OpenResty proxy in production.

## Overview

The OpenResty proxy runs on EC2 instances in the `ProxyAsg` Auto Scaling Group and serves as a load balancer/router for the rollup infrastructure. It routes requests between leader and follower nodes based on the request type.

## Quick Reference

- **Config File**: `/usr/local/openresty/nginx/conf/nginx.conf`
- **Service Name**: `openresty`
- **Log Files**: 
  - Error: `/var/log/nginx/error.log`
  - Access: `/var/log/nginx/access.log`
- **PID File**: `/usr/local/openresty/nginx/logs/nginx.pid`

## Connecting to Proxy Instance

### Method 1: AWS Systems Manager (Recommended)

```bash
# List proxy instances
aws ec2 describe-instances \
  --filters "Name=tag:Service,Values=proxy" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{InstanceId:InstanceId,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress}" \
  --output table

# Connect via SSM (no SSH key needed)
aws ssm start-session --target <INSTANCE_ID>

# Switch to root for admin tasks
sudo su -
```

### Method 2: SSH

```bash
# Get the Elastic IP from CloudFormation outputs
aws cloudformation describe-stacks \
  --stack-name SovRollupCdkStarterStack \
  --query "Stacks[0].Outputs[?OutputKey=='ProxyElasticIP'].OutputValue" \
  --output text

# SSH using the key pair
ssh -i ~/.ssh/sov-rollup-keypair-SovRollupCdkStarterStack.pem ec2-user@<ELASTIC_IP>
```

## Real-Time Configuration Updates

### 1. Update Proxy Configuration

```bash
# Connect to the proxy instance (see above)
sudo su -

# Backup current config
cp /usr/local/openresty/nginx/conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf.backup.$(date +%Y%m%d-%H%M%S)

# Edit the configuration
vim /usr/local/openresty/nginx/conf/nginx.conf

# Test configuration syntax
openresty -t

# If syntax is OK, reload without downtime
systemctl reload openresty
```

### 2. Update Backend IPs

If the primary rollup instance changes, update the backend IPs:

```bash
# Get the new primary instance IP
PRIMARY_IP=$(aws autoscaling describe-auto-scaling-groups \
  --region us-east-1 \
  --query "AutoScalingGroups[?Tags[?Key=='Stack' && Value=='SovRollupCdkStarterStack'] && Tags[?Key=='ASGType' && Value=='Primary']].Instances[0].InstanceId" \
  --output text | xargs -I {} aws ec2 describe-instances \
  --instance-ids {} \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

echo "Primary IP: $PRIMARY_IP"

# Update the config file
sed -i "s/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:12346/$PRIMARY_IP:12346/g" /usr/local/openresty/nginx/conf/nginx.conf

# Test and reload
openresty -t && systemctl reload openresty
```

### 3. Update Routing Rules

To modify which endpoints route to leader vs follower:

```bash
# Edit the Lua access_by_lua_block section
vim /usr/local/openresty/nginx/conf/nginx.conf

# Find this section and modify routing logic:
# access_by_lua_block {
#     local uri = ngx.var.uri
#     local method = ngx.var.request_method
#     ...
# }

# Test and reload
openresty -t && systemctl reload openresty
```

## Common Operations

### Check Service Status

```bash
# Service status
systemctl status openresty

# View recent logs
journalctl -u openresty -f

# Check if nginx is responding
curl -I http://localhost:80/health
```

### Restart Service (With Downtime)

```bash
# Full restart (brief downtime)
systemctl restart openresty

# Check status
systemctl status openresty
curl http://localhost:80/health
```

## Configuration Examples

### Add New Endpoint Route

To route a new endpoint to the leader:

```lua
-- In the access_by_lua_block section, add:
if uri == "/new-endpoint" and method == "POST" then
    use_leader = true
```

### Update Rate Limiting

```nginx
# In the http block, modify:
limit_req_zone $binary_remote_addr zone=global_limit:10m rate=200r/s;

# In the location block, modify:
limit_req zone=global_limit burst=100 nodelay;
```

### Service Won't Start

1. Check syntax: `openresty -t`
2. Verify directories exist:
   - `ls -la /var/log/nginx/`
   - `ls -la /usr/local/openresty/nginx/logs/`
3. Check permissions: `chown -R nobody:nobody /usr/local/openresty/nginx/logs/`

## Emergency Procedures

### Rollback Configuration

```bash
# List available backups
ls -la /usr/local/openresty/nginx/conf/nginx.conf.backup.*

# Restore from backup
cp /usr/local/openresty/nginx/conf/nginx.conf.backup.<timestamp> /usr/local/openresty/nginx/conf/nginx.conf

# Test and reload
openresty -t && systemctl reload openresty
```

### Log Analysis

```bash
# Top error codes
awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -nr

# Average response time
awk '{print $NF}' /var/log/nginx/access.log | awk -F'=' '{sum+=$2; count++} END {print sum/count}'

# Top IPs by request count
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -nr | head -10
```
