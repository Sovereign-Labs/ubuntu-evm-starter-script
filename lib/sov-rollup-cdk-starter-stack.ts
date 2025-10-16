import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

export class SovRollupCdkStarterStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Create VPC for the rollup infrastructure
    const vpc = new ec2.Vpc(this, 'SovRollupVpc', {
      maxAzs: 2,
      natGateways: 0, // Start with 0 NAT gateways to save costs
      subnetConfiguration: [
        {
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24
        }
      ]
    });

    // Create security group for EC2 instance
    const securityGroup = new ec2.SecurityGroup(this, 'SovRollupSecurityGroup', {
      vpc,
      description: 'Security group for Sovereign Rollup EC2 instance',
      allowAllOutbound: true
    });

    // Allow SSH from anywhere (to be locked down later)
    securityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(22),
      'Allow SSH access from anywhere'
    );

    // Create a new key pair
    const keyPair = new ec2.KeyPair(this, 'SovRollupKeyPair', {
      keyPairName: `sov-rollup-keypair-${cdk.Stack.of(this).stackName}`
    });

    // Create user data script that downloads and executes the latest setup script
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      '#!/bin/bash',
      'set -e',
      '',
      '# Log all output to file for debugging',
      'exec > >(tee -a /var/log/user-data.log)',
      'exec 2>&1',
      '',
      'echo "Starting user data script at $(date)"',
      '',
      '# Install git if not present',
      'apt-get update',
      'apt-get install -y git curl',
      '',
      '# Download the latest setup script from master branch',
      'echo "Downloading setup script from GitHub..."',
      'curl -L https://raw.githubusercontent.com/Sovereign-Labs/ubuntu-evm-starter-script/master/setup.sh -o /tmp/setup.sh',
      '',
      '# Make it executable and owned by ubuntu user',
      'chmod +x /tmp/setup.sh',
      'chown ubuntu:ubuntu /tmp/setup.sh',
      '',
      '# Execute the setup script as ubuntu user with sudo privileges',
      'echo "Executing setup script as ubuntu user..."',
      'sudo -u ubuntu -H bash -c "sudo /tmp/setup.sh"',
      '',
      'echo "User data script completed at $(date)"'
    );

    // Create EC2 instance
    const instance = new ec2.Instance(this, 'SovRollupInstance', {
      vpc,
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.C8GD, ec2.InstanceSize.XLARGE12),
      machineImage: ec2.MachineImage.fromSsmParameter(
        '/aws/service/canonical/ubuntu/server/jammy/stable/current/arm64/hvm/ebs-gp2/ami-id',
        {
          os: ec2.OperatingSystemType.LINUX
        }
      ),
      securityGroup,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC
      },
      blockDevices: [
        {
          deviceName: '/dev/sda1',
          volume: ec2.BlockDeviceVolume.ebs(24, {
            volumeType: ec2.EbsDeviceVolumeType.GP3
          })
        }
      ],
      keyPair: keyPair,
      userData: userData
    });

    // Output the instance public IP
    new cdk.CfnOutput(this, 'InstancePublicIp', {
      value: instance.instancePublicIp,
      description: 'Public IP address of the EC2 instance'
    });

    // Output the instance ID
    new cdk.CfnOutput(this, 'InstanceId', {
      value: instance.instanceId,
      description: 'Instance ID of the EC2 instance'
    });

    // Output the key pair name
    new cdk.CfnOutput(this, 'KeyPairName', {
      value: keyPair.keyPairName,
      description: 'Name of the created SSH key pair'
    });

    // Output command to retrieve private key
    new cdk.CfnOutput(this, 'GetPrivateKeyCommand', {
      value: `aws ssm get-parameter --name /ec2/keypair/${keyPair.keyPairId} --region ${cdk.Stack.of(this).region} --with-decryption --query Parameter.Value --output text > ${keyPair.keyPairName}.pem && chmod 400 ${keyPair.keyPairName}.pem`,
      description: 'Command to retrieve the private key'
    });
  }
}