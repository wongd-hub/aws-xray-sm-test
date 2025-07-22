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

echo "🧹 AWS X-Ray Project Cleanup Script"
echo "=================================="
echo
echo "Choose cleanup option:"
echo "1) Destroy all resources (INCLUDING ECR repository and images) ⚠️"
echo "2) Destroy all resources EXCEPT ECR repository (RECOMMENDED) ✅"
echo "3) Only destroy SageMaker resources (keep S3 bucket and ECR) 🎯"
echo "4) Cancel"
echo

read -p "Enter your choice (1-4): " choice

case $choice in
    1)
        log "⚠️  WARNING: This will destroy ALL resources including ECR repository!"
        read -p "Are you absolutely sure? Type 'yes' to confirm: " confirm
        if [ "$confirm" = "yes" ]; then
            log "Destroying all resources..."
            cd terraform
            terraform destroy -auto-approve
            log_success "All resources destroyed!"
        else
            log "Destruction cancelled."
        fi
        ;;
    2)
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