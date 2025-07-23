library(plumber)
library(jsonlite)

# Helper functions (internal) ----
`%||%` <- function(x, y) {
  if (!is.null(x)) x else y
}

rand_hex <- function(n) {
  paste0(sample(c(0:9, letters[1:6]), n, replace = TRUE), collapse = "")
}

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

# Internal segment sender (thread-safe)
.send_xray_segment <- function(name, start_time, end_time, parent_id = NULL, 
                               trace_id = NULL, annotations = list(), 
                               error = NULL, metadata = list(), segment_id = NULL) {
  
  if (is.null(trace_id)) return(NULL)  # Must have trace_id to send segments
  
  seg <- list(
    name = name,
    id = if (!is.null(segment_id)) segment_id else rand_hex(16),
    trace_id = trace_id,  # Use the provided trace_id directly
    start_time = start_time,
    end_time = end_time,
    annotations = annotations
  )
  
  if (!is.null(parent_id)) {
    seg$parent_id <- parent_id
    seg$type <- "subsegment"
  }
  
  if (!is.null(error)) {
    seg$error <- TRUE
    seg$cause <- list(
      exceptions = list(
        list(message = error, type = "InferenceError")
      )
    )
  }
  
  if (length(metadata) > 0) {
    seg$metadata <- metadata
  }

  payload <- toJSON(seg, auto_unbox = TRUE)
  
  cat("Sending X-Ray", if (!is.null(parent_id)) "subsegment:" else "segment:", 
      name, "with trace_id:", trace_id, "\n")

  tryCatch({
    header <- '{"format": "json", "version": 1}'
    full_payload <- paste0(header, "\n", payload)
    cmd <- sprintf("printf %s | nc -u -w1 127.0.0.1 2000", shQuote(full_payload))
    system(cmd, ignore.stdout = TRUE, ignore.stderr = TRUE)
  }, error = function(e) {
    cat("Warning: X-Ray segment send failed:", e$message, "\n")
  })
  
  return(seg$id)
}

# Initialize X-Ray context from request (thread-safe - returns context object)
.init_xray_context <- function(req) {
  context <- list(
    trace_header = NULL,
    trace_id = NULL,
    parent_segment_id = NULL,
    enabled = FALSE,
    start_time = as.numeric(Sys.time())
  )
  
  # Try to get trace header from standard location
  incoming <- req$HTTP_X_AMZN_TRACE_ID
  
  # If not found, try SageMaker custom attributes
  if (is.null(incoming) && !is.null(req$HTTP_X_AMZN_SAGEMAKER_CUSTOM_ATTRIBUTES)) {
    custom_attrs <- req$HTTP_X_AMZN_SAGEMAKER_CUSTOM_ATTRIBUTES
    if (grepl("X-Amzn-Trace-Id=", custom_attrs)) {
      trace_parts <- strsplit(custom_attrs, "X-Amzn-Trace-Id=")[[1]]
      if (length(trace_parts) >= 2) {
        trace_candidate <- gsub("^\\s+|\\s+$|,$", "", trace_parts[2])
        if (nchar(trace_candidate) > 0) {
          incoming <- trace_candidate
        }
      }
    }
  }
  
  # Debug output
  cat("=== X-Ray Debug ===\n")
  cat("Incoming trace header:", if (is.null(incoming)) "NULL" else incoming, "\n")
  
  # Set up context if we have a trace header
  if (!is.null(incoming) && incoming != "") {
    context$trace_header <- incoming
    context$trace_id <- extract_root(incoming)
    context$enabled <- TRUE
    
    # Debug output
    cat("Extracted trace ID:", if (is.null(context$trace_id)) "NULL" else context$trace_id, "\n")
    
    # Create main segment ID (but don't send segment yet - will send when complete)
    context$parent_segment_id <- rand_hex(16)
    cat("Generated parent segment ID:", context$parent_segment_id, "\n")
  } else {
    cat("No valid trace header found, X-Ray disabled\n")
  }
  cat("==================\n")
  
  return(context)
}

# Finalize X-Ray context (thread-safe - uses context object)
.finalize_xray_context <- function(context, success = TRUE, error_message = NULL) {
  if (context$enabled && !is.null(context$parent_segment_id)) {
    end_time <- as.numeric(Sys.time())
    
    annotations <- list(
      service = "r-plumber",
      success = success,
      duration_ms = (end_time - context$start_time) * 1000
    )
    
    cat("Finalizing main segment with trace_id:", context$trace_id, "\n")
    
    # Now send the complete main segment
    .send_xray_segment(
      name = "inference-request",
      start_time = context$start_time,
      end_time = end_time,
      parent_id = NULL,  # This is the root segment
      trace_id = context$trace_id,  # Use stored trace_id
      annotations = annotations,
      error = error_message,
      segment_id = context$parent_segment_id  # Use the pre-generated ID
    )
  }
}

# PUBLIC API: Simple tracing function for users (thread-safe) ----

#' Trace an operation with X-Ray subsegments
#' 
#' @param expr R expression to execute and trace
#' @param operation_name Name for the operation (will appear in X-Ray console)
#' @return Result of the expression
#' @examples
#' result <- trace_operation({
#'   Sys.sleep(0.1)
#'   "Hello World"
#' }, operation_name = "my-operation")
trace_operation <- function(expr, operation_name = "operation") {
  # Look for xray_context in the calling environment (thread-safe)
  context <- tryCatch({
    get("xray_context", envir = parent.frame())
  }, error = function(e) {
    list(enabled = FALSE, trace_id = NULL, parent_segment_id = NULL)
  })
  
  if (!context$enabled || is.null(context$trace_id)) {
    # No tracing context - just execute and return
    return(eval.parent(substitute(expr)))
  }
  
  start_time <- as.numeric(Sys.time())
  
  # Execute the expression and handle errors
  tryCatch({
    result <- eval.parent(substitute(expr))
    end_time <- as.numeric(Sys.time())
    
    cat("Creating subsegment:", operation_name, "with parent:", context$parent_segment_id, "\n")
    
    # Send successful subsegment
    .send_xray_segment(
      name = operation_name,
      start_time = start_time,
      end_time = end_time,
      parent_id = context$parent_segment_id,
      trace_id = context$trace_id,  # Use stored trace_id
      annotations = list(
        duration_ms = (end_time - start_time) * 1000,
        success = TRUE
      )
    )
    
    return(result)
    
  }, error = function(e) {
    end_time <- as.numeric(Sys.time())
    
    # Send error subsegment
    .send_xray_segment(
      name = operation_name,
      start_time = start_time,
      end_time = end_time,
      parent_id = context$parent_segment_id,
      trace_id = context$trace_id,  # Use stored trace_id
      annotations = list(
        duration_ms = (end_time - start_time) * 1000,
        success = FALSE
      ),
      error = e$message
    )
    
    # Re-throw the error
    stop(e)
  })
}

# Business logic examples (pure functions - no tracing embedded) ----

preprocess_data <- function(payload) {
  cat("Preprocessing data...\n")
  Sys.sleep(0.1)  # Simulate work
  
  if (is.null(payload$input)) {
    stop("Missing required 'input' field")
  }
  
  list(
    processed_input = toupper(as.character(payload$input)),
    timestamp = Sys.time()
  )
}

run_inference <- function(processed_data) {
  cat("Running model inference...\n")
  Sys.sleep(0.2)  # Simulate model execution
  
  list(
    prediction = paste("PROCESSED:", processed_data$processed_input),
    confidence = runif(1, 0.8, 0.99),
    model_version = "v1.2.3"
  )
}

postprocess_results <- function(inference_result) {
  cat("Post-processing results...\n")
  Sys.sleep(0.05)  # Simulate post-processing
  
  list(
    final_result = inference_result$prediction,
    confidence_score = round(inference_result$confidence, 3),
    model_metadata = inference_result$model_version,
    postprocessed_at = Sys.time()
  )
}

# Routes ----

#* @get /ping
function() {
  list(status = "ok")
}

#* @post /invocations
#* @serializer unboxedJSON
function(req, res) {
  # Initialize X-Ray context (thread-safe - each request gets its own context)
  xray_context <- .init_xray_context(req)
  
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
    
    # Finalize tracing
    .finalize_xray_context(xray_context, success = TRUE)
    
    return(list(
      message = "Inference completed successfully!",
      result = final_result,
      timestamp = format(Sys.time(), tz = "UTC", usetz = TRUE),
      tracing_enabled = xray_context$enabled
    ))
    
  }, error = function(e) {
    # Finalize tracing with error
    .finalize_xray_context(xray_context, success = FALSE, error_message = e$message)
    
    res$status <- 500
    return(list(
      error = "Internal server error",
      message = e$message,
      timestamp = format(Sys.time(), tz = "UTC", usetz = TRUE)
    ))
  })
}

#* @post /test-simple
#* @serializer unboxedJSON
function(req, res) {
  # No X-Ray setup needed
  payload <- fromJSON(req$postBody)
  
  # Create trace context for testing
  xray_context <- list(
    enabled = TRUE,
    trace_header = paste0("Root=1-", toupper(as.hexmode(as.integer(Sys.time()))), "-", rand_hex(24)),
    parent_segment_id = rand_hex(16)
  )
  
  # Simple business logic with automatic tracing - just wrap function calls
  result1 <- trace_operation({
    cat("Step 1: Validating input\n")
    Sys.sleep(0.05)
    if (is.null(payload$input)) stop("No input provided")
    paste("Validated:", payload$input)
  }, operation_name = "validation")
  
  result2 <- trace_operation({
    cat("Step 2: Processing\n") 
    Sys.sleep(0.1)
    toupper(result1)
  }, operation_name = "processing")
  
  result3 <- trace_operation({
    cat("Step 3: Finalizing\n")
    Sys.sleep(1)
    paste("FINAL:", result2)
  }, operation_name = "finalization")
  
  return(list(
    message = "Simple tracing example completed!",
    result = result3,
    timestamp = format(Sys.time(), tz = "UTC", usetz = TRUE)
  ))
}
