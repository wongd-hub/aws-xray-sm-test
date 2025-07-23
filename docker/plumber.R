library(plumber)
library(jsonlite)

# Functions ----

# Nullish coalescer infix operator: returns left if not NULL, else right
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
  m <- regmatches(trace_header, regexec("Root=([^;]+)", trace_header))[[1]]
  if (length(m) > 1) m[2] else NULL
}

# Build & send a segment to the local daemon
send_xray_segment <- function(
  name,
  # propagate from incoming header or leave NULL to start a new trace
  trace_header = NULL,
  # if creating a subsegment
  parent_id    = NULL,
  annotations  = list()
) {

  now <- as.numeric(Sys.time())
  trace_id <- extract_root(trace_header)
  seg <- list(
    name        = name,
    id          = rand_hex(16),
    trace_id    = if (!is.null(trace_id)) trace_id else paste0(
      "1-",
      toupper(as.hexmode(as.integer(now))), "-",
      rand_hex(24)
    ),
    start_time  = now,
    end_time    = now,
    annotations = annotations
  )
  if (!is.null(parent_id)) seg$parent_id <- parent_id

  # serialize to compact JSON
  payload <- toJSON(seg, auto_unbox = TRUE)

  # send over UDP to X-Ray daemon using netcat with proper format
  tryCatch({
    cat("Sending X-Ray segment:", substr(payload, 1, 100), "...\n")

    # X-Ray daemon expects UDP segments with format: 
    # {"format": "json", "version": 1}\n{segment_json}
    header <- '{"format": "json", "version": 1}'
    full_payload <- paste0(header, "\n", payload)

    cmd <- sprintf(
      "printf %s | nc -u -w1 127.0.0.1 2000", 
      shQuote(full_payload)
    )
    result <- system(cmd, ignore.stdout = FALSE, ignore.stderr = FALSE)
    cat("X-Ray segment sent successfully (exit code:", result, ")\n")
  }, error = function(e) {
    cat("Warning: Could not send X-Ray segment:", e$message, "\n")
  })

}



# Routes ----

# Health check
#* @get /ping
function() {
  list(status="ok")
}

# Inference entrypoint
#* @post /invocations
#* @serializer unboxedJSON
function(req, res) {
  payload <- fromJSON(req$postBody)

  # Log all headers to debug X-Ray tracing
  cat("=== DEBUG: All request headers ===\n")
  headers <- names(req)
  for (h in headers[grepl("HTTP_", headers)]) {
    cat(sprintf("%s: %s\n", h, req[[h]]))
  }
  cat("===================================\n")

  # grab incoming trace header from standard location or custom attributes
  incoming <- req$HTTP_X_AMZN_TRACE_ID

  # If not in standard header, check custom attributes (SageMaker async pattern)
  if (
    is.null(incoming) &&
      !is.null(req$HTTP_X_AMZN_SAGEMAKER_CUSTOM_ATTRIBUTES)
  ) {
    custom_attrs <- req$HTTP_X_AMZN_SAGEMAKER_CUSTOM_ATTRIBUTES
    cat("Custom attributes:", custom_attrs, "\n")
    cat("Custom attributes class:", class(custom_attrs), "\n")
    cat("Custom attributes length:", length(custom_attrs), "\n")

    # Extract trace ID from custom attributes: "X-Amzn-Trace-Id=1-xxxxx-xxxx"
    cat("Checking if contains X-Amzn-Trace-Id...\n")
    contains_trace <- grepl("X-Amzn-Trace-Id=", custom_attrs)
    cat("Contains trace ID:", contains_trace, "\n")

    if (contains_trace) {
      cat("Attempting to split on 'X-Amzn-Trace-Id='...\n")
      trace_parts <- strsplit(custom_attrs, "X-Amzn-Trace-Id=")[[1]]
      cat("Split result:", paste(trace_parts, collapse = " | "), "\n")
      cat("Number of parts:", length(trace_parts), "\n")

      if (length(trace_parts) >= 2) {
        # Take everything after "X-Amzn-Trace-Id=" and remove
        #  any trailing whitespace/commas
        trace_candidate <- trace_parts[2]
        cat("Raw trace candidate:", trace_candidate, "\n")
        # trim whitespace and trailing comma
        trace_candidate <- gsub("^\\s+|\\s+$|,$", "", trace_candidate)
        cat("Cleaned trace candidate:", trace_candidate, "\n")
        cat("Trace candidate length:", nchar(trace_candidate), "\n")

        if (nchar(trace_candidate) > 0) {
          incoming <- trace_candidate
          cat(
            "SUCCESS: Extracted trace ID from custom attributes:",
            incoming,
            "\n"
          )
        } else {
          cat("ERROR: Trace candidate is empty after cleaning\n")
        }
      } else {
        cat("ERROR: Not enough parts after split\n")
      }
    } else {
      cat("ERROR: Custom attributes do not contain 'X-Amzn-Trace-Id='\n")
    }
  } else {
    if (is.null(req$HTTP_X_AMZN_SAGEMAKER_CUSTOM_ATTRIBUTES)) {
      cat("No custom attributes found in request\n")
    } else {
      cat("Standard X-Ray header already found, skipping custom attributes\n")
    }
  }

  cat("X-Ray trace header:", if (is.null(incoming)) "NULL" else incoming, "\n")

  # Only send X-Ray segment if we have a valid trace context from SageMaker
  if (!is.null(incoming) && incoming != "") {
    cat("Sending X-Ray segment with trace context\n")
    send_xray_segment(
      "my-inference",
      trace_header = incoming,
      annotations  = list(job = "async-123")
    )
  } else {
    cat("No X-Ray trace header from SageMaker - skipping segment\n")
  }

  # …your real inference logic here…
  list(
    message   = "Hello from R!",
    input     = payload,
    timestamp = format(Sys.time(), tz = "UTC", usetz = TRUE),
    xray_debug = list(
      trace_header = incoming,
      headers_count = length(headers[grepl("HTTP_", headers)])
    )
  )
}
