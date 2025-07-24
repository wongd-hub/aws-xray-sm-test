#!/bin/bash

# Simple X-Ray test - sends UDP packet directly to test X-Ray daemon

echo "🔍 Testing X-Ray Daemon Connectivity"
echo "======================================"

# Generate a simple X-Ray trace segment
TRACE_ID="1-$(printf '%08x' $(date +%s))-$(printf '%012x' $$)"
SEGMENT_ID=$(printf '%08x' $$)

SEGMENT='{
  "name": "test-segment",
  "id": "'$SEGMENT_ID'",
  "trace_id": "'$TRACE_ID'",
  "start_time": '$(date +%s)',
  "end_time": '$(date +%s)',
  "annotations": {
    "test": "direct-xray-test"
  }
}'

echo "📤 Sending test segment to X-Ray daemon..."
echo "Trace ID: $TRACE_ID"
echo

# Try to send directly via netcat (if available)
if command -v nc >/dev/null 2>&1; then
    echo "$SEGMENT" | nc -u 127.0.0.1 2000
    echo "✅ Sent via netcat to 127.0.0.1:2000"
else
    echo "⚠️  netcat not available, skipping direct test"
fi

echo
echo "🔍 Check X-Ray console for trace: $TRACE_ID"
echo "   Time: $(date)" 