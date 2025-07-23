library(plumber)
library(jsonlite)

# Minimal X-Ray helpers (thread-safe)
rand_hex <- function(n) {
  paste0(sample(c(0:9, letters[1:6]), n, replace = TRUE), collapse = "")
}

.send_subsegment <- function(name, start_time, end_time, context, annotations = list(), error = NULL) {
  if (!context$enabled || is.null(context$trace_header)) return(NULL)
  
  seg <- list(
    name = name,
    id = rand_hex(16),
    trace_id = extract_root(context$trace_header),
    parent_id = context$parent_segment_id,
    type = "subsegment",
    start_time = start_time,
    end_time = end_time,
    annotations = annotations
  )
  
  if (!is.null(error)) {
    seg$error <- TRUE
    seg$cause <- list(exceptions = list(list(message = error, type = "InferenceError")))
  }
  
  payload <- toJSON(seg, auto_unbox = TRUE)
  tryCatch({
    header <- '{"format": "json", "version": 1}'
    full_payload <- paste0(header, "\n", payload)
    cmd <- sprintf("printf %s | nc -u -w1 127.0.0.1 2000", shQuote(full_payload))
    system(cmd, ignore.stdout = TRUE, ignore.stderr = TRUE)
  }, error = function(e) {
    # Silently handle X-Ray failures
  })
}

# Helper to extract trace root
extract_root <- function(trace_header) {
  if (is.null(trace_header) || length(trace_header) == 0) {
    return(NULL)
  }
  
  # Handle two formats:
  # 1. "Root=1-xxx-xxx" (full format)
  # 2. "1-xxx-xxx" (just the trace ID part)
  if (grepl("Root=", trace_header)) {
    # Extract from "Root=1-xxx-xxx" format
    m <- regmatches(trace_header, regexec("Root=([^;]+)", trace_header))[[1]]
    if (length(m) > 1) m[2] else NULL
  } else if (grepl("^1-[0-9a-f]+-[0-9a-f]+", trace_header)) {
    # Already in "1-xxx-xxx" format, use as-is
    trace_header
  } else {
    NULL
  }
}

# PUBLIC API: Simple tracing function for users (thread-safe) ----

#' Trace an operation with X-Ray subsegments and metrics
#' 
#' @param expr R expression to execute and trace
#' @param operation_name Name for the operation (will appear in X-Ray console)
#' @return Result of the expression
trace_operation <- function(expr, operation_name = "operation") {
  # Look for xray_context in the calling environment (thread-safe)
  context <- tryCatch({
    get("xray_context", envir = parent.frame())
  }, error = function(e) {
    list(enabled = FALSE, trace_header = NULL, parent_segment_id = NULL)
  })
  
  if (!context$enabled) {
    # No tracing context - just execute and return
    return(eval.parent(substitute(expr)))
  }
  
  start_time <- as.numeric(Sys.time())
  
  tryCatch({
    result <- eval.parent(substitute(expr))
    end_time <- as.numeric(Sys.time())
    
    # Send X-Ray subsegment
    .send_subsegment(
      name = operation_name,
      start_time = start_time,
      end_time = end_time,
      context = context,
      annotations = list(
        duration_ms = (end_time - start_time) * 1000,
        success = TRUE
      )
    )
    
    return(result)
    
  }, error = function(e) {
    end_time <- as.numeric(Sys.time())
    
    # Send error subsegment
    .send_subsegment(
      name = operation_name,
      start_time = start_time,
      end_time = end_time,
      context = context,
      annotations = list(
        duration_ms = (end_time - start_time) * 1000,
        success = FALSE
      ),
      error = e$message
    )
    
    stop(e)
  })
}

# Enhanced metrics function (still simple for users)
send_inference_metrics <- function(inference_id, start_time, end_time, success = TRUE, 
                                   error_message = NULL, operation_timings = NULL) {
  duration <- as.numeric(end_time - start_time)
  
  # Log structured metrics for CloudWatch Insights
  base_log <- list(
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"),
    inference_id = inference_id,
    duration = duration,
    success = tolower(as.character(success)),
    endpoint = "xray-rocker-model-async-endpoint"
  )
  
  if (!is.null(operation_timings)) {
    base_log$operation_timings <- operation_timings
  }
  
  cat(toJSON(base_log, auto_unbox = TRUE), "\n")
  
  if (!is.null(error_message)) {
    error_log <- list(
      error = error_message,
      inference_id = inference_id,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    )
    cat(toJSON(error_log, auto_unbox = TRUE), "\n")
  }
}

# Business logic (pure functions - no tracing embedded) ----

preprocess_data <- function(payload) {
  cat("Starting data preprocessing...\n")
  Sys.sleep(0.05)  # Simulate processing time
  
  if (is.null(payload$input)) {
    stop("Missing required 'input' field in payload")
  }
  
  list(
    processed_input = toupper(as.character(payload$input)),
    preprocessing_timestamp = Sys.time()
  )
}

run_inference <- function(processed_data) {
  cat("Running model inference...\n")
  Sys.sleep(0.15)  # Simulate model execution time
  
  list(
    prediction = paste("PROCESSED:", processed_data$processed_input),
    confidence = runif(1, 0.8, 0.99),
    model_version = "v1.2.3"
  )
}

postprocess_results <- function(inference_result) {
  cat("Post-processing results...\n")
  Sys.sleep(0.03)  # Simulate post-processing time
  
  list(
    final_result = inference_result$prediction,
    confidence_score = round(inference_result$confidence, 3),
    model_metadata = inference_result$model_version,
    postprocessed_at = Sys.time()
  )
}

#* @post /invocations
#* @serializer unboxedJSON
function(req, res) {
  start_time <- Sys.time()
  inference_id <- sprintf("inf-%s", format(start_time, "%Y%m%d-%H%M%S-%f"))
  
  # Create X-Ray context for this request (thread-safe)
  xray_context <- list(
    enabled = TRUE,
    trace_header = paste0("Root=1-", toupper(as.hexmode(as.integer(start_time))), "-", rand_hex(24)),
    parent_segment_id = rand_hex(16),
    start_time = as.numeric(start_time)
  )
  
  cat("Starting inference with subsegments:", inference_id, "\n")
  
  payload <- fromJSON(req$postBody)
  
  tryCatch({
    # Users wrap their function calls with trace_operation() - clean and simple!
    processed_data <- trace_operation({
      preprocess_data(payload)
    }, operation_name = "data-preprocessing")
    
    inference_result <- trace_operation({
      run_inference(processed_data)
    }, operation_name = "model-inference")
    
    final_result <- trace_operation({
      postprocess_results(inference_result)
    }, operation_name = "post-processing")
    
    end_time <- Sys.time()
    
    # Send the complete main segment
    .send_main_segment(xray_context, end_time, success = TRUE)
    
    # Send metrics 
    send_inference_metrics(
      inference_id = inference_id,
      start_time = start_time,
      end_time = end_time,
      success = TRUE
    )
    
    return(list(
      message = "Inference completed with metrics and subsegments!",
      result = final_result,
      timestamp = format(Sys.time(), tz="UTC", usetz=TRUE),
      inference_id = inference_id,
      timing_breakdown = list(
        total_duration_ms = as.numeric(end_time - start_time) * 1000
      ),
      tracing_enabled = xray_context$enabled
    ))
    
  }, error = function(e) {
    end_time <- Sys.time()
    
    # Send the complete main segment with error
    .send_main_segment(xray_context, end_time, success = FALSE, error_message = e$message)
    
    # Send error metrics
    send_inference_metrics(
      inference_id = inference_id,
      start_time = start_time,
      end_time = end_time,
      success = FALSE,
      error_message = e$message
    )
    
    res$status <- 500
    return(list(
      error = "Internal server error",
      message = e$message,
      inference_id = inference_id,
      timestamp = format(Sys.time(), tz="UTC", usetz=TRUE)
    ))
  })
}

# Helper to send main segment
.send_main_segment <- function(context, end_time, success = TRUE, error_message = NULL) {
  if (!context$enabled) return()
  
  annotations <- list(
    service = "r-plumber-metrics",
    success = success,
    duration_ms = (as.numeric(end_time) - context$start_time) * 1000
  )
  
  seg <- list(
    name = "inference-request",
    id = context$parent_segment_id,
    trace_id = extract_root(context$trace_header),
    start_time = context$start_time,
    end_time = as.numeric(end_time),
    annotations = annotations
  )
  
  if (!is.null(error_message)) {
    seg$error <- TRUE
    seg$cause <- list(exceptions = list(list(message = error_message, type = "InferenceError")))
  }
  
  payload <- toJSON(seg, auto_unbox = TRUE)
  tryCatch({
    header <- '{"format": "json", "version": 1}'
    full_payload <- paste0(header, "\n", payload)
    cmd <- sprintf("printf %s | nc -u -w1 127.0.0.1 2000", shQuote(full_payload))
    system(cmd, ignore.stdout = TRUE, ignore.stderr = TRUE)
  }, error = function(e) {
    # Silently handle X-Ray failures
  })
} 