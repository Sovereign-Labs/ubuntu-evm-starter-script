import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as synthetics from 'aws-cdk-lib/aws-synthetics';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
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
      maxAzs: 99, // Per the docs, use 99 to ensure the VPC spans all AZs in the region
      natGateways: 1, // Need at least 1 NAT gateway for private subnets
      subnetConfiguration: [ // We'll get one subnet per AZ for each type
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

    // Add parameters for additional optional configuration
    const quicknodeApiTokenParam = new cdk.CfnParameter(this, 'QuickNodeApiToken', {
      type: 'String',
      description: 'QuickNode API token for blockchain RPC access (optional)',
      default: '',
      noEcho: true // Hide the value in CloudFormation console
    });

    const quicknodeHostParam = new cdk.CfnParameter(this, 'QuickNodeHost', {
      type: 'String',
      description: 'QuickNode host URL (optional)',
      default: ''
    });

    const celestiaSeedParam = new cdk.CfnParameter(this, 'CelestiaSeed', {
      type: 'String',
      description: 'Celestia node key for data availability (optional)',
      default: '',
      noEcho: true // Hide the value in CloudFormation console
    });

    const branchNameParam = new cdk.CfnParameter(this, 'BranchName', {
      type: 'String',
      description: 'Git branch name for setup script (optional)',
      default: ''
    });

    const monitoringUrlParam = new cdk.CfnParameter(this, 'MonitoringUrl', {
      type: 'String',
      description: 'InfluxDB URL for metrics (optional)',
      default: ''
    });

    const influxTokenParam = new cdk.CfnParameter(this, 'InfluxToken', {
      type: 'String',
      description: 'InfluxDB authentication token (optional)',
      default: '',
      noEcho: true // Hide the value in CloudFormation console
    });

    const alloyPasswordParam = new cdk.CfnParameter(this, 'AlloyPassword', {
      type: 'String',
      description: 'Alloy password for monitoring authentication (optional)',
      default: '',
      noEcho: true // Hide the value in CloudFormation console
    });

    const domainNameParam = new cdk.CfnParameter(this, 'DomainName', {
      type: 'String',
      description: 'Domain name for SSL certificate (optional, e.g., api.example.com)',
      default: ''
    });
    
    // Create a security group for RDS
    const rdsSecurityGroup = new ec2.SecurityGroup(this, 'SovRollupRdsSecurityGroup', {
      vpc,
      description: 'Security group for Sovereign Rollup RDS instance',
      allowAllOutbound: true
    });

    // Create Aurora postgres cluster. This gives multi-AZ durability by default and should perform better than managed postgres.
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
    });

    // Create compute infrastructure with database information
    const computeInfra = new ComputeInfrastructure(this, 'SovRollupCompute', {
      vpc,
      healthCheckPort: healthCheckPortParam.valueAsNumber,
      primaryAz: cdk.Stack.of(this).availabilityZones[0], // Same AZ as Aurora writer
      databaseCluster: auroraCluster,
      databaseName: dbNameParam.valueAsString,
      quicknodeApiToken: quicknodeApiTokenParam.valueAsString || undefined,
      quicknodeHost: quicknodeHostParam.valueAsString || undefined,
      celestiaSeed: celestiaSeedParam.valueAsString || undefined,
      branchName: branchNameParam.valueAsString || undefined,
      monitoringUrl: monitoringUrlParam.valueAsString || undefined,
      influxToken: influxTokenParam.valueAsString || undefined,
      alloyPassword: alloyPasswordParam.valueAsString || undefined,
      domainName: domainNameParam.valueAsString || undefined,
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

    // Output domain setup instructions if domain parameter is provided
    new cdk.CfnOutput(this, 'DomainSetupInstructions', {
      value: domainNameParam.valueAsString ? 
        `Point your domain ${domainNameParam.valueAsString} to the Elastic IP ${computeInfra.proxyEip.ref}` :
        'No domain name provided. Service is accessible via HTTP only at the Elastic IP.',
      description: 'Instructions for domain setup'
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

    // --------------- Set up temporary monitoring ---------------
    // This should be replaced with a grafana instance and more tailored alerting.

    // Monthly Costs (US East-1), according to claude.
    // CloudWatch Synthetics:
    // - $0.0012 per canary run
    // - 1 run/minute × 44,640 runs/month = ~$54/month
    // CloudWatch Alarms:
    // - $0.10 per alarm/month = $0.10/month
    // SNS:
    // - SMS: ~$0.0075 per message (only when alerting)
    // - Email: Free
    // Total: ~$54.10/month for continuous 1-minute monitoring
    // Create CloudWatch alarm for canary failures
    // Create SNS topic for alerting
    const alertTopic = new sns.Topic(this, 'AlertTopic', {
      displayName: 'SOV Rollup Alerts',
      topicName: `${cdk.Stack.of(this).stackName}-alerts`
    });

    // Create CloudWatch Synthetics canary for health check monitoring
    const healthCheckCanary = new synthetics.Canary(this, 'HealthCheckCanary', {
      canaryName: `${cdk.Stack.of(this).stackName.toLowerCase()}-health-check`,
      schedule: synthetics.Schedule.rate(cdk.Duration.minutes(1)),
      test: synthetics.Test.custom({
        code: synthetics.Code.fromInline(`
const synthetics = require('Synthetics');
const log = require('SyntheticsLogger');

const healthCheck = async function () {
    const config = synthetics.getConfiguration();
    config.setConfig({
        continueOnStepFailure: false,
        includeRequestHeaders: true,
        includeResponseHeaders: true,
        restrictedHeaders: [],
        restrictedUrlParameters: []
    });

    const endpointUrl = process.env.ENDPOINT_URL;
    if (!endpointUrl) {
        throw "ENDPOINT_URL environment variable not set";
    }

    let page = await synthetics.getPage();
    
    const response = await page.goto("http://" + endpointUrl + "/sequencer/ready", {
        waitUntil: 'networkidle0',
        timeout: 30000
    });
    
    if (response.status() < 200 || response.status() > 299) {
        throw "Failed health check with status: " + response.status();
    }
    
    log.info("Health check passed with status: " + response.status());
};

exports.handler = async () => {
    return await synthetics.executeStep('healthCheck', healthCheck);
};
        `),
        handler: 'index.handler'
      }),
      runtime: synthetics.Runtime.SYNTHETICS_NODEJS_PUPPETEER_6_2,
      environmentVariables: {
        ENDPOINT_URL: computeInfra.proxyEip.ref
      }
    });

    const canaryAlarm = new cloudwatch.Alarm(this, 'CanaryFailureAlarm', {
      alarmName: `${cdk.Stack.of(this).stackName}-health-check-failure`,
      alarmDescription: 'Alert when health check canary fails for 5 minutes',
      metric: healthCheckCanary.metricFailed({
        period: cdk.Duration.minutes(1),
        statistic: 'Sum'
      }),
      threshold: 1,
      evaluationPeriods: 5,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING // The failure metric only gets emitted when the canary fails, so we don't want to treat missing data as a breach.
    });

    // Add SNS action to the alarm
    canaryAlarm.addAlarmAction(new cloudwatchActions.SnsAction(alertTopic));

    // Output SNS topic ARN for subscription setup
    new cdk.CfnOutput(this, 'AlertTopicArn', {
      value: alertTopic.topicArn,
      description: 'SNS topic ARN for alert subscriptions'
    });

    // Output subscription commands
    new cdk.CfnOutput(this, 'SubscribeToAlertsEmailCommand', {
      value: `aws sns subscribe --topic-arn ${alertTopic.topicArn} --protocol email --notification-endpoint your-email@example.com --region ${cdk.Stack.of(this).region}`,
      description: 'Command to subscribe to email alerts (replace email)'
    });

    new cdk.CfnOutput(this, 'SubscribeToAlertsSmsCommand', {
      value: `aws sns subscribe --topic-arn ${alertTopic.topicArn} --protocol sms --notification-endpoint +1234567890 --region ${cdk.Stack.of(this).region}`,
      description: 'Command to subscribe to SMS alerts (replace phone number with +country code)'
    });
    // --------------- End of temporary monitoring ---------------
  }
}
