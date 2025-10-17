import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as rds from 'aws-cdk-lib/aws-rds';
import { Construct } from 'constructs';
import { ComputeInfrastructure } from './compute-infrastructure';

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
      natGateways: 1, // Need at least 1 NAT gateway for private subnets
      subnetConfiguration: [
        {
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24
        },
        {
          name: 'Private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask: 24
        }
      ]
    });

    // Add parameter for RDS database name
    const dbNameParam = new cdk.CfnParameter(this, 'DatabaseName', {
      type: 'String',
      description: 'Name for the RDS database',
      default: 'sovrollupdb'
    });

    // Add parameter for RDS master username
    const dbUsernameParam = new cdk.CfnParameter(this, 'DatabaseUsername', {
      type: 'String',
      description: 'Master username for the RDS database',
      default: 'dbadmin'
    });

    // Create a security group for RDS
    const rdsSecurityGroup = new ec2.SecurityGroup(this, 'SovRollupRdsSecurityGroup', {
      vpc,
      description: 'Security group for Sovereign Rollup RDS instance',
      allowAllOutbound: true
    });

    // Create Aurora postgres cluster. This gives multi-AZ durability by default and should perform better than postgres.
    const auroraCluster = new rds.DatabaseCluster(this, 'SovRollupAuroraCluster', {
      engine: rds.DatabaseClusterEngine.auroraPostgres({
        version: rds.AuroraPostgresEngineVersion.VER_17_5
      }),
      vpc,
      securityGroups: [rdsSecurityGroup],
      defaultDatabaseName: dbNameParam.valueAsString,
      credentials: rds.Credentials.fromUsername(dbUsernameParam.valueAsString),
      writer: rds.ClusterInstance.provisioned('writer', {
        // Use graviton3-based instances for better price/performance
        instanceType: ec2.InstanceType.of(ec2.InstanceClass.R8G, ec2.InstanceSize.LARGE),
        enablePerformanceInsights: true,
        publiclyAccessible: false,
        // Place writer in same AZ as EC2 instances for lowest latency
        availabilityZone: cdk.Stack.of(this).availabilityZones[0]
      }),
      readers: [
        // Start with one reader, can scale up later
        rds.ClusterInstance.provisioned('reader1', {
          instanceType: ec2.InstanceType.of(ec2.InstanceClass.R8G, ec2.InstanceSize.LARGE),
          enablePerformanceInsights: true,
          publiclyAccessible: false,
          // Place reader in different AZ for high availability
          availabilityZone: cdk.Stack.of(this).availabilityZones[1]
        })
      ],
      backup: {
        retention: cdk.Duration.days(7)
      },
      removalPolicy: cdk.RemovalPolicy.DESTROY, // For development - change for production
      deletionProtection: false, // For development - set to true for production
      storageEncrypted: true,
      // Enable enhanced monitoring for better observability
      monitoringInterval: cdk.Duration.seconds(60),
      // Enable backtrack for Aurora to allow point-in-time recovery
      backtrackWindow: cdk.Duration.hours(72)
    });

    // Create compute infrastructure with database information
    const computeInfra = new ComputeInfrastructure(this, 'SovRollupCompute', {
      vpc,
      healthCheckPort: healthCheckPortParam.valueAsNumber,
      primaryAz: cdk.Stack.of(this).availabilityZones[0], // Same AZ as Aurora writer
      databaseCluster: auroraCluster,
      databaseName: dbNameParam.valueAsString
    });

    // Allow connections from the compute instances to RDS
    rdsSecurityGroup.addIngressRule(
      computeInfra.securityGroup,
      ec2.Port.tcp(5432), // PostgreSQL port
      'Allow PostgreSQL connections from compute instances'
    );

    // Output the Auto Scaling Group names
    new cdk.CfnOutput(this, 'PrimaryAutoScalingGroupName', {
      value: computeInfra.primaryAsg.autoScalingGroupName,
      description: 'Name of the Primary Auto Scaling Group (same AZ as Aurora writer)'
    });

    new cdk.CfnOutput(this, 'SecondaryAutoScalingGroupName', {
      value: computeInfra.secondaryAsg.autoScalingGroupName,
      description: 'Name of the Secondary Auto Scaling Group (multi-AZ)'
    });

    // Output the key pair name
    new cdk.CfnOutput(this, 'KeyPairName', {
      value: computeInfra.keyPair.keyPairName,
      description: 'Name of the created SSH key pair'
    });

    // Output command to retrieve private key
    new cdk.CfnOutput(this, 'GetPrivateKeyCommand', {
      value: `aws ssm get-parameter --name /ec2/keypair/${computeInfra.keyPair.keyPairId} --region ${cdk.Stack.of(this).region} --with-decryption --query Parameter.Value --output text > ${computeInfra.keyPair.keyPairName}.pem && chmod 400 ${computeInfra.keyPair.keyPairName}.pem`,
      description: 'Command to retrieve the private key'
    });

    // Output note about SSH access
    new cdk.CfnOutput(this, 'SshAccessNote', {
      value: 'To SSH into instances, use AWS Systems Manager Session Manager or find instance IPs via AWS Console',
      description: 'Note about SSH access to Auto Scaling Group instances'
    });

    // Output Aurora cluster write endpoint
    new cdk.CfnOutput(this, 'AuroraClusterWriteEndpoint', {
      value: auroraCluster.clusterEndpoint.hostname,
      description: 'Aurora cluster write endpoint address'
    });

    // Output Aurora cluster read endpoint
    new cdk.CfnOutput(this, 'AuroraClusterReadEndpoint', {
      value: auroraCluster.clusterReadEndpoint.hostname,
      description: 'Aurora cluster read endpoint address'
    });

    // Output database port
    new cdk.CfnOutput(this, 'DatabasePort', {
      value: auroraCluster.clusterEndpoint.port.toString(),
      description: 'Aurora database port'
    });

    // Output database write connection string
    new cdk.CfnOutput(this, 'DatabaseWriteConnectionString', {
      value: `postgresql://${dbUsernameParam.valueAsString}:<password>@${auroraCluster.clusterEndpoint.hostname}:${auroraCluster.clusterEndpoint.port}/${dbNameParam.valueAsString}`,
      description: 'Aurora write connection string (replace <password> with actual password)'
    });

    // Output database read connection string
    new cdk.CfnOutput(this, 'DatabaseReadConnectionString', {
      value: `postgresql://${dbUsernameParam.valueAsString}:<password>@${auroraCluster.clusterReadEndpoint.hostname}:${auroraCluster.clusterEndpoint.port}/${dbNameParam.valueAsString}`,
      description: 'Aurora read connection string (replace <password> with actual password)'
    });
  }
}
