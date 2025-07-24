#!/bin/bash

# Test script for SageMaker async endpoint with X-Ray tracing

set -e

# Your endpoint details
ENDPOINT_NAME="xray-rocker-model-async-endpoint"
REGION="us-east-1"
ENDPOINT_URL="https://runtime.sagemaker.${REGION}.amazonaws.com/endpoints/${ENDPOINT_NAME}/async-invocations"

# Generate a unique trace ID for X-Ray
TRACE_ID="1-$(printf '%08x' $(date +%s))-$(printf '%012x' $$)"

echo "🚀 Testing SageMaker Async Endpoint with X-Ray Tracing"
echo "======================================================"
echo "Endpoint: $ENDPOINT_URL"
echo "Trace ID: $TRACE_ID"
echo

# Create test payload - simple JSON
TEST_PAYLOAD='{"input": "test data for subsegments"}'

echo "📦 Sending payload: $TEST_PAYLOAD"
echo

# Get S3 bucket name from Terraform
cd terraform
S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
cd ..

if [ -z "$S3_BUCKET" ]; then
    echo "❌ Could not get S3 bucket name from Terraform. Is infrastructure deployed?"
    exit 1
fi

echo "📦 S3 Bucket: $S3_BUCKET"

# Save payload to temporary file and upload to S3
TEMP_FILE=$(mktemp /tmp/sagemaker-payload.XXXXXX.json)
echo "$TEST_PAYLOAD" > "$TEMP_FILE"

INPUT_S3_KEY="inputs/test-$(date +%s).json"
echo "⬆️  Uploading payload to S3..."
aws s3 cp "$TEMP_FILE" "s3://$S3_BUCKET/$INPUT_S3_KEY"

echo "🔄 Making async invocation request..."

# Use AWS CLI for async invocation with X-Ray trace header
RESPONSE=$(aws sagemaker-runtime invoke-endpoint-async \
  --endpoint-name "$ENDPOINT_NAME" \
  --content-type "application/json" \
  --input-location "s3://$S3_BUCKET/$INPUT_S3_KEY" \
  --invocation-timeout-seconds 3600 \
  --custom-attributes "X-Amzn-Trace-Id=$TRACE_ID" \
  --region "$REGION" 2>&1 || echo "Failed to invoke endpoint")

echo "📥 Response: $RESPONSE"
echo

if echo "$RESPONSE" | grep -q "InferenceId"; then
    echo "✅ Async invocation successful!"
    INFERENCE_ID=$(echo "$RESPONSE" | grep -o '"InferenceId": "[^"]*"' | cut -d'"' -f4)
    echo "🆔 Inference ID: $INFERENCE_ID"
    echo
    echo "🔍 To view X-Ray traces:"
    echo "1. Go to AWS Console → X-Ray → Traces"
    echo "2. Look for trace ID: $TRACE_ID"
    echo "3. Or search by service name: 'my-inference'"
    echo "4. Filter by time range: last 5 minutes"
    echo
    echo "📊 Check results in S3 when processing completes:"
    echo "   aws s3 ls s3://$S3_BUCKET/async-output/"
    echo "   aws s3 cp s3://$S3_BUCKET/async-output/\$INFERENCE_ID.out ."
else
    echo "❌ Request failed. Response: $RESPONSE"
fi

# Cleanup
rm -f "$TEMP_FILE" 