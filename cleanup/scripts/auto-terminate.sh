#!/bin/bash
# Script to automatically terminate EC2 instance after specified time
# This runs as a background process on instance startup

# Default timeout (1 hour = 3600 seconds)
TIMEOUT=${1:-3600}

echo "[$(date)] Auto-termination scheduled in $TIMEOUT seconds" > /var/log/auto-terminate.log

# Sleep for the specified time
sleep $TIMEOUT

echo "[$(date)] Timeout reached. Starting termination process..." >> /var/log/auto-terminate.log

# Get the instance ID from metadata service
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
echo "Instance ID: $INSTANCE_ID" >> /var/log/auto-terminate.log

# Cancel spot request if this is a spot instance
SPOT_REQUEST_ID=$(aws ec2 describe-spot-instance-requests \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --query "SpotInstanceRequests[0].SpotInstanceRequestId" \
  --output text 2>/dev/null || echo "None")

if [[ -n "$SPOT_REQUEST_ID" && "$SPOT_REQUEST_ID" != "None" ]]; then
  echo "Canceling spot request: $SPOT_REQUEST_ID" >> /var/log/auto-terminate.log
  aws ec2 cancel-spot-instance-requests --spot-instance-request-ids $SPOT_REQUEST_ID
  echo "Spot request canceled" >> /var/log/auto-terminate.log
fi

# Terminate the instance
echo "Terminating instance: $INSTANCE_ID" >> /var/log/auto-terminate.log
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
echo "Termination command sent" >> /var/log/auto-terminate.log

exit 0
