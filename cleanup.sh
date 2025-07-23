#!/bin/bash

# Cleanup script for tf-aws-xray project

set -e

# Logging functions (reuse from runner.sh)
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1"
}

# Function to empty S3 bucket completely
empty_s3_bucket() {
    local bucket_name="$1"
    
    if [ -z "$bucket_name" ]; then
        log "No S3 bucket name provided, skipping S3 cleanup"
        return 0
    fi
    
    log "Checking if S3 bucket '$bucket_name' exists..."
    
    # Check if bucket exists
    if ! aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        log "S3 bucket '$bucket_name' does not exist, skipping cleanup"
        return 0
    fi
    
    log "Emptying S3 bucket '$bucket_name'..."
    
    # Delete all object versions and delete markers
    log "Deleting all object versions..."
    aws s3api list-object-versions --bucket "$bucket_name" --output json | \
    jq -r '.Versions[]? | "--version-id \(.VersionId) \(.Key)"' | \
    while read -r version_args; do
        if [ -n "$version_args" ]; then
            aws s3api delete-object --bucket "$bucket_name" $version_args
        fi
    done
    
    # Delete all delete markers
    log "Deleting all delete markers..."
    aws s3api list-object-versions --bucket "$bucket_name" --output json | \
    jq -r '.DeleteMarkers[]? | "--version-id \(.VersionId) \(.Key)"' | \
    while read -r marker_args; do
        if [ -n "$marker_args" ]; then
            aws s3api delete-object --bucket "$bucket_name" $marker_args
        fi
    done
    
    # Delete any remaining objects (fallback)
    log "Deleting any remaining objects..."
    aws s3 rm "s3://$bucket_name" --recursive || true
    
    log_success "S3 bucket '$bucket_name' emptied successfully"
}

# Function to get S3 bucket name from Terraform
get_s3_bucket_name() {
    cd terraform
    local bucket_name
    bucket_name=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
    cd ..
    echo "$bucket_name"
}

echo "🧹 AWS X-Ray Project Cleanup Script"
echo "=================================="
echo
echo "Choose cleanup option:"
echo "1) Destroy all resources (INCLUDING ECR repository and images) ⚠️"
echo "2) Destroy all resources EXCEPT ECR repository (RECOMMENDED) ✅"
echo "3) Only destroy SageMaker resources (keep S3 bucket and ECR) 🎯"
echo "4) Only empty S3 bucket (no infrastructure changes) 🪣"
echo "5) Cancel"
echo

read -p "Enter your choice (1-5): " choice

case $choice in
    1)
        log "⚠️  WARNING: This will destroy ALL resources including ECR repository!"
        read -p "Are you absolutely sure? Type 'yes' to confirm: " confirm
        if [ "$confirm" = "yes" ]; then
            log "Getting S3 bucket name..."
            S3_BUCKET_NAME=$(get_s3_bucket_name)
            
            log "Emptying S3 bucket before destruction..."
            empty_s3_bucket "$S3_BUCKET_NAME"
            
            log "Destroying all resources..."
            cd terraform
            terraform destroy -auto-approve
            log_success "All resources destroyed!"
        else
            log "Destruction cancelled."
        fi
        ;;
    2)
        log "Getting S3 bucket name..."
        S3_BUCKET_NAME=$(get_s3_bucket_name)
        
        log "Emptying S3 bucket before destruction..."
        empty_s3_bucket "$S3_BUCKET_NAME"
        
        log "Removing ECR repository from Terraform management..."
        cd terraform
        terraform state rm aws_ecr_repository.model_repo || true
        log "Destroying remaining resources..."
        terraform destroy -auto-approve
        log_success "Resources destroyed! ECR repository preserved."
        ;;
    3)
        log "Destroying only SageMaker resources..."
        cd terraform
        terraform destroy -auto-approve \
            -target=aws_sagemaker_endpoint.async_endpoint \
            -target=aws_sagemaker_endpoint_configuration.async_cfg \
            -target=aws_sagemaker_model.model \
            -target=aws_iam_role_policy_attachment.sagemaker_s3_attach \
            -target=aws_iam_role_policy_attachment.sagemaker_xray_attach \
            -target=aws_iam_role.sagemaker_exec \
            -target=aws_iam_policy.s3_policy \
            -target=aws_iam_policy.xray_policy
        log_success "SageMaker resources destroyed! S3 bucket and ECR preserved."
        ;;
    4)
        log "Getting S3 bucket name..."
        S3_BUCKET_NAME=$(get_s3_bucket_name)
        
        log "Emptying S3 bucket only..."
        empty_s3_bucket "$S3_BUCKET_NAME"
        log_success "S3 bucket emptied! No infrastructure changes made."
        ;;
    5)
        log "Cleanup cancelled."
        exit 0
        ;;
    *)
        log_error "Invalid choice. Please run the script again."
        exit 1
        ;;
esac

echo
log "Cleanup completed! 🎉" 