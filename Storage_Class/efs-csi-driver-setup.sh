#!/usr/bin/env bash
set -e

# ==========================================
# CONFIGURATION - UPDATE THESE VARIABLES
# ==========================================
CLUSTER_NAME="my-eks-cluster"
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="123456789012"
NAMESPACE="default"

# Color outputs
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Starting EFS CSI Setup for EKS Cluster: ${CLUSTER_NAME} ===${NC}"

# ------------------------------------------
# Step 1: IAM Policy & ServiceAccount
# ------------------------------------------
echo -e "\n${BLUE}[Step 1/5] Setting up IAM Policy and Role...${NC}"

POLICY_NAME="AmazonEKS_EFS_CSI_Driver_Policy"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

# Check if policy exists, if not create it
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "Downloading IAM policy document..."
    curl -s -O https://raw.githubusercontent.com/kubernetes-sigs/aws-efs-csi-driver/master/docs/iam-policy-example.json
    
    echo "Creating IAM policy $POLICY_NAME..."
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam-policy-example.json
    rm iam-policy-example.json
else
    echo "IAM policy $POLICY_NAME already exists."
fi

echo "Creating IAM ServiceAccount for EFS CSI driver..."
eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --namespace kube-system \
    --name efs-csi-controller-sa \
    --attach-policy-arn "$POLICY_ARN" \
    --approve \
    --region "$AWS_REGION" || echo "Service account already exists or updated."

# ------------------------------------------
# Step 2: Install EFS CSI Driver Add-on
# ------------------------------------------
echo -e "\n${BLUE}[Step 2/5] Installing EFS CSI Driver Add-on...${NC}"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/eksctl-${CLUSTER_NAME}-addon-aws-efs-csi-driver-role"

aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-efs-csi-driver \
    --service-account-role-arn "$ROLE_ARN" \
    --region "$AWS_REGION" || echo "Addon already exists or creation in progress."

# Wait briefly for driver pods
echo "Waiting for CSI Driver pods to initialize..."
kubectl rollout status deployment/efs-csi-controller -n kube-system --timeout=60s || true

# ------------------------------------------
# Step 3: Provision EFS File System & SG
# ------------------------------------------
echo -e "\n${BLUE}[Step 3/5] Provisioning EFS and Security Groups...${NC}"

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text)
CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" --query "Vpcs[0].CidrBlock" --output text)

echo "VPC ID: $VPC_ID | CIDR: $CIDR"

SG_NAME="EKS-EFS-SecurityGroup-${CLUSTER_NAME}"
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" --region "$AWS_REGION" --query "SecurityGroups[0].GroupId" --output text)

if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
    echo "Creating Security Group for EFS..."
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "EKS EFS Security Group for $CLUSTER_NAME" \
        --vpc-id "$VPC_ID" \
        --region "$AWS_REGION" \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 2049 \
        --cidr "$CIDR" \
        --region "$AWS_REGION"
fi

echo "Security Group ID: $SG_ID"

# Create EFS File System
EFS_NAME="eks-efs-${CLUSTER_NAME}"
FILE_SYSTEM_ID=$(aws efs describe-file-systems --region "$AWS_REGION" --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId" --output text)

if [ -z "$FILE_SYSTEM_ID" ]; then
    echo "Creating EFS File System..."
    FILE_SYSTEM_ID=$(aws efs create-file-system \
        --region "$AWS_REGION" \
        --performance-mode generalPurpose \
        --tags Key=Name,Value="$EFS_NAME" \
        --query "FileSystemId" \
        --output text)
fi

echo "EFS File System ID: $FILE_SYSTEM_ID"

# Wait until EFS is available
echo "Waiting for EFS state to become available..."
aws efs wait file-system-available --file-system-id "$FILE_SYSTEM_ID" --region "$AWS_REGION"

# Get Subnets and Create Mount Targets
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.subnetIds[*]" --output text)

for SUBNET in $SUBNET_IDS; do
    EXISTS=$(aws efs describe-mount-targets --file-system-id "$FILE_SYSTEM_ID" --region "$AWS_REGION" --query "MountTargets[?SubnetId=='${SUBNET}'].MountTargetId" --output text)
    if [ -z "$EXISTS" ]; then
        echo "Creating mount target in subnet: $SUBNET"
        aws efs create-mount-target \
            --file-system-id "$FILE_SYSTEM_ID" \
            --subnet-id "$SUBNET" \
            --security-groups "$SG_ID" \
            --region "$AWS_REGION" || true
    else
        echo "Mount target already exists in subnet: $SUBNET"
    fi
done
