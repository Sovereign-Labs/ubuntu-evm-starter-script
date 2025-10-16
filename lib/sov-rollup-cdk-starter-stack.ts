import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as autoscaling from 'aws-cdk-lib/aws-autoscaling';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import { generateHealthCheckScript } from './health-check-script';

export const MAX_NODE_SETUP_TIME_MINUTES = 15;

export class SovRollupCdkStarterStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Add parameter for health check port
    const healthCheckPortParam = new cdk.CfnParameter(this, 'HealthCheckPort', {
      type: 'Number',
      description: 'Port for health check endpoint',
      default: 12346
    });

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

    // Create security group for EC2 instances in ASG
    const asgSecurityGroup = new ec2.SecurityGroup(this, 'SovRollupAsgSecurityGroup', {
      vpc,
      description: 'Security group for Sovereign Rollup Auto Scaling Group instances',
      allowAllOutbound: true
    });

    // Allow SSH from anywhere (to be locked down later)
    asgSecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(22),
      'Allow SSH access from anywhere'
    );


    // Create IAM role for EC2 instances
    const ec2Role = new iam.Role(this, 'SovRollupEc2Role', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')
      ],
      inlinePolicies: {
        // Let instances set their own health status
        AutoScalingHealthCheck: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                'autoscaling:SetInstanceHealth',
                'ec2:DescribeInstances'
              ],
              resources: ['*']
            })
          ]
        })
      }
    });

    // Create a new key pair to ssh into the instances
    const keyPair = new ec2.KeyPair(this, 'SovRollupKeyPair', {
      keyPairName: `sov-rollup-keypair-${cdk.Stack.of(this).stackName}`
    });

    // Create user data script that 
    //  - downloads and executes the latest setup script
    //  - sets up the healtcheck script to run every minute
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
      '# Install dependencies',
      'apt-get update',
      'apt-get install -y git curl awscli',
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
      '# Create health check script',
      `cat > /usr/local/bin/health-check.sh << 'EOF'`,
      generateHealthCheckScript(healthCheckPortParam.valueAsString, MAX_NODE_SETUP_TIME_MINUTES),
      'EOF',
      '',
      '# Make health check script executable',
      'chmod +x /usr/local/bin/health-check.sh',
      '',
      '# Add cron job to run health check every minute',
      'echo "* * * * * root /usr/local/bin/health-check.sh >> /var/log/health-check.log 2>&1" >> /etc/crontab',
      '',
      'echo "User data script completed at $(date)"'
    );


    // Create launch template
    const launchTemplate = new ec2.LaunchTemplate(this, 'SovRollupLaunchTemplate', {
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.C8GD, ec2.InstanceSize.XLARGE12),
      machineImage: ec2.MachineImage.fromSsmParameter(
        '/aws/service/canonical/ubuntu/server/jammy/stable/current/arm64/hvm/ebs-gp2/ami-id',
        {
          os: ec2.OperatingSystemType.LINUX
        }
      ),
      securityGroup: asgSecurityGroup,
      keyPair: keyPair,
      userData: userData,
      role: ec2Role,
      blockDevices: [
        {
          // Use a 24 GB EBS volume for the root device. All other storage is on the attached nvme drives for c8gd instances
          deviceName: '/dev/sda1',
          volume: ec2.BlockDeviceVolume.ebs(24, {
            volumeType: ec2.EbsDeviceVolumeType.GP3
          })
        }
      ]
    });

    // Create an Auto Scaling Group (more instances will be added later)
    const asg = new autoscaling.AutoScalingGroup(this, 'SovRollupAsg', {
      vpc,
      launchTemplate: launchTemplate,
      minCapacity: 1,
      maxCapacity: 1,
      desiredCapacity: 1,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC
      },
      healthChecks: autoscaling.HealthChecks.ec2({
        gracePeriod: cdk.Duration.minutes(MAX_NODE_SETUP_TIME_MINUTES)
      })
    });
    

    // Output the Auto Scaling Group name
    new cdk.CfnOutput(this, 'AutoScalingGroupName', {
      value: asg.autoScalingGroupName,
      description: 'Name of the Auto Scaling Group'
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

    // Output note about SSH access
    new cdk.CfnOutput(this, 'SshAccessNote', {
      value: 'To SSH into instances, use AWS Systems Manager Session Manager or find instance IPs via AWS Console',
      description: 'Note about SSH access to Auto Scaling Group instances'
    });
  }
}
