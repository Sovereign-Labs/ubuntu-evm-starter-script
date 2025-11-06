import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as autoscaling from 'aws-cdk-lib/aws-autoscaling';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as rds from 'aws-cdk-lib/aws-rds';
import { Construct } from 'constructs';
import { assert } from 'console';

export const MAX_NODE_SETUP_TIME_MINUTES = 15;

export const MOCK_DATABASE_NAME = 'mock_da_postgres';
export interface ComputeInfrastructureProps {
  vpc: ec2.Vpc;
  healthCheckPort: number;
  primaryAz?: string; // Optional: specify primary AZ for co-location with Aurora writer
  databaseCluster: rds.DatabaseCluster; // Aurora cluster for connection string
  databaseName: string; // Database name
  quicknodeApiToken?: string; // Optional: QuickNode API token
  quicknodeHost?: string; // Optional: QuickNode endpoint
  celestiaSeed?: string; // Optional: Celestia seed phrase
  branchName?: string; // Optional: Git branch name
  monitoringUrl?: string; // Optional: Monitoring instance URL
  influxToken?: string; // Optional: InfluxDB token
  alloyPassword?: string; // Optional: Alloy password for monitoring authentication
  domainName?: string; // Optional: Domain name for SSL certificate
  mockDatabaseCluster?: rds.DatabaseCluster; // Optional: Mock database cluster for testing
}

export class ComputeInfrastructure extends Construct {
  public readonly primaryAsg: autoscaling.AutoScalingGroup;
  public readonly secondaryAsg: autoscaling.AutoScalingGroup;
  public readonly proxyAsg: autoscaling.AutoScalingGroup;
  public readonly securityGroup: ec2.SecurityGroup;
  public readonly keyPair: ec2.KeyPair;
  public readonly proxyEip: ec2.CfnEIP;
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

    // Create separate security group for proxy instances
    const proxySecurityGroup = new ec2.SecurityGroup(this, 'ProxySecurityGroup', {
      vpc: props.vpc,
      description: 'Security group for OpenResty proxy instances',
      allowAllOutbound: true
    });

    // Allow HTTP and HTTPS traffic from anywhere
    proxySecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(80),
      'Allow HTTP traffic'
    );
    
    proxySecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(443),
      'Allow HTTPS traffic'
    );

    // Allow SSH from anywhere (to be locked down later)
    proxySecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(22),
      'Allow SSH access'
    );

    // Allow proxy to connect to rollup instances on port 12346
    this.securityGroup.addIngressRule(
      proxySecurityGroup,
      ec2.Port.tcp(12346),
      'Allow proxy to connect to rollup service'
    );

    // Allow proxy to connect to Grafana on rollup instances
    this.securityGroup.addIngressRule(
      proxySecurityGroup,
      ec2.Port.tcp(3000),
      'Allow proxy to connect to Grafana'
    );

    // Allow Primary ASG instances to connect to Mock DA server on port 50051
    this.securityGroup.addIngressRule(
      this.securityGroup,
      ec2.Port.tcp(50051),
      'Allow rollup instances to connect to Mock DA server'
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
                'ec2:DescribeInstances',
                'autoscaling:DescribeAutoScalingGroups'
              ],
              resources: ['*']
            })
          ]
        }),
        // Let proxy instances associate Elastic IPs
        ElasticIPManagement: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                'ec2:AssociateAddress',
                'ec2:DescribeAddresses'
              ],
              resources: ['*']
            })
          ]
        })
      }
    });

    // Grant access to database secret
    props.databaseCluster.secret!.grantRead(this.ec2Role);
    
    // Grant access to mock database secret if it exists
    if (props.mockDatabaseCluster && props.mockDatabaseCluster.secret) {
      props.mockDatabaseCluster.secret.grantRead(this.ec2Role);
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
      '# Get EC2 instance ID for hostname',
      'export INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)',
      'echo "Instance ID: $INSTANCE_ID"',
      '',
      '# Download the latest setup script from master branch',
      'echo "Downloading setup scripts from GitHub..."',
      'curl -L https://raw.githubusercontent.com/Sovereign-Labs/ubuntu-evm-starter-script/mockda/setup.sh -o /tmp/setup.sh',
      'curl -L https://raw.githubusercontent.com/Sovereign-Labs/ubuntu-evm-starter-script/mockda/setup_celestia_quicknode.sh -o /tmp/setup_celestia_quicknode.sh',
      '',
      '# Make them executable and owned by ubuntu user',
      'chmod +x /tmp/setup.sh',
      'chmod +x /tmp/setup_celestia_quicknode.sh',
      'chown ubuntu:ubuntu /tmp/setup.sh',
      'chown ubuntu:ubuntu /tmp/setup_celestia_quicknode.sh',
    ];

    // Add database connection string retrieval if database is provided
    let setupCommand = 'sudo -u ubuntu -H bash -c "sudo /tmp/setup.sh"';

    // Environment variables will be set from retrieved secrets in the user data script
    
    // Database connection string setup
    const secretArn = props.databaseCluster.secret!.secretArn;
    const dbHost = props.databaseCluster.clusterEndpoint.hostname;
    const dbPort = props.databaseCluster.clusterEndpoint.port;
    const dbName = props.databaseName;
    const region = cdk.Stack.of(this).region;
    
    baseCommands.push(
      '# Retrieve database credentials from Secrets Manager',
      `echo "Retrieving database credentials..."`,
      `SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ${secretArn} --region ${region} --query SecretString --output text)`,
      `DB_USERNAME=$(echo $SECRET_JSON | jq -r .username)`,
      `DB_PASSWORD=$(echo $SECRET_JSON | jq -r .password)`,
      '',
      '# Construct database connection string',
      `export DATABASE_URL="postgresql://$DB_USERNAME:$DB_PASSWORD@${dbHost}:${dbPort}/${dbName}"`,
      'echo "Database connection string constructed (password hidden)"',
      ''
    );

    // Add mock database setup conditionally - only if we're not using Celestia
    
    baseCommands.push(
      '# Debug mock DA setup conditions',
      `echo "celestiaSeed: '${props.celestiaSeed || ''}'"`,
      ''
    );
    const branchArg = props.branchName ? ` --branch-name "${props.branchName}"` : '';
    const monitoringUrlArg = props.monitoringUrl ? ` --monitoring-url "${props.monitoringUrl}"` : '';
    const influxTokenArg = props.influxToken ? ` --influx-token "${props.influxToken}"` : '';
    const alloyPasswordArg = props.alloyPassword ? ` --alloy-password "${props.alloyPassword}"` : '';
    const quicknodeTokenArg = props.quicknodeApiToken ? ` --quicknode-token "${props.quicknodeApiToken}"` : '';
    const quicknodeHostArg = props.quicknodeHost ? ` --quicknode-host "${props.quicknodeHost}"` : '';
    const celestiaSeedArg = props.celestiaSeed ? ` --celestia-seed "${props.celestiaSeed}"` : '';
    const mockDaUrlArg = ` --mock-da-connection-string "$MOCK_DA_SERVER_IP"`;
    const mockDaUrlEnvVar = ` MOCK_DA_SERVER_IP="$MOCK_DA_SERVER_IP"`;
    baseCommands.push(
      '# Function to get mockda server instance IP',
      'get_mockda_server_ip() {',
      '  local stack_name="' + cdk.Stack.of(this).stackName + '"',
      '  # Find ASG name using tags',
      '  local asg_name=$(aws autoscaling describe-auto-scaling-groups \\',
      '    --region ' + cdk.Stack.of(this).region + ' \\',
      '    --query "AutoScalingGroups[?Tags[?Key==\'Stack\' && Value==\'${stack_name}\'] && Tags[?Key==\'ASGType\' && Value==\'MockDaServer\']].AutoScalingGroupName" \\',
      '    --output text | head -1)',
      '  ',
      '  if [ -n "$asg_name" ]; then',
      '    local instance_id=$(aws autoscaling describe-auto-scaling-groups \\',
      '      --auto-scaling-group-names "$asg_name" \\',
      '      --region ' + cdk.Stack.of(this).region + ' \\',
      '      --query "AutoScalingGroups[0].Instances[0].InstanceId" \\',
      '      --output text)',
      '    ',
      '    if [ "$instance_id" != "None" ] && [ -n "$instance_id" ]; then',
      '      aws ec2 describe-instances \\',
      '        --instance-ids "$instance_id" \\',
      '        --region ' + cdk.Stack.of(this).region + ' \\',
      '        --query "Reservations[0].Instances[0].PrivateIpAddress" \\',
      '        --output text',
      '    else',
      '      echo ""',
      '    fi',
      '  else',
      '    echo ""',
      '  fi',
      '}',
      '',
      '# Wait for mock DA ASG instance to be available',
      'MOCK_DA_SERVER_IP=""',
      'for i in {1..30}; do',
      '  MOCK_DA_SERVER_IP=$(get_mockda_server_ip)',
      '  if [ -n "$MOCK_DA_SERVER_IP" ] && [ "$MOCK_DA_SERVER_IP" != "None" ]; then',
      '    echo "Found mockda server instance IP: $MOCK_DA_SERVER_IP"',
      '    export MOCK_DA_SERVER_IP',
      '    break',
      '  fi',
      '  echo "Waiting for mock da ASG instance... (attempt $i/30)"',
      '  sleep 10',
      'done',
      '',
      'if [ -z "$MOCK_DA_SERVER_IP" ] || [ "$MOCK_DA_SERVER_IP" == "None" ]; then',
      '  echo "ERROR: Could not find mock da ASG instance IP"',
      '  echo "Mock DA server will not be available for this rollup instance"',
      '  MOCK_DA_SERVER_IP=""',
      '  export MOCK_DA_SERVER_IP',
      'fi',
    );
    
    setupCommand = `sudo -u ubuntu -H DATABASE_URL="$DATABASE_URL"${mockDaUrlEnvVar} INSTANCE_ID="$INSTANCE_ID" bash -c 'sudo /tmp/setup.sh --is-primary --postgres-conn-string "$DATABASE_URL"${quicknodeTokenArg}${quicknodeHostArg}${celestiaSeedArg}${branchArg}${monitoringUrlArg}${influxTokenArg}${alloyPasswordArg} --hostname "$INSTANCE_ID"${mockDaUrlArg}'`;

    baseCommands.push(
      '# Execute the setup script as ubuntu user with sudo privileges',
      'echo "Executing setup script as ubuntu user..."',
      'echo "DATABASE_URL is: $DATABASE_URL"',
      'echo "MOCK_DA_SERVER_IP is: $MOCK_DA_SERVER_IP"',
      `echo "mockDaUrlArg: '${mockDaUrlArg}'"`,
      `echo "mockDaUrlEnvVar: '${mockDaUrlEnvVar}'"`,
      'echo "Setup command about to run:"',
      `echo "Setup command: ${setupCommand}"`,
      setupCommand,
      'echo "User data script completed at $(date)"'
    );
    
    // Add all commands to primary user data
    userData.addCommands(...baseCommands);

    // Create secondary user data (without --is-primary flag)
    const secondaryUserData = ec2.UserData.forLinux();
    const secondaryBaseCommands = [...baseCommands];
    
    // Replace the setup command to remove --is-primary flag
    const setupCommandIndex = secondaryBaseCommands.findIndex(cmd => cmd.includes('sudo /tmp/setup.sh'));
    if (setupCommandIndex !== -1) {
      const branchArg = props.branchName ? ` --branch-name "${props.branchName}"` : '';
      const monitoringUrlArg = props.monitoringUrl ? ` --monitoring-url "${props.monitoringUrl}"` : '';
      const influxTokenArg = props.influxToken ? ` --influx-token "${props.influxToken}"` : '';
      const alloyPasswordArg = props.alloyPassword ? ` --alloy-password "${props.alloyPassword}"` : '';
      const quicknodeTokenArg = props.quicknodeApiToken ? ` --quicknode-token "${props.quicknodeApiToken}"` : '';
      const quicknodeHostArg = props.quicknodeHost ? ` --quicknode-host "${props.quicknodeHost}"` : '';
      const celestiaSeedArg = props.celestiaSeed ? ` --celestia-seed "${props.celestiaSeed}"` : '';
      const mockDaUrlArg = ` --mock-da-connection-string "$MOCK_DA_SERVER_IP"`;
      const mockDaUrlEnvVar = ` MOCK_DA_SERVER_IP="$MOCK_DA_SERVER_IP"`;
      
      secondaryBaseCommands[setupCommandIndex] = `sudo -u ubuntu -H DATABASE_URL="$DATABASE_URL"${mockDaUrlEnvVar} INSTANCE_ID="$INSTANCE_ID" bash -c 'sudo /tmp/setup.sh --postgres-conn-string "$DATABASE_URL"${quicknodeTokenArg}${quicknodeHostArg}${celestiaSeedArg}${branchArg}${monitoringUrlArg}${influxTokenArg}${alloyPasswordArg} --hostname "$INSTANCE_ID"${mockDaUrlArg}'`;
    }
    
    secondaryUserData.addCommands(...secondaryBaseCommands);

    // Create primary launch template
    const launchTemplate = new ec2.LaunchTemplate(this, 'PrimaryLaunchTemplate', {
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

    // Create secondary launch template (without --is-primary flag)
    const secondaryLaunchTemplate = new ec2.LaunchTemplate(this, 'SecondaryLaunchTemplate', {
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.C8GD, ec2.InstanceSize.XLARGE12),
      machineImage: ec2.MachineImage.fromSsmParameter(
        '/aws/service/canonical/ubuntu/server/jammy/stable/current/arm64/hvm/ebs-gp2/ami-id',
        {
          os: ec2.OperatingSystemType.LINUX
        }
      ),
      securityGroup: this.securityGroup,
      keyPair: this.keyPair,
      userData: secondaryUserData,
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

    const availabilityZones = props.vpc.availabilityZones;
    assert(availabilityZones.length >= 2, 'Must have at least 2 availability zones');
    const primaryAz = availabilityZones[0]; // Use VPC's first AZ as primary
    const secondaryAzs = availabilityZones.slice(1); // Use remaining AZs as secondary
    assert(secondaryAzs.length >= 1, 'Must have at least 1 secondary availability zone');

    // Create primary ASG with guaranteed instance in writer's AZ
    const primaryAsg = new autoscaling.AutoScalingGroup(this, 'PrimaryAsg', {
      vpc: props.vpc,
      launchTemplate: launchTemplate,
      minCapacity: 1, // Always keep at least 1 instance in primary AZ
      maxCapacity: 2,
      desiredCapacity: 1,
      vpcSubnets: { // Place all instances in this ASG in the same AZ as the Aurora writer
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
        availabilityZones: [primaryAz],
      },
      healthChecks: autoscaling.HealthChecks.ec2({
        gracePeriod: cdk.Duration.minutes(MAX_NODE_SETUP_TIME_MINUTES)
      })
    });

    // Create secondary ASG for multi-AZ distribution
    const secondaryAsg = new autoscaling.AutoScalingGroup(this, 'SecondaryAsg', {
      vpc: props.vpc,
      launchTemplate: secondaryLaunchTemplate,
      minCapacity: 0, // Can scale to 0
      maxCapacity: 3,
      desiredCapacity: 0, // NOTE: Update this to 1 after initial deployment
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
        // Place secondary instances anywhere except the primary AZ. This way we're robust to that AZ going down.
        availabilityZones: secondaryAzs,
      },
      healthChecks: autoscaling.HealthChecks.ec2({
        gracePeriod: cdk.Duration.minutes(MAX_NODE_SETUP_TIME_MINUTES)
      })
    });

    // Tag both ASGs
    cdk.Tags.of(primaryAsg).add('ASGType', 'Primary');
    cdk.Tags.of(primaryAsg).add('PreferredAZ', primaryAz);
    cdk.Tags.of(primaryAsg).add('Stack', cdk.Stack.of(this).stackName);
    cdk.Tags.of(secondaryAsg).add('ASGType', 'Secondary');
    cdk.Tags.of(secondaryAsg).add('Stack', cdk.Stack.of(this).stackName);

    // Create custom user data for Mock DA server
    const mockDaUserData = ec2.UserData.forLinux();

     // Base commands
     mockDaUserData.addCommands(
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
      '# Get EC2 instance ID for hostname',
      'export INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)',
      'echo "Instance ID: $INSTANCE_ID"',
      '',
      '# Download the latest setup script from master branch',
      'echo "Downloading setup scripts from GitHub..."',
      'curl -L https://raw.githubusercontent.com/Sovereign-Labs/ubuntu-evm-starter-script/mockda/setup_mock_da.sh -o /tmp/setup.sh',
      '',
      '# Make them executable and owned by ubuntu user',
      'chmod +x /tmp/setup.sh',
      'chown ubuntu:ubuntu /tmp/setup.sh',
    );

    // Add mock database credentials retrieval for the mock DA server
      const mockSecretArn = props.mockDatabaseCluster?.secret?.secretArn;
      const mockDbHost = props.mockDatabaseCluster!.clusterEndpoint.hostname;
      const mockDbPort = props.mockDatabaseCluster!.clusterEndpoint.port;
      const mockDbName = MOCK_DATABASE_NAME;
      
      mockDaUserData.addCommands(
        '# Retrieve mock database credentials from Secrets Manager',
        'echo "Retrieving mock database credentials..."',
        `SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ${mockSecretArn} --region ${region} --query SecretString --output text)`,
        'DB_USERNAME=$(echo $SECRET_JSON | jq -r .username)',
        'DB_PASSWORD=$(echo $SECRET_JSON | jq -r .password)',
        '',
        '# Construct database connection string',
        `export MOCK_DA_DATABASE_URL="postgresql://$DB_USERNAME:$DB_PASSWORD@${mockDbHost}:${mockDbPort}/${mockDbName}"`,
        'echo "Mock DA database connection string constructed (password hidden)"',
        ''
      );

    // Create the setup command for mock DA server with proper variables
    const mockDaBranchArg = props.branchName ? ` --branch-name "${props.branchName}"` : '';
    const mockDaMonitoringUrlArg = props.monitoringUrl ? ` --monitoring-url "${props.monitoringUrl}"` : '';
    const mockDaInfluxTokenArg = props.influxToken ? ` --influx-token "${props.influxToken}"` : '';
    const mockDaAlloyPasswordArg = props.alloyPassword ? ` --alloy-password "${props.alloyPassword}"` : '';
    const mockDaDatabaseArg = ' --mock-da-connection-string "$MOCK_DA_DATABASE_URL"';

    const mockDaSetupCommand = `sudo -u ubuntu -H MOCK_DA_DATABASE_URL="$MOCK_DA_DATABASE_URL" INSTANCE_ID="$INSTANCE_ID" bash -c 'sudo /tmp/setup.sh${mockDaBranchArg}${mockDaMonitoringUrlArg}${mockDaInfluxTokenArg}${mockDaAlloyPasswordArg} --hostname "$INSTANCE_ID"${mockDaDatabaseArg}'`;
    
    mockDaUserData.addCommands(
      '# Execute the setup script as ubuntu user with sudo privileges',
      'echo "Executing mock DA setup script as ubuntu user..."',
      'echo "MOCK_DA_DATABASE_URL is: $MOCK_DA_DATABASE_URL"',
      mockDaSetupCommand,
      'echo "Mock DA user data script completed at $(date)"'
    );

    // Create custom launch template for Mock DA server with its user data
    const mockDaLaunchTemplate = new ec2.LaunchTemplate(this, 'MockDaLaunchTemplate', {
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.C8G, ec2.InstanceSize.XLARGE2),
      machineImage: ec2.MachineImage.fromSsmParameter(
        '/aws/service/canonical/ubuntu/server/jammy/stable/current/arm64/hvm/ebs-gp2/ami-id',
        {
          os: ec2.OperatingSystemType.LINUX
        }
      ),
      securityGroup: this.securityGroup,
      role: this.ec2Role,
      userData: mockDaUserData,
      blockDevices: [{
        deviceName: '/dev/sda1',
        volume: ec2.BlockDeviceVolume.ebs(128, {
          volumeType: ec2.EbsDeviceVolumeType.GP3,
          encrypted: true
        })
      }]
    });

    // Create OpenResty Auto Scaling Group (same AZ as primary to avoid cross-AZ data charges)
    const mockDaServerAsg = new autoscaling.AutoScalingGroup(this, 'MockDaServerAsg', {
      vpc: props.vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
        availabilityZones: [primaryAz] // Same AZ as primary ASG
      },
      launchTemplate: mockDaLaunchTemplate,
      minCapacity: 1,
      maxCapacity: 1,
      desiredCapacity: 1,
      healthChecks: autoscaling.HealthChecks.ec2({
        gracePeriod: cdk.Duration.minutes(15)
      }),
      // updatePolicy: autoscaling.UpdatePolicy.rollingUpdate({
      //   maxBatchSize: 1,
      //   minInstancesInService: 0,
      //   pauseTime: cdk.Duration.minutes(5)
      // })
    });

    // Tag OpenResty instances
    cdk.Tags.of(mockDaServerAsg).add('Name', `${cdk.Stack.of(this).stackName}-mock-da-server`);
    cdk.Tags.of(mockDaServerAsg).add('Service', 'mock-da-server');
    cdk.Tags.of(mockDaServerAsg).add('ASGType', 'MockDaServer');
    cdk.Tags.of(mockDaServerAsg).add('Stack', cdk.Stack.of(this).stackName);

    // Create OpenResty Auto Scaling Group (same AZ as primary to avoid cross-AZ data charges)
    const proxyAsg = new autoscaling.AutoScalingGroup(this, 'ProxyAsg', {
      vpc: props.vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
        availabilityZones: [primaryAz] // Same AZ as primary ASG
      },
      launchTemplate: launchTemplate,
      minCapacity: 1,
      maxCapacity: 1,
      desiredCapacity: 1,
      healthChecks: autoscaling.HealthChecks.ec2({
        gracePeriod: cdk.Duration.minutes(5)
      }),
      updatePolicy: autoscaling.UpdatePolicy.rollingUpdate({
        maxBatchSize: 1,
        minInstancesInService: 0,
        pauseTime: cdk.Duration.minutes(5)
      })
    });

    // Tag OpenResty instances
    cdk.Tags.of(proxyAsg).add('Name', `${cdk.Stack.of(this).stackName}-proxy`);
    cdk.Tags.of(proxyAsg).add('Service', 'proxy');
    cdk.Tags.of(proxyAsg).add('Stack', cdk.Stack.of(this).stackName);

    // Custom user data for OpenResty to discover primary ASG instance
    const proxyUserData = ec2.UserData.forLinux();
    
    // Base commands without domain-specific configuration
    const baseProxyCommands = [
      'set -e',
      '',
      '# Get instance metadata',
      'INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)',
      'REGION=' + cdk.Stack.of(this).region,
      'STACK_NAME=' + cdk.Stack.of(this).stackName,
      'DOMAIN_NAME=' + (props.domainName || ''),
      '',
      '# Find and associate Elastic IP',
      'echo "Looking for Elastic IP tagged with stack name..."',
      'EIP_ALLOCATION_ID=$(aws ec2 describe-addresses \\',
      '  --region $REGION \\',
      '  --filters "Name=tag:Name,Values=${STACK_NAME}-proxy-eip" \\',
      '  --query "Addresses[0].AllocationId" \\',
      '  --output text)',
      '',
      'if [ "$EIP_ALLOCATION_ID" != "None" ] && [ -n "$EIP_ALLOCATION_ID" ]; then',
      '  echo "Associating Elastic IP $EIP_ALLOCATION_ID to instance $INSTANCE_ID"',
      '  aws ec2 associate-address \\',
      '    --instance-id $INSTANCE_ID \\',
      '    --allocation-id $EIP_ALLOCATION_ID \\',
      '    --region $REGION',
      '  echo "Elastic IP associated successfully"',
      'else',
      '  echo "WARNING: No Elastic IP found for proxy"',
      'fi',
      '',
      '# Install OpenResty from official repository',
      'curl -O https://openresty.org/package/amazon/openresty.repo',
      'mv openresty.repo /etc/yum.repos.d/',
      'yum check-update',
      'yum install -y openresty',
      '',
      '# Install certbot if domain name is provided',
      'if [ -n "$DOMAIN_NAME" ]; then',
      '  echo "Installing certbot for domain: $DOMAIN_NAME"',
      '  amazon-linux-extras install epel -y',
      '  yum install -y certbot',
      '  mkdir -p /var/www/certbot',
      'fi',
      '',
      '# Download nginx configuration file (HTTP-only for all cases initially - we need the proxy to be running to pass an ACME challenge to get a TLS certificate before we can use the full config)',
      'curl -L https://raw.githubusercontent.com/Sovereign-Labs/ubuntu-evm-starter-script/mockda/nginx-http-only.conf -o /tmp/nginx-http-only.conf',
    ];
    
    // Add all base commands
    proxyUserData.addCommands(...baseProxyCommands);
    
    // Continue with the rest of the commands
    proxyUserData.addCommands(
      '# Function to get primary ASG instance IP',
      'get_primary_asg_ip() {',
      '  local stack_name="' + cdk.Stack.of(this).stackName + '"',
      '  # Find ASG name using tags',
      '  local asg_name=$(aws autoscaling describe-auto-scaling-groups \\',
      '    --region ' + cdk.Stack.of(this).region + ' \\',
      '    --query "AutoScalingGroups[?Tags[?Key==\'Stack\' && Value==\'${stack_name}\'] && Tags[?Key==\'ASGType\' && Value==\'Primary\']].AutoScalingGroupName" \\',
      '    --output text | head -1)',
      '  ',
      '  if [ -n "$asg_name" ]; then',
      '    local instance_id=$(aws autoscaling describe-auto-scaling-groups \\',
      '      --auto-scaling-group-names "$asg_name" \\',
      '      --region ' + cdk.Stack.of(this).region + ' \\',
      '      --query "AutoScalingGroups[0].Instances[0].InstanceId" \\',
      '      --output text)',
      '    ',
      '    if [ "$instance_id" != "None" ] && [ -n "$instance_id" ]; then',
      '      aws ec2 describe-instances \\',
      '        --instance-ids "$instance_id" \\',
      '        --region ' + cdk.Stack.of(this).region + ' \\',
      '        --query "Reservations[0].Instances[0].PrivateIpAddress" \\',
      '        --output text',
      '    else',
      '      echo ""',
      '    fi',
      '  else',
      '    echo ""',
      '  fi',
      '}',
      '',
      '# Wait for primary ASG instance to be available',
      'PRIMARY_IP=""',
      'for i in {1..30}; do',
      '  PRIMARY_IP=$(get_primary_asg_ip)',
      '  if [ -n "$PRIMARY_IP" ] && [ "$PRIMARY_IP" != "None" ]; then',
      '    echo "Found primary ASG instance IP: $PRIMARY_IP"',
      '    break',
      '  fi',
      '  echo "Waiting for primary ASG instance... (attempt $i/30)"',
      '  sleep 10',
      'done',
      '',
      'if [ -z "$PRIMARY_IP" ] || [ "$PRIMARY_IP" == "None" ]; then',
      '  echo "ERROR: Could not find primary ASG instance IP"',
      '  exit 1',
      'fi',
      '',
      '# Copy nginx configuration to OpenResty directory',
      `sudo mkdir -p /usr/local/openresty/nginx/conf`,
      'sudo cp /tmp/nginx-http-only.conf /usr/local/openresty/nginx/conf/nginx.conf',
      '',
      '# Replace placeholders in nginx config',
      'sudo sed -i "s/{{ROLLUP_LEADER_IP}}/$PRIMARY_IP/g" /usr/local/openresty/nginx/conf/nginx.conf',
      'sudo sed -i "s/{{ROLLUP_FOLLOWER_IP}}/$PRIMARY_IP/g" /usr/local/openresty/nginx/conf/nginx.conf',
      '',
      '# Configure domain name in nginx',
      'if [ -n "$DOMAIN_NAME" ]; then',
      '  sudo sed -i "s/{{DOMAIN_NAME}}/$DOMAIN_NAME/g" /usr/local/openresty/nginx/conf/nginx.conf',
      'else',
      '  # If no domain, use wildcard server name',
      '  sudo sed -i "s/{{DOMAIN_NAME}}/_/g" /usr/local/openresty/nginx/conf/nginx.conf',
      'fi',
      '',
      '# Create log directories',
      'sudo mkdir -p /var/log/nginx',
      'mkdir -p /usr/local/openresty/nginx/logs',
      '',
      '# Start OpenResty',
      'sudo systemctl enable openresty',
      'sudo systemctl start openresty',
      '',
      '# Setup Let\'s Encrypt certificate if domain is provided',
      'if [ -n "$DOMAIN_NAME" ]; then',
      '  echo "Setting up Let\'s Encrypt certificate for $DOMAIN_NAME"',
      '  ',
      '  # Wait for OpenResty to start',
      '  sleep 5',
      '  ',
      '  # Get certificate using webroot method',
      '  certbot certonly --webroot \\',
      '    --webroot-path=/var/www/certbot \\',
      '    --non-interactive \\',
      '    --agree-tos \\',
      '    --email info@sovlabs.io \\',
      '    --domains $DOMAIN_NAME \\',
      '    --keep-until-expiring',
      '  ',
      '  # If certificate was obtained, switch to HTTPS config',
      '  if [ -d "/etc/letsencrypt/live/$DOMAIN_NAME" ]; then',
      '    # Download HTTPS config',
      '    curl -L https://raw.githubusercontent.com/Sovereign-Labs/ubuntu-evm-starter-script/mockda/nginx-https.conf -o /tmp/nginx-https.conf',
      '    sudo cp /tmp/nginx-https.conf /usr/local/openresty/nginx/conf/nginx.conf',
      '    sudo sed -i "s/{{ROLLUP_LEADER_IP}}/$PRIMARY_IP/g" /usr/local/openresty/nginx/conf/nginx.conf',
      '    sudo sed -i "s/{{ROLLUP_FOLLOWER_IP}}/$PRIMARY_IP/g" /usr/local/openresty/nginx/conf/nginx.conf',
      '    sudo sed -i "s/{{DOMAIN_NAME}}/$DOMAIN_NAME/g" /usr/local/openresty/nginx/conf/nginx.conf',
      '    ',
      '    # Restart (not reload) nginx with SSL configuration',
      '    sudo systemctl restart openresty',
      '    echo "SSL certificate installed and nginx reloaded with HTTPS configuration"',
      '  else',
      '    echo "WARNING: Failed to obtain SSL certificate, continuing with HTTP only"',
      '  fi',
      '  ',
      '  # Setup automatic renewal',
      '  echo "0 3 * * * root certbot renew --quiet --post-hook \'systemctl reload openresty\'" >> /etc/crontab',
      'fi',
      '',
      '# Health check',
      'for i in {1..10}; do',
      '  if curl -f http://localhost:80/health &>/dev/null; then',
      '    echo "OpenResty started successfully"',
      '    break',
      '  fi',
      '  echo "Waiting for OpenResty to start... (attempt $i/10)"',
      '  sleep 5',
      'done'
    );

    // Create custom launch template for OpenResty with its user data
    const proxyLaunchTemplate = new ec2.LaunchTemplate(this, 'ProxyLaunchTemplate', {
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.LARGE),
      machineImage: new ec2.AmazonLinuxImage({
        generation: ec2.AmazonLinuxGeneration.AMAZON_LINUX_2
      }),
      securityGroup: proxySecurityGroup,
      role: this.ec2Role,
      userData: proxyUserData,
      blockDevices: [{
        deviceName: '/dev/xvda',
        volume: ec2.BlockDeviceVolume.ebs(30, {
          volumeType: ec2.EbsDeviceVolumeType.GP3,
          encrypted: true
        })
      }]
    });

    // Update OpenResty ASG to use its own launch template
    proxyAsg.node.tryRemoveChild('LaunchConfig');
    const cfnOpenRestyAsg = proxyAsg.node.defaultChild as autoscaling.CfnAutoScalingGroup;
    cfnOpenRestyAsg.launchTemplate = {
      launchTemplateId: proxyLaunchTemplate.launchTemplateId!,
      version: proxyLaunchTemplate.versionNumber
    };

    // Create Elastic IP for proxy
    const proxyEip = new ec2.CfnEIP(this, 'ProxyEIP', {
      domain: 'vpc',
      tags: [{
        key: 'Name',
        value: `${cdk.Stack.of(this).stackName}-proxy-eip`
      }]
    });

    // Expose all ASGs and proxy EIP
    this.primaryAsg = primaryAsg;
    this.secondaryAsg = secondaryAsg;
    this.proxyAsg = proxyAsg;
    this.proxyEip = proxyEip;
  }

}
