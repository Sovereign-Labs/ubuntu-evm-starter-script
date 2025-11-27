#!/bin/bash
set -e

# Get Mock DA Server IP Script
# Discovers the mock DA server instance IP by querying ASG tags
#
# Usage:
#   ./get_mock_da_server_ip.sh --stack-name <name> --region <region> [--wait] [--max-attempts <n>]
#
# Options:
#   --stack-name    CDK stack name (required)
#   --region        AWS region (required)
#   --wait          Wait and retry until instance is found
#   --max-attempts  Maximum retry attempts when --wait is used (default: 30)

STACK_NAME=""
REGION=""
WAIT=false
MAX_ATTEMPTS=30

while [[ $# -gt 0 ]]; do
  case $1 in
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --wait)
      WAIT=true
      shift
      ;;
    --max-attempts)
      MAX_ATTEMPTS="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$STACK_NAME" ] || [ -z "$REGION" ]; then
  echo "Error: Missing required arguments" >&2
  echo "Required: --stack-name, --region" >&2
  exit 1
fi

# Function to get mock DA server instance IP
get_mockda_server_ip() {
  # Find ASG name using tags
  local asg_name=$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --query "AutoScalingGroups[?Tags[?Key=='Stack' && Value=='${STACK_NAME}'] && Tags[?Key=='ASGType' && Value=='MockDaServer']].AutoScalingGroupName" \
    --output text | head -1)

  if [ -n "$asg_name" ] && [ "$asg_name" != "None" ]; then
    local instance_id=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$asg_name" \
      --region "$REGION" \
      --query "AutoScalingGroups[0].Instances[0].InstanceId" \
      --output text)

    if [ "$instance_id" != "None" ] && [ -n "$instance_id" ]; then
      aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$REGION" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" \
        --output text
    else
      echo ""
    fi
  else
    echo ""
  fi
}

if [ "$WAIT" = true ]; then
  # Wait for mock DA ASG instance to be available
  MOCK_DA_SERVER_IP=""
  for i in $(seq 1 $MAX_ATTEMPTS); do
    MOCK_DA_SERVER_IP=$(get_mockda_server_ip)
    if [ -n "$MOCK_DA_SERVER_IP" ] && [ "$MOCK_DA_SERVER_IP" != "None" ]; then
      echo "$MOCK_DA_SERVER_IP"
      exit 0
    fi
    echo "Waiting for mock DA ASG instance... (attempt $i/$MAX_ATTEMPTS)" >&2
    sleep 10
  done

  echo "ERROR: Could not find mock DA ASG instance IP after $MAX_ATTEMPTS attempts" >&2
  exit 1
else
  # Single attempt
  MOCK_DA_SERVER_IP=$(get_mockda_server_ip)
  if [ -n "$MOCK_DA_SERVER_IP" ] && [ "$MOCK_DA_SERVER_IP" != "None" ]; then
    echo "$MOCK_DA_SERVER_IP"
    exit 0
  else
    echo "ERROR: Could not find mock DA ASG instance IP" >&2
    exit 1
  fi
fi
