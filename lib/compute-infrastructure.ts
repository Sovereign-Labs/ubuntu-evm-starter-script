import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as autoscaling from 'aws-cdk-lib/aws-autoscaling';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as rds from 'aws-cdk-lib/aws-rds';
import { Construct } from 'constructs';
import { generateHealthCheckScript } from './health-check-script';

export const MAX_NODE_SETUP_TIME_MINUTES = 15;

export interface ComputeInfrastructureProps {
  vpc: ec2.Vpc;
  healthCheckPort: number;
  primaryAz?: string; // Optional: specify primary AZ for co-location with Aurora writer
  databaseCluster?: rds.DatabaseCluster; // Optional: Aurora cluster for connection string
  databaseName?: string; // Database name
}

export class ComputeInfrastructure extends Construct {
  public readonly asg: autoscaling.AutoScalingGroup; // Primary ASG
  public readonly primaryAsg: autoscaling.AutoScalingGroup;
  public readonly secondaryAsg: autoscaling.AutoScalingGroup;
  public readonly securityGroup: ec2.SecurityGroup;
  public readonly keyPair: ec2.KeyPair;
  private ec2Role: iam.Role;

  constructor(scope: Construct, id: string, props: ComputeInfrastructureProps) {
    super(scope, id);

    // Create security group for EC2 instances in ASG
    this.securityGroup = new ec2.SecurityGroup(this, 'SecurityGroup', {
      vpc: props.vpc,
      description: 'Security group for Sovereign Rollup Auto Scaling Group instances',
      allowAllOutbound: true
    });

    // Allow SSH from anywhere (to be locked down later)
    this.securityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(22),
      'Allow SSH access from anywhere'
    );

    // Create IAM role for EC2 instances
    this.ec2Role = new iam.Role(this, 'Ec2Role', {
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

    // Grant access to database secret if database cluster is provided
    if (props.databaseCluster && props.databaseCluster.secret) {
      props.databaseCluster.secret.grantRead(this.ec2Role);
    }

    // Create a new key pair to ssh into the instances
    this.keyPair = new ec2.KeyPair(this, 'KeyPair', {
      keyPairName: `sov-rollup-keypair-${cdk.Stack.of(this).stackName}`
    });

    // Create user data script that 
    //  - downloads and executes the latest setup script
    //  - sets up the healtcheck script to run every minute
    const userData = ec2.UserData.forLinux();
    
    // Base commands
    const baseCommands = [
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
      'apt-get install -y git curl awscli jq',
      '',
      '# Download the latest setup script from master branch',
      'echo "Downloading setup script from GitHub..."',
      'curl -L https://raw.githubusercontent.com/Sovereign-Labs/ubuntu-evm-starter-script/master/setup.sh -o /tmp/setup.sh',
      '',
      '# Make it executable and owned by ubuntu user',
      'chmod +x /tmp/setup.sh',
      'chown ubuntu:ubuntu /tmp/setup.sh',
      ''
    ];

    // Add database connection string retrieval if database is provided
    let setupCommand = 'sudo -u ubuntu -H bash -c "sudo /tmp/setup.sh"';
    
    if (props.databaseCluster && props.databaseCluster.secret) {
      const secretArn = props.databaseCluster.secret.secretArn;
      const dbHost = props.databaseCluster.clusterEndpoint.hostname;
      const dbPort = props.databaseCluster.clusterEndpoint.port;
      const dbName = props.databaseName || 'postgres';
      const region = cdk.Stack.of(this).region;
      
      baseCommands.push(
        '# Retrieve database credentials from Secrets Manager',
        `echo "Retrieving database credentials..."`,
        `SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ${secretArn} --region ${region} --query SecretString --output text)`,
        `DB_USERNAME=$(echo $SECRET_JSON | jq -r .username)`,
        `DB_PASSWORD=$(echo $SECRET_JSON | jq -r .password)`,
        '',
        '# Construct database connection string',
        `DATABASE_URL="postgresql://$DB_USERNAME:$DB_PASSWORD@${dbHost}:${dbPort}/${dbName}"`,
        'echo "Database connection string constructed (password hidden)"',
        ''
      );
      
      setupCommand = 'sudo -u ubuntu -H bash -c "sudo /tmp/setup.sh \\"$DATABASE_URL\\""';
    }

    baseCommands.push(
      '# Execute the setup script as ubuntu user with sudo privileges',
      'echo "Executing setup script as ubuntu user..."',
      setupCommand,
      '',
      '# Create health check script',
      `cat > /usr/local/bin/health-check.sh << 'EOF'`,
      generateHealthCheckScript(props.healthCheckPort.toString(), MAX_NODE_SETUP_TIME_MINUTES),
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
    
    // Add all commands to user data
    userData.addCommands(...baseCommands);

    // Create launch template
    const launchTemplate = new ec2.LaunchTemplate(this, 'LaunchTemplate', {
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.C8GD, ec2.InstanceSize.XLARGE12),
      machineImage: ec2.MachineImage.fromSsmParameter(
        '/aws/service/canonical/ubuntu/server/jammy/stable/current/arm64/hvm/ebs-gp2/ami-id',
        {
          os: ec2.OperatingSystemType.LINUX
        }
      ),
      securityGroup: this.securityGroup,
      keyPair: this.keyPair,
      userData: userData,
      role: this.ec2Role,
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

    const availabilityZones = cdk.Stack.of(this).availabilityZones;
    const primaryAz = props.primaryAz || availabilityZones[0];

    // Create primary ASG with guaranteed instance in writer's AZ
    const primaryAsg = new autoscaling.AutoScalingGroup(this, 'PrimaryAsg', {
      vpc: props.vpc,
      launchTemplate: launchTemplate,
      minCapacity: 1, // Always keep at least 1 instance in primary AZ
      maxCapacity: 2,
      desiredCapacity: 1,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
        availabilityZones: [primaryAz] // Only in writer's AZ
      },
      healthChecks: autoscaling.HealthChecks.ec2({
        gracePeriod: cdk.Duration.minutes(MAX_NODE_SETUP_TIME_MINUTES)
      })
    });

    // Create secondary ASG for multi-AZ distribution
    const secondaryAsg = new autoscaling.AutoScalingGroup(this, 'SecondaryAsg', {
      vpc: props.vpc,
      launchTemplate: launchTemplate,
      minCapacity: 0, // Can scale to 0
      maxCapacity: 3,
      desiredCapacity: 1, // Start with 1 additional instance
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC
        // Uses all AZs for distribution
      },
      healthChecks: autoscaling.HealthChecks.ec2({
        gracePeriod: cdk.Duration.minutes(MAX_NODE_SETUP_TIME_MINUTES)
      })
    });

    // Tag both ASGs
    cdk.Tags.of(primaryAsg).add('ASGType', 'Primary');
    cdk.Tags.of(primaryAsg).add('PreferredAZ', primaryAz);
    cdk.Tags.of(secondaryAsg).add('ASGType', 'Secondary');

    // Expose both ASGs
    this.primaryAsg = primaryAsg;
    this.secondaryAsg = secondaryAsg;
    this.asg = primaryAsg; // For backward compatibility
  }

  // Method to grant access to database secret after cluster is created
  public grantDatabaseAccess(databaseCluster: rds.DatabaseCluster): void {
    if (databaseCluster.secret) {
      databaseCluster.secret.grantRead(this.ec2Role);
    }
  }
}
