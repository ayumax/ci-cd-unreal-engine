#!/bin/bash
# Script to terminate EC2 spot instance and cancel spot request
set -e

# Arguments:
#   $1: Instance ID

if [ $# -lt 1 ]; then
    echo "Usage: $0 <instance-id>"
    exit 1
fi

INSTANCE_ID=$1
echo "Terminating EC2 instance: $INSTANCE_ID"

# Check if instance exists
INSTANCE_STATE=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null || echo "not-found")

if [ "$INSTANCE_STATE" = "not-found" ]; then
    echo "Instance not found or already terminated"
    exit 0
fi

# First cancel any associated spot request
echo "Checking for spot instance requests..."
SPOT_REQUEST_ID=$(aws ec2 describe-spot-instance-requests \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --query "SpotInstanceRequests[0].SpotInstanceRequestId" \
  --output text 2>/dev/null || echo "None")

if [[ -n "$SPOT_REQUEST_ID" && "$SPOT_REQUEST_ID" != "None" ]]; then
  echo "Canceling spot request"
  aws ec2 cancel-spot-instance-requests --spot-instance-request-ids $SPOT_REQUEST_ID
  echo "Spot request canceled successfully"
fi

# Try terminating via SSM first (graceful approach)
echo "Attempting graceful termination via SSM..."
aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=['sudo shutdown -h now']" \
  --output text &>/dev/null || echo "SSM command failed, will use direct termination"

# Force terminate via EC2 API (always works, less graceful)
echo "Terminating instance via EC2 API"
aws ec2 terminate-instances --instance-ids $INSTANCE_ID &>/dev/null
echo "Termination initiated"

# Wait for instance to terminate (up to 2 minutes)
echo "Waiting for instance to terminate..."
WAIT_TIME=0
MAX_WAIT=120
SLEEP_INTERVAL=10

while [ $WAIT_TIME -lt $MAX_WAIT ]; do
  STATUS=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "terminated")
  
  if [[ "$STATUS" == "terminated" ]]; then
    echo "Instance successfully terminated"
    break
  fi
  
  echo "Current status: $STATUS (waiting...)"
  sleep $SLEEP_INTERVAL
  WAIT_TIME=$((WAIT_TIME + SLEEP_INTERVAL))
done

if [ $WAIT_TIME -ge $MAX_WAIT ]; then
  echo "Warning: Instance termination timeout reached. Please check manually."
  exit 1
else
  echo "Termination completed successfully"
  exit 0
fi
