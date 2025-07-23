#!/bin/bash

echo "Testing Simplified X-Ray Subsegments"
echo "===================================="

# Check if container is running
if ! docker ps | grep -q "xray-rocker"; then
    echo "Error: No X-Ray container found running. Please start the container first."
    echo "Run: cd docker && ./run_docker.sh"
    exit 1
fi

echo "Container is running. Testing simplified subsegments interface..."
echo

# Test 1: Test the main inference endpoint with automatic X-Ray detection
echo "Test 1: Testing /invocations endpoint with X-Ray trace header"
echo "-----------------------------------------------------------"
curl -X POST http://localhost:8080/invocations \
    -H "Content-Type: application/json" \
    -H "X-Amzn-Trace-Id: Root=1-$(printf '%x' $(date +%s))-$(openssl rand -hex 12)" \
    -d '{"input": "test data for automatic subsegments"}' | jq .

echo
echo "========================================="
echo

# Test 2: Test the simple test endpoint (creates its own trace)
echo "Test 2: Testing /test-simple endpoint (standalone tracing)"
echo "---------------------------------------------------------"
curl -X POST http://localhost:8080/test-simple \
    -H "Content-Type: application/json" \
    -d '{"input": "standalone test with simple interface"}' | jq .

echo
echo "========================================="
echo

# Test 3: Test with SageMaker custom attributes format (automatic detection)
echo "Test 3: Testing with SageMaker custom attributes (automatic detection)"
echo "--------------------------------------------------------------------"
trace_id="Root=1-$(printf '%x' $(date +%s))-$(openssl rand -hex 12)"
curl -X POST http://localhost:8080/invocations \
    -H "Content-Type: application/json" \
    -H "X-Amzn-SageMaker-Custom-Attributes: X-Amzn-Trace-Id=${trace_id}" \
    -d '{"input": "sagemaker trace test with automatic detection"}' | jq .

echo
echo "========================================="
echo

# Test 4: Test without any trace headers (should still work, no tracing)
echo "Test 4: Testing without trace headers (no tracing, just business logic)"
echo "----------------------------------------------------------------------"
curl -X POST http://localhost:8080/invocations \
    -H "Content-Type: application/json" \
    -d '{"input": "no tracing test"}' | jq .

echo
echo "========================================="
echo

# Test 5: Test error handling with automatic subsegments
echo "Test 5: Testing error handling with automatic subsegments"
echo "--------------------------------------------------------"
curl -X POST http://localhost:8080/invocations \
    -H "Content-Type: application/json" \
    -H "X-Amzn-Trace-Id: Root=1-$(printf '%x' $(date +%s))-$(openssl rand -hex 12)" \
    -d '{"missing_input": "this will cause an error"}' | jq .

echo
echo "========================================="
echo

# Test 6: Demonstrate how simple the user code is
echo "Test 6: Example of simple user code with trace_operation()"
echo "---------------------------------------------------------"
echo "In your R code, analysts just wrap existing function calls:"
echo ""
echo "# Keep your business logic functions pure:"
echo "preprocess_data <- function(payload) {"
echo "  # Your existing preprocessing logic"
echo "  return(processed_data)"
echo "}"
echo ""
echo "run_inference <- function(data) {"
echo "  # Your existing model inference logic"
echo "  return(inference_result)"
echo "}"
echo ""
echo "# Then wrap function calls for tracing:"
echo "processed_data <- trace_operation({"
echo "  preprocess_data(payload)"
echo "}, operation_name = 'data-preprocessing')"
echo ""
echo "inference_result <- trace_operation({"
echo "  run_inference(processed_data)"
echo "}, operation_name = 'model-inference')"
echo ""
echo "# You can even wrap multiple operations:"
echo "final_result <- trace_operation({"
echo "  result1 <- preprocess_data(payload)"
echo "  result2 <- run_inference(result1)"
echo "  postprocess_results(result2)"
echo "}, operation_name = 'full-pipeline')"
echo ""

echo "All tests completed!"
echo
echo "Key benefits of the simplified interface:"
echo "========================================"
echo "✓ Business logic functions stay pure (no tracing code embedded)"
echo "✓ Just wrap function calls: trace_operation({your_function()}, operation_name = 'name')"
echo "✓ Same functions work with or without tracing"
echo "✓ Zero friction - existing code doesn't need to change"
echo "✓ Automatic context detection from SageMaker headers"
echo "✓ Silent failure when X-Ray is not available"
echo "✓ Can wrap single functions or entire code blocks"
echo
echo "To view X-Ray traces:"
echo "1. Go to AWS X-Ray console"
echo "2. Click on 'Traces' in the left sidebar"
echo "3. Look for traces with service name 'inference-request'"
echo "4. Click on a trace to see the subsegments breakdown"
echo
echo "You should see subsegments for:"
echo "- data-preprocessing"
echo "- model-inference"  
echo "- post-processing"
echo "- validation, processing, finalization (from /test-simple)" 