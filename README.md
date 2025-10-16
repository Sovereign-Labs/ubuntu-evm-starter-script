# Sovereign Rollup CDK Starter

This is an AWS CDK project for deploying sovereign rollup infrastructure on AWS.

## Infrastructure Components

The stack includes:
- **VPC**: Custom VPC with public subnets across 2 availability zones
- **EC2 Instance**: c8gd.12xlarge (ARM-based Graviton) instance running Ubuntu 22.04 LTS
  - 24GB GP3 root volume
  - SSH access on port 22 (currently open to all IPs)

## Prerequisites

1. AWS CLI configured with appropriate credentials
2. Node.js and npm installed
3. AWS CDK CLI installed: `npm install -g aws-cdk`
4. An existing EC2 key pair (or create one in AWS Console)

## Getting Started

1. Install dependencies:
   ```bash
   npm install
   ```

2. Build the TypeScript code:
   ```bash
   npm run build
   ```

3. Deploy the stack:
   - With existing key pair:
     ```bash
     npx cdk deploy --parameters ExistingKeyPairName=your-key-pair-name
     ```
   - Without key pair parameter (you'll need to create one first):
     ```bash
     npx cdk deploy
     ```

4. After deployment, the stack will output:
   - `InstancePublicIp`: The public IP address to SSH into your instance
   - `InstanceId`: The EC2 instance ID

## Connecting to the Instance

Once deployed, connect to your instance using:
```bash
ssh -i /path/to/your-key.pem ubuntu@<InstancePublicIp>
```

## Useful Commands

- `npm run build` - Compile TypeScript to JavaScript
- `npm run watch` - Watch for changes and compile
- `npm run cdk` - Run CDK commands
- `npx cdk synth` - Synthesize CloudFormation template
- `npx cdk diff` - Compare deployed stack with current state
- `npx cdk deploy` - Deploy this stack to your AWS account/region
- `npx cdk destroy` - Destroy the stack

## Security Note

The EC2 instance currently allows SSH access from any IP address (0.0.0.0/0). This should be restricted to specific IP ranges in production environments.