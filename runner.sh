#! /bin/bash

# Sample usage:
# ./runner.sh true

set -e  # Exit on any error

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1"
}

force_docker_rebuild=${1:-false}

# Ensure we're in the correct directory (where the script is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log "Starting deployment script with force_docker_rebuild=$force_docker_rebuild"
log "Working directory: $(pwd)"

# Test AWS connectivity and get account ID
log "Testing AWS connectivity..."
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    log_error "Unable to connect to AWS or credentials are invalid."
    exit 1
fi
log_success "AWS connectivity verified"

# Auto-detect account ID if not set
if [ -z "$ACCOUNT_ID" ]; then
    log "ACCOUNT_ID not set, auto-detecting from AWS..."
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -n "$ACCOUNT_ID" ]; then
        log "Auto-detected AWS Account ID: $ACCOUNT_ID"
    else
        log_error "Failed to auto-detect AWS Account ID"
        exit 1
    fi
else
    log "Using provided ACCOUNT_ID: $ACCOUNT_ID"
fi

# ECR repository will be managed by Terraform

# Check if Docker image exists
log "Checking if Docker image 'xray-rocker-model' exists..."
if ! docker images | grep -q "xray-rocker-model" || [ "$force_docker_rebuild" = true ]; then
    if [ "$force_docker_rebuild" = true ]; then
        log "Force rebuild requested. Building Docker image..."
    else
        log "Docker image does not exist. Building..."
    fi
    (
        cd docker && \
        log "Building Docker image in docker/ directory..." && \
        docker build -t xray-rocker-model:latest . 
    )
    log_success "Docker image built successfully"
else
    log "Docker image already exists, skipping build"
fi

# Test Docker image
log "Preparing to test Docker image..."
# if docker/sample.json doesn't exist, create it
if [ ! -f docker/sample.json ]; then
    log "Creating sample.json for testing..."
    echo "{\"foo\": \"bar\"}" > docker/sample.json
else
    log "Found existing docker/sample.json"
fi

# Run & test Docker image
log "Starting Docker container for testing..."

# Start the container, wait for port 8080 to be ready, then POST sample.json to /invocations
log "Running container with AWS region us-east-1..."
container_id=$(
  docker run --rm -d \
    -e AWS_REGION=us-east-1 \
    -v ~/.aws:/root/.aws:ro \
    -p 8080:8080 \
    --name my-test-container \
    xray-rocker-model:latest
)
log "Container started with ID: $container_id"

# Wait for the Plumber API to be ready (timeout after 30s)
log "Waiting for Plumber API to be ready (timeout: 30s)..."
api_ready=false
for i in {1..30}; do
  if curl -s http://localhost:8080/ping | grep -q "ok"; then
    log_success "API is ready after ${i}s"
    api_ready=true
    break
  fi
  if [ $i -eq 30 ]; then
    log_error "API failed to start within 30 seconds"
    docker logs "$container_id"
    docker stop "$container_id" > /dev/null 2>&1
    exit 1
  fi
  echo -n "."
  sleep 1
done

if [ "$api_ready" = true ]; then
    log "Testing /invocations endpoint..."
    
    # Verify the sample.json file exists and show its contents
    if [ -f "docker/sample.json" ]; then
        log "Found docker/sample.json with contents: $(cat docker/sample.json)"
    else
        log_error "docker/sample.json not found in current directory: $(pwd)"
        log "Contents of docker/ directory: $(ls -la docker/ 2>/dev/null || echo 'Directory not found')"
        exit 1
    fi
    
    # Send sample.json to the /invocations endpoint
    log "Sending POST request to /invocations..."
    response=$(curl -s -X POST \
      -H "Content-Type: application/json" \
      -H "X-Amzn-Trace-Id: Root=1-67891233-abcdef012345678912345678;Sampled=1" \
      --data-binary @docker/sample.json \
      http://localhost:8080/invocations)
    
    log "API Response: $response"
    
    # Check if the response indicates success
    if echo "$response" | grep -q "error"; then
        log_error "API returned an error response"
        log "Checking container logs for more details:"
        docker logs "$container_id" --tail 20
    else
        log_success "API test completed successfully"
    fi
fi

# Stop and remove the container
log "Stopping and removing container..."
if docker stop "$container_id" > /dev/null 2>&1; then
    log_success "Container stopped successfully"
else
    log_error "Failed to stop container"
    docker logs "$container_id"
    exit 1
fi

log_success "Docker container test completed successfully"

# Push to ECR (repository managed by Terraform)
if [ -n "$ACCOUNT_ID" ]; then
    log "Preparing to push to ECR repository..."
    
    log "Logging into ECR..."
    if aws ecr get-login-password \
        --region us-east-1 \
        | docker login \
        --username AWS \
        --password-stdin \
        ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com; then
        log_success "ECR login successful"
        
        log "Tagging image for ECR..."
        docker tag xray-rocker-model:latest ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/xray-rocker-model:latest
        
        log "Pushing image to ECR..."
        if docker push ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/xray-rocker-model:latest; then
            log_success "Image pushed to ECR successfully"
        else
            log_error "Failed to push image to ECR"
            exit 1
        fi
    else
        log_error "ECR login failed"
        exit 1
    fi
else
    log "ACCOUNT_ID not set, skipping ECR push"
fi

# Deploy with Terraform
log "Starting Terraform deployment..."

# Check if SageMaker endpoint exists and delete it before applying Terraform
log "Checking for existing SageMaker endpoint..."
ENDPOINT_NAME="xray-rocker-model-async-endpoint"
if aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" >/dev/null 2>&1; then
    log "Found existing endpoint '$ENDPOINT_NAME', deleting it..."
    aws sagemaker delete-endpoint --endpoint-name "$ENDPOINT_NAME"
    
    # Wait for endpoint deletion to complete
    log "Waiting for endpoint deletion to complete..."
    while aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" >/dev/null 2>&1; do
        echo -n "."
        sleep 10
    done
    log_success "Endpoint deletion completed"
else
    log "No existing endpoint found, proceeding with deployment"
fi

(
    cd terraform && \
    log "Initializing Terraform..." && \
    terraform init && \
    log_success "Terraform initialized" && \
    log "Creating Terraform plan..." && \
    terraform plan -out=tfplan.out && \
    log_success "Terraform plan created" && \
    log "Applying Terraform plan..." && \
    terraform apply tfplan.out && \
    log_success "Terraform deployment completed"
)

log_success "Deployment script completed successfully!"



