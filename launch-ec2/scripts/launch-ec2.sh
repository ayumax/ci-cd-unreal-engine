#!/bin/bash
set -e

# Script to launch EC2 spot instance
# Arguments:
#   $1: Repository name (e.g. "username/repo")
#   $2: PR number (e.g. "123")
#   $3: Unreal Engine version (e.g. "5.5")

# Validate arguments
if [ $# -lt 3 ]; then
    echo "Usage: $0 <repository-name> <pr-number> <ue-version>"
    exit 1
fi

REPO_NAME=$1
PR_NUMBER=$2
UE_VERSION=$3

# Get script directory path
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# AWS related variables
AWS_REGION=${AWS_REGION:-"ap-northeast-1"}

echo "==== Configuration ===="
echo "Repository: $REPO_NAME"
echo "PR number: $PR_NUMBER"
echo "UE version: $UE_VERSION"
echo "======================"

# Prepare inline user data script
echo "Preparing user data script..."
cat > userdata-temp.sh << 'USERDATA_SCRIPT'
#!/bin/bash
# Log all output
exec > >(tee /var/log/user-data.log) 2>&1

echo "Starting user data script: $(date)"

# Setup environment
mkdir -p /opt/ci-scripts
cd /opt/ci-scripts

# Environment variables
REPO_FULL_NAME="{{REPO_FULL_NAME}}"
PR_NUMBER="{{PR_NUMBER}}"
RUNNER_NAME="unreal-ci-pr-{{PR_NUMBER}}"

# Configure Docker
systemctl start docker
systemctl enable docker

# Install required packages
sudo yum install -y jq python3 python3-pip libicu

# Get GitHub PAT from Parameter Store
GITHUB_PAT=$(aws ssm get-parameter --name "/unreal-cicd/github-pat" --with-decryption --query "Parameter.Value" --output text)
if [ -z "$GITHUB_PAT" ]; then
    echo "Error: Failed to get GitHub PAT"
    exit 1
fi

# Get runner registration token
REGISTRATION_TOKEN=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_PAT" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$REPO_FULL_NAME/actions/runners/registration-token" | \
  jq -r '.token')
if [ -z "$REGISTRATION_TOKEN" ]; then
    echo "Error: Failed to get registration token"
    exit 1
fi

# Configure and start runner
su - ec2-user -c "cd /opt/actions-runner && ./config.sh --url https://github.com/$REPO_FULL_NAME --token $REGISTRATION_TOKEN --name $RUNNER_NAME --labels \"self-hosted,unreal-engine,ue5,Linux,X64,pr-$PR_NUMBER\" --unattended"
su - ec2-user -c "cd /opt/actions-runner && ./run.sh"

# Prepare test environment
mkdir -p /opt/test-runner
chmod 755 /opt/test-runner
touch /var/lib/cloud/instance/boot-finished

echo "User data script completed: $(date)"
USERDATA_SCRIPT

# Replace variables in the user data script
echo "Configuring user data script..."
sed -i "s|{{REPO_FULL_NAME}}|${REPO_NAME}|g" userdata-temp.sh
sed -i "s|{{PR_NUMBER}}|${PR_NUMBER}|g" userdata-temp.sh

# Get AMI ID
echo "Looking for Unreal Engine ${UE_VERSION} AMI..."
UE_VERSION_DASH=$(echo ${UE_VERSION} | tr '.' '-')
AMI_ID=$(aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=unreal-cicd-${UE_VERSION_DASH}*" "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
    echo "Error: No AMI found for UE ${UE_VERSION}"
    exit 1
fi

echo "Using AMI: $AMI_ID"

# Instance type candidates
INSTANCE_TYPES=("c5.2xlarge" "c5a.2xlarge" "c6i.2xlarge" "c6a.2xlarge" "m5.2xlarge" "r5.xlarge")

# Find available subnets
echo "Finding available subnets..."
SUBNET_IDS=($(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=*-public-subnet-*" \
  --query "Subnets[*].SubnetId" \
  --output text))

if [ ${#SUBNET_IDS[@]} -eq 0 ]; then
    echo "Error: No suitable subnets found"
    exit 1
fi

# Get security group
echo "Finding security group..."
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=*-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text)

if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    echo "Error: No security group found"
    exit 1
fi

# Get IAM instance profile
echo "Finding IAM instance profile..."
INSTANCE_PROFILE=$(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName, '-ec2-instance-profile') || contains(InstanceProfileName, 'ec2_instance_profile')].InstanceProfileName" \
  --output text | head -n 1)

if [ -z "$INSTANCE_PROFILE" ] || [ "$INSTANCE_PROFILE" == "None" ]; then
    echo "Error: No instance profile found"
    exit 1
fi

# Base64 encode user data
USERDATA=$(base64 -w 0 userdata-temp.sh)

# Launch success flag
SUCCESS=false
SPOT_REQUEST_ID=""

# Try each subnet with each instance type
echo "Attempting to launch EC2 spot instance..."
for SUBNET in "${SUBNET_IDS[@]}"; do
    for INSTANCE_TYPE in "${INSTANCE_TYPES[@]}"; do
        echo "Trying: $INSTANCE_TYPE in subnet $SUBNET"
        
        # Debug mode to capture errors
        set +e
        ERROR_FILE=$(mktemp)
        RESPONSE=$(aws ec2 request-spot-instances \
            --instance-count 1 \
            --type one-time \
            --tag-specifications "ResourceType=spot-instances-request,Tags=[{Key=Name,Value=unreal-ci-pr-${PR_NUMBER}},{Key=PR,Value=${PR_NUMBER}}]" \
            --launch-specification "{
                \"ImageId\":\"${AMI_ID}\",
                \"InstanceType\":\"${INSTANCE_TYPE}\",
                \"SubnetId\":\"${SUBNET}\",
                \"SecurityGroupIds\":[\"${SG_ID}\"],
                \"IamInstanceProfile\":{\"Name\":\"${INSTANCE_PROFILE}\"},
                \"UserData\":\"${USERDATA}\",
                \"KeyName\":\"AWSOndemandCICD-key\",
                \"BlockDeviceMappings\":[
                    {
                        \"DeviceName\":\"/dev/xvda\",
                        \"Ebs\":{
                            \"VolumeSize\":60,
                            \"VolumeType\":\"gp3\",
                            \"DeleteOnTermination\":true
                        }
                    }
                ]
            }" 2> ${ERROR_FILE})
        EXIT_CODE=$?
        set -e
        
        # Check for errors
        if [ ${EXIT_CODE} -eq 0 ]; then
            echo "Spot instance request created successfully!"
            SUCCESS=true
            SPOT_REQUEST_ID=$(echo $RESPONSE | jq -r '.SpotInstanceRequests[0].SpotInstanceRequestId')
            break 2  # Break both loops
        else
            ERROR_MSG=$(cat ${ERROR_FILE})
            rm -f ${ERROR_FILE}
            
            # Classify AWS API error codes
            if echo "${ERROR_MSG}" | grep -q "InsufficientInstanceCapacity"; then
                echo "Error: Insufficient capacity for $INSTANCE_TYPE, trying next type..."
                continue
            elif echo "${ERROR_MSG}" | grep -q "MaxSpotInstanceCountExceeded"; then
                echo "Error: Maximum spot instance count exceeded"
                exit 1
            elif echo "${ERROR_MSG}" | grep -q "RequestLimitExceeded"; then
                echo "Error: API request limit exceeded, waiting before retry"
                sleep 10
                continue
            else
                echo "Error: Failed to launch instance"
                continue
            fi
        fi
    done
done

if [ "$SUCCESS" != "true" ]; then
    echo "Error: All launch attempts failed"
    exit 1
fi

# Wait for instance ID
echo "Waiting for spot instance to start..."
INSTANCE_ID=""
for i in {1..15}; do
    INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
        --spot-instance-request-ids $SPOT_REQUEST_ID \
        --query "SpotInstanceRequests[0].InstanceId" \
        --output text)
    
    if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "null" ] && [ "$INSTANCE_ID" != "None" ]; then
        echo "Instance ID obtained"
        
        # Add Name tag
        aws ec2 create-tags \
            --resources $INSTANCE_ID \
            --tags "Key=Name,Value=unreal-ci-pr-${PR_NUMBER}" "Key=PR,Value=${PR_NUMBER}"
        
        # Save EC2 instance info to file
        echo "instance_id=$INSTANCE_ID" > ec2-info.txt
        echo "pr_number=$PR_NUMBER" >> ec2-info.txt
        echo "repo_name=$REPO_NAME" >> ec2-info.txt
        
        break
    fi
    echo "Waiting for instance ID... ($i/15)"
    sleep 10
done

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "null" ] || [ "$INSTANCE_ID" == "None" ]; then
    echo "Error: Failed to get instance ID"
    exit 1
fi

# Wait for instance to start running
echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get public IP
INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo "Instance startup complete"

# Clean up temporary files
rm -f userdata-temp.sh

# Set GitHub Actions outputs
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "instance_id=$INSTANCE_ID" >> $GITHUB_OUTPUT
    echo "instance_ip=$INSTANCE_IP" >> $GITHUB_OUTPUT
fi

exit 0

