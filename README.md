# Sovereign Rollup CDK Starter

This is an AWS CDK project for deploying sovereign rollup infrastructure on AWS.

## Infrastructure Components

The stack includes:
- **VPC**: Multi-AZ VPC with public and private subnets
- **Auto Scaling Groups**: 
  - Primary ASG: Runs in same AZ as Aurora writer for low latency
  - Secondary ASG: Multi-AZ for high availability
  - Proxy ASG: OpenResty/nginx proxy with Elastic IP
- **Aurora PostgreSQL**: Serverless v2 cluster with writer and reader instances
- **Load Balancer**: OpenResty proxy with dynamic routing, WebSocket support, and TLS termination
- **Monitoring**: CloudWatch Synthetics canary with SNS alerting
- **Security**: Automatic SSL/TLS certificates via Let's Encrypt

## Prerequisites

1. AWS CLI configured with appropriate credentials
2. Node.js and npm installed
3. AWS CDK CLI installed: `npm install -g aws-cdk`

## Getting Started

1. Install dependencies:
   ```bash
   npm install
   ```

2. Build the TypeScript code:
   ```bash
   npm run build
   ```

3. Bootstrap your AWS environment (first time only):
   ```bash
   npx cdk bootstrap
   ```
   This creates the necessary resources for CDK deployments in your AWS account/region.

4. Deploy the stack:
   ```bash
   npx cdk deploy
   ```

   To deploy with optional parameters:
   ```bash
   npx cdk deploy \
     --parameters DatabaseName=myrollupdb \
     --parameters DatabaseUsername=dbadmin \
     --parameters QuickNodeApiToken=your-token \
     --parameters QuickNodeHost=your-endpoint.quiknode.pro \
     --parameters CelestiaSeed=your-celestia-seed \
     --parameters BranchName=develop \
     --parameters MonitoringUrl=influx.example.com \
     --parameters InfluxToken=your-influx-token \
     --parameters AlloyPassword=your-alloy-password \
     --parameters DomainName=api.theirdomain.com \
   ```

5. After deployment, the stack will output:
   - `PrimaryAutoScalingGroupName`: Name of the primary ASG
   - `SecondaryAutoScalingGroupName`: Name of the secondary ASG
   - `KeyPairName`: Name of the created SSH key pair
   - `GetPrivateKeyCommand`: AWS CLI command to retrieve your private key
   - `ProxyElasticIP`: The Elastic IP for accessing your service
   - `AuroraClusterWriteEndpoint`: Aurora database write endpoint
   - `Route53Nameservers`: Nameservers to configure at your domain registrar (if Route53 enabled)

6. Retrieve your private key:
   - Copy and run the `GetPrivateKeyCommand` from the stack outputs
   - This will save the private key to a `.pem` file with proper permissions

## Connecting to the Instance

1. First retrieve your private key using the command from the stack outputs
2. Then connect to your instance:
   ```bash
   ssh -i <KeyPairName>.pem ubuntu@<InstancePublicIp>
   ```
   Replace `<KeyPairName>` and `<InstancePublicIp>` with the values from your stack outputs.

## Configuration Parameters

### Optional Parameters
- **HealthCheckPort**: Port for health check endpoint (default: 12346)
- **DatabaseName**: Aurora database name (default: sovrollupdb)
- **DatabaseUsername**: Aurora master username (default: dbadmin)
- **QuickNodeApiToken**: API token for QuickNode blockchain RPC access
- **QuickNodeHost**: QuickNode RPC endpoint URL (without http://)
- **CelestiaSeed**: Celestia node seed for data availability layer
- **BranchName**: Git branch name for setup script
- **MonitoringUrl**: Montoring instance URL for metrics (without http://)
- **InfluxToken**: InfluxDB authentication token
- **AlloyPassword**: Alloy password for monitoring authentication
- **DomainName**: Domain name for SSL certificate (e.g., api.theirdomain.com) 

## TLS/SSL Configuration

The stack supports automatic TLS certificates via Let's Encrypt:

### Option 1: Direct Domain Setup
1. Deploy with `--parameters DomainName=api.theirdomain.com`
2. Have the domain owner create an A record pointing to your Elastic IP
3. The proxy will automatically request and renew Let's Encrypt certificates

### Option 2: CNAME Setup with Route53
1. Deploy with:
   ```bash
   --parameters BaseDomain=yourservice.com \
   --parameters CnameSubdomain=api \
   --parameters DomainName=api.theirdomain.com
   ```
2. Update your domain's nameservers to use Route53 (one-time setup)
3. Give the third party your CNAME target (e.g., `api.yourservice.com`)
4. They create: `api.theirdomain.com` CNAME → `api.yourservice.com`
5. Certificates are automatically obtained for `api.theirdomain.com`

### Costs
- Route53 Hosted Zone: $0.50/month
- DNS queries: $0.40 per million requests
- Let's Encrypt certificates: Free

## Health Check Configuration

The stack uses a custom health check system that queries `localhost:12346/healthcheck` every minute via cron and reports status directly to the Auto Scaling Group using `aws autoscaling set-instance-health`. Instances have a 15-minute grace period after launch before health checks begin. Your application must expose a health endpoint that returns HTTP 2xx when healthy. To customize: modify `HealthCheckPort` parameter (default: 12346), `MAX_NODE_SETUP_TIME_MINUTES` in the CDK stack (default: 15), or edit the health check script in `lib/health-check-script.ts`. Logs are written to `/var/log/health-check.log`.

## Architecture Overview

The infrastructure uses a multi-tier architecture:

1. **Proxy Layer**: OpenResty/nginx proxy with Elastic IP handles:
   - TLS termination with Let's Encrypt
   - Request routing (write operations to primary, reads to any instance)
   - WebSocket support
   - Rate limiting (100 req/s with burst of 50)

2. **Compute Layer**: Auto Scaling Groups with c8gd.12xlarge instances
   - Primary ASG: Single instance in same AZ as database writer
   - Secondary ASG: Multi-AZ instances for high availability
   - Automatic setup via user data scripts

3. **Data Layer**: Aurora PostgreSQL Serverless v2
   - Writer instance co-located with primary compute
   - Reader instance in different AZ
   - Automatic backups and encryption

## Useful Commands

- `npm run build` - Compile TypeScript to JavaScript
- `npm run watch` - Watch for changes and compile
- `npm run cdk` - Run CDK commands
- `npm run generate-nginx-configs` - Generate nginx config files for debugging
- `npx cdk synth` - Synthesize CloudFormation template
- `npx cdk diff` - Compare deployed stack with current state
- `npx cdk deploy` - Deploy this stack to your AWS account/region
- `npx cdk destroy` - Destroy the stack

### Debugging Nginx Configurations

To inspect the generated nginx configurations: 

```bash
npm run generate-nginx-configs
```

This creates two configuration files in the `nginx-configs/` directory:
- `nginx-http-only.conf`: HTTP configuration used initially and for domains
- `nginx-https.conf`: HTTPS configuration used after SSL certificates are obtained

Note that this does not alter the stack in any way, or cause any deployments. This is a view-only command..


## Cleaning Up

To delete all resources created by this stack:

```bash
npx cdk destroy
```

This will:
- Show what resources will be deleted
- Ask for confirmation (use `--force` to skip)
- Delete all resources in reverse dependency order
- Remove the CloudFormation stack

**Warning**: This permanently deletes:
- All EC2 instances and their data
- The Aurora database cluster
- The VPC and all networking resources
- Any resources created by the stack

If deletion fails:
- Check CloudFormation console for specific errors
- Manually delete stuck resources in AWS console
- Re-run `npx cdk destroy`

## Security Notes

- SSH access is currently open to all IPs (0.0.0.0/0) - restrict in production
- Database credentials are stored in AWS Secrets Manager
- All traffic between components stays within the VPC
- TLS certificates are automatically managed by Let's Encrypt
- Consider enabling AWS GuardDuty and Security Hub for production deployments
