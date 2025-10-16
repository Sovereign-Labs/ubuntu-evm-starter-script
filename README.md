# Sovereign Rollup CDK Starter

This is an AWS CDK project for deploying sovereign rollup infrastructure on AWS.

## Infrastructure Components

The stack includes:
- **VPC**: Custom VPC with public subnets across 2 availability zones
- **EC2 Instance**: c8gd.12xlarge (ARM-based Graviton) instance running Ubuntu 22.04 LTS
  - 24GB GP3 root volume
  - SSH access on port 22 (currently open to all IPs)
- **SSH Key Pair**: Automatically created and stored in AWS Systems Manager Parameter Store

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

5. After deployment, the stack will output:
   - `InstancePublicIp`: The public IP address to SSH into your instance
   - `InstanceId`: The EC2 instance ID
   - `KeyPairName`: Name of the created SSH key pair
   - `GetPrivateKeyCommand`: AWS CLI command to retrieve your private key

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

## Useful Commands

- `npm run build` - Compile TypeScript to JavaScript
- `npm run watch` - Watch for changes and compile
- `npm run cdk` - Run CDK commands
- `npx cdk synth` - Synthesize CloudFormation template
- `npx cdk diff` - Compare deployed stack with current state
- `npx cdk deploy` - Deploy this stack to your AWS account/region
- `npx cdk destroy` - Destroy the stack

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
- The EC2 instance and all data on it
- The VPC and all networking resources
- Any resources created by the stack

If deletion fails:
- Check CloudFormation console for specific errors
- Manually delete stuck resources in AWS console
- Re-run `npx cdk destroy`

## Security Note

The EC2 instance currently allows SSH access from any IP address (0.0.0.0/0). This should be restricted to specific IP ranges in production environments.