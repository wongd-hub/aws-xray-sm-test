library(plumber)
library(jsonlite)
library(httr)

# Functions ----

# Nullish coalescer infix operator: returns left if not NULL, else right
`%||%` <- function(x, y) {
  if (!is.null(x)) x else y
}

rand_hex <- function(n) {
  paste0(sample(c(0:9, letters[1:6]), n, replace=TRUE), collapse="")
}

extract_root <- function(trace_header) {
  m <- regmatches(trace_header, regexec("Root=([^;]+)", trace_header))[[1]]
  if (length(m)>1) m[2] else NULL
}

# Build & send a segment to the local daemon
send_xray_segment <- function(
  name,
  trace_header = NULL,      # propagate from incoming header or leave NULL to start a new trace
  parent_id    = NULL,      # if creating a subsegment
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

  # # serialize to compact JSON
  # payload <- toJSON(seg, auto_unbox=TRUE)

  # wrap in the PutTraceSegments API format
  body <- list( TraceSegmentDocuments = list(toJSON(seg, auto_unbox=TRUE)) )

  # send over UDP to X-Ray daemon
  # cmd <- sprintf("printf %s | nc -u -w1 127.0.0.1 2000", shQuote(payload))
  # system(cmd, ignore.stdout=TRUE, ignore.stderr=TRUE)
  # POST to the local daemon’s HTTP proxy
  resp <- POST(
    url    = "http://127.0.0.1:2000/TraceSegments",
    body   = body,
    encode = "json",
    timeout(1)
  )
  if (http_error(resp)) {
    warning("X-Ray daemon HTTP error: ", status_code(resp))
  }

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

  # grab incoming trace header if present
  incoming <- req$HTTP_X_AMZN_TRACE_ID
  # start a new segment/subsegment
  send_xray_segment("my-inference", trace_header = incoming, annotations = list(job="async-123"))

  # …your real inference logic here…
  list(
    message   = "Hello from R!",
    input     = payload,
    timestamp = format(Sys.time(), tz="UTC", usetz=TRUE)
  )
}
