# X-Ray Subsegments for R - Simple Interface

This provides a minimal-friction way to add AWS X-Ray subsegments to your R code.

## For R Analysts: How to Add Tracing

You only need to know **one function**: `trace_operation()`

### Step 1: Keep your business logic functions pure

```r
# Your existing functions don't need to change
preprocess_data <- function(payload) {
  # Your existing preprocessing logic
  return(processed_data)
}

run_inference <- function(data) {
  # Your existing model inference logic  
  return(inference_result)
}

postprocess_results <- function(result) {
  # Your existing postprocessing logic
  return(final_result)
}
```

### Step 2: Wrap function calls for tracing

```r
# Just wrap your function calls with trace_operation()
processed_data <- trace_operation({
  preprocess_data(payload)
}, operation_name = "data-preprocessing")

inference_result <- trace_operation({
  run_inference(processed_data)
}, operation_name = "model-inference")

final_result <- trace_operation({
  postprocess_results(inference_result)
}, operation_name = "post-processing")
```

### You can also wrap multiple operations:

```r
# Trace an entire pipeline as one subsegment
final_result <- trace_operation({
  data <- preprocess_data(payload)
  result <- run_inference(data)
  postprocess_results(result)
}, operation_name = "full-pipeline")

# Or trace complex logic blocks
validation_result <- trace_operation({
  if (is.null(payload$input)) stop("Missing input")
  if (length(payload$input) == 0) stop("Empty input")
  cat("Validation passed\n")
  TRUE
}, operation_name = "input-validation")
```

## That's it!

- **No setup required** - X-Ray context is handled automatically
- **Thread-safe** - Ready for concurrent requests and `future` multi-threading
- **Same code works** with or without X-Ray enabled
- **Silent failure** - if X-Ray daemon isn't available, your code still works
- **Automatic timing** - subsegments automatically capture duration
- **Error handling** - failed operations are automatically marked as errors in X-Ray

## What you get in AWS X-Ray Console

When you use `trace_operation()`, you'll see:
- Main segment: `inference-request`
- Subsegments with your custom `operation_name`
- Timing information for each operation
- Success/failure status
- Error details if operations fail

## Testing

Run the test script to see it in action:
```bash
./test-subsegments.sh
```

## Files

- `plumber.R` - Full X-Ray integration with SageMaker headers
- `simple-metrics.R` - Simplified version with basic metrics
- `test-subsegments.sh` - Test script demonstrating the interface 