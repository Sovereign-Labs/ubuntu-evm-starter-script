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

    // Add parameters for optional existing key pair
    const existingKeyPairParam = new cdk.CfnParameter(this, 'ExistingKeyPairName', {
      type: 'String',
      description: 'Name of existing EC2 key pair (optional)',
      default: ''
    });

    // Create EC2 instance
    const instance = new ec2.Instance(this, 'SovRollupInstance', {
      vpc,
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.C8GD, ec2.InstanceSize.XLARGE12),
      machineImage: ec2.MachineImage.fromSsmParameter(
        '/aws/service/canonical/ubuntu/server/jammy/stable/current/arm64/hvm/ebs-gp2/ami-id',
        {
          os: ec2.OperatingSystemType.LINUX,
          userData: ec2.UserData.forLinux()
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
      keyName: existingKeyPairParam.valueAsString || undefined
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
  }
}