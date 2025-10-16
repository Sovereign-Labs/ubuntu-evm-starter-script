export function generateHealthCheckScript(healthCheckPort: string, maxNodeSetupTimeMinutes: number): string {
  return `#!/bin/bash

HEALTHCHECK_PORT=\${HEALTHCHECK_PORT:-${healthCheckPort}}
MAX_NODE_SETUP_TIME_MINUTES=\${MAX_NODE_SETUP_TIME_MINUTES:-${maxNodeSetupTimeMinutes}}
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
LAUNCH_TIME=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION --query "Reservations[0].Instances[0].LaunchTime" --output text)
LAUNCH_TIMESTAMP=$(date -d "$LAUNCH_TIME" +%s)
CURRENT_TIMESTAMP=$(date +%s)
ELAPSED_MINUTES=$(( ($CURRENT_TIMESTAMP - $LAUNCH_TIMESTAMP) / 60 ))

# Skip health check during grace period
if [ $ELAPSED_MINUTES -lt $MAX_NODE_SETUP_TIME_MINUTES ]; then
    echo "Instance still in grace period ($ELAPSED_MINUTES/$MAX_NODE_SETUP_TIME_MINUTES minutes)"
    exit 0
fi

# Perform health check
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$HEALTHCHECK_PORT/healthcheck || echo "000")

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    echo "Health check passed: HTTP $HTTP_STATUS"
    aws autoscaling set-instance-health --instance-id $INSTANCE_ID --health-status Healthy --region $REGION
else
    echo "Health check failed: HTTP $HTTP_STATUS"
    aws autoscaling set-instance-health --instance-id $INSTANCE_ID --health-status Unhealthy --region $REGION
fi`;
}