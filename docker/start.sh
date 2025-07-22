#!/bin/bash
set -e

echo "Starting X-Ray enabled R Plumber container..."
echo "Container started at: $(date)"
echo "Environment: AWS_REGION=${AWS_REGION:-us-east-1}"

# Start X-Ray daemon in background
echo "Starting X-Ray daemon for region: ${AWS_REGION:-us-east-1}"
echo "SageMaker should provide AWS credentials via IAM role..."

# Start X-Ray daemon with verbose logging
/usr/local/bin/xray --region ${AWS_REGION:-us-east-1} --log-level debug &
XRAY_PID=$!

# Wait for X-Ray daemon to be ready
echo "Waiting for X-Ray daemon to start..."
sleep 5

# Check if X-Ray daemon is responding (optional - don't fail if not)
for i in $(seq 1 10); do
    if nc -z 127.0.0.1 2000 2>/dev/null; then
        echo "X-Ray daemon is ready!"
        break
    fi
    echo "Waiting for X-Ray daemon... (attempt $i/10)"
    sleep 1
done

# Start R Plumber application
echo "Starting R Plumber application on port 8080..."
exec R -e "
library(plumber)
pr <- plumb('/opt/app/plumber.R')
pr\$run(host='0.0.0.0', port=8080)
" 