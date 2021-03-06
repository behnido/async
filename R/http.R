
## TODO: methods
## TODO: headers
## TODO: options
## TODO: can we save to file?

#' Asynchronous HTTP GET request
#'
#' Start an HTTP GET request in the background, and report its completion
#' via a deferred.
#'
#' @param url URL to connect to.
#' @param headers HTTP headers to send.
#' @param file If not `NULL`, it must be a string, specifying a file.
#'   The body of the response is written to this file.
#' @param options Options to set on the handle. Passed to
#'   [curl::handle_setopt()].
#' @param on_progress Progress handler function. It is only used if the
#'   response body is written to a file.
#' @return Deferred object.
#'
#' @family asyncronous HTTP calls
#' @export
#' @importFrom curl new_handle handle_setheaders
#' @examples
#' afun <- async(function() {
#'   http_get("https://eu.httpbin.org/status/200")$
#'     then(~ .$status_code)
#' })
#' synchronise(afun())

http_get <- function(url, headers = character(), file = NULL,
                     options = list(timeout = 600), on_progress = NULL) {
  assert_that(is_string(url))
  handle <- new_handle(url = url)
  handle_setheaders(handle, .list = headers)
  handle_setopt(handle, .list = options)
  make_deferred_http(handle, file, on_progress)
}

#' Asynchronous HTTP HEAD request
#'
#' @inheritParams http_get
#' @return Deferred object.
#'
#' @family asyncronous HTTP calls
#' @export
#' @importFrom curl handle_setopt
#' @examples
#' afun <- async(function() {
#'   dx <- http_head("https://eu.httpbin.org/status/200")$
#'     then(~ .$status_code)
#' })
#' synchronise(afun())
#'
#' # Check a list of URLs in parallel
#' afun <- async(function(urls) {
#'   when_all(.list = lapply(urls, http_head))$
#'     then(~ lapply(., "[[", "status_code"))
#' })
#' urls <- c("https://r-project.org", "https://eu.httpbin.org")
#' synchronise(afun(urls))

http_head <- function(url, headers = character(), file = NULL,
                      options = list(timeout = 600), on_progress = NULL) {
  assert_that(is_string(url))
  handle <- new_handle(url = url)
  handle_setheaders(handle, .list = headers)
  handle_setopt(handle, customrequest = "HEAD", nobody = TRUE,
                .list = options)
  make_deferred_http(handle, file, on_progress)
}

#' @importFrom curl multi_cancel

make_deferred_http <- function(handle, file, on_progress) {
  handle; file; on_progress
  deferred$new(
    function(resolve, reject, progress) {
      force(resolve)
      force(reject)
      get_default_event_loop()$add_http(
        handle,
        function(err, res) if (is.null(err)) resolve(res) else reject(err),
        progress,
        file,
        deferred = environment(resolve)$self
      )
    },
    on_progress = on_progress,
    on_cancel = function(reason) multi_cancel(handle)
  )
}

#' Throw R errors for HTTP errors
#'
#' Status codes below 400 are considered successful, others will trigger
#' errors. Note that this is different from the `httr` package, which
#' considers the 3xx status code errors as well.
#'
#' @param resp HTTP response from [http_get()], [http_head()], etc.
#' @return The HTTP response invisibly, if it is considered successful.
#'   Otherwise an error is thrown.
#'
#' @export
#' @examples
#' afun <- async(function() {
#'   http_get("https://eu.httpbin.org/status/404")$
#'     then(http_stop_for_status)
#' })
#'
#' tryCatch(synchronise(afun()), error = function(e) e)

http_stop_for_status <- function(resp) {
  if (!is.integer(resp$status_code)) stop("Not an HTTP response")
  if (resp$status_code < 400) return(invisible(resp))
  stop(http_error(resp))
}

http_error <- function(resp, call = sys.call(-1)) {
  status <- resp$status_code
  reason <- http_status(status)$reason
  message <- sprintf("%s (HTTP %d).", reason, status)
  status_type <- (status %/% 100) * 100
  http_class <- paste0("http_", unique(c(status, status_type, "error")))
  structure(
    list(message = message, call = call),
    class = c(http_class, "error", "condition")
  )
}

http_status <- function(status) {
  status_desc <- http_statuses[[as.character(status)]]
  if (is.na(status_desc)) {
    stop("Unknown http status code: ", status, call. = FALSE)
  }

  status_types <- c("Information", "Success", "Redirection", "Client error",
    "Server error")
  status_type <- status_types[[status %/% 100]]

  # create the final information message
  message <- paste(status_type, ": (", status, ") ", status_desc, sep = "")

  list(
    category = status_type,
    reason = status_desc,
    message = message
  )
}

http_statuses <- c(
  "100" = "Continue",
  "101" = "Switching Protocols",
  "102" = "Processing (WebDAV; RFC 2518)",
  "200" = "OK",
  "201" = "Created",
  "202" = "Accepted",
  "203" = "Non-Authoritative Information",
  "204" = "No Content",
  "205" = "Reset Content",
  "206" = "Partial Content",
  "207" = "Multi-Status (WebDAV; RFC 4918)",
  "208" = "Already Reported (WebDAV; RFC 5842)",
  "226" = "IM Used (RFC 3229)",
  "300" = "Multiple Choices",
  "301" = "Moved Permanently",
  "302" = "Found",
  "303" = "See Other",
  "304" = "Not Modified",
  "305" = "Use Proxy",
  "306" = "Switch Proxy",
  "307" = "Temporary Redirect",
  "308" = "Permanent Redirect (experimental Internet-Draft)",
  "400" = "Bad Request",
  "401" = "Unauthorized",
  "402" = "Payment Required",
  "403" = "Forbidden",
  "404" = "Not Found",
  "405" = "Method Not Allowed",
  "406" = "Not Acceptable",
  "407" = "Proxy Authentication Required",
  "408" = "Request Timeout",
  "409" = "Conflict",
  "410" = "Gone",
  "411" = "Length Required",
  "412" = "Precondition Failed",
  "413" = "Request Entity Too Large",
  "414" = "Request-URI Too Long",
  "415" = "Unsupported Media Type",
  "416" = "Requested Range Not Satisfiable",
  "417" = "Expectation Failed",
  "418" = "I'm a teapot (RFC 2324)",
  "420" = "Enhance Your Calm (Twitter)",
  "422" = "Unprocessable Entity (WebDAV; RFC 4918)",
  "423" = "Locked (WebDAV; RFC 4918)",
  "424" = "Failed Dependency (WebDAV; RFC 4918)",
  "424" = "Method Failure (WebDAV)",
  "425" = "Unordered Collection (Internet draft)",
  "426" = "Upgrade Required (RFC 2817)",
  "428" = "Precondition Required (RFC 6585)",
  "429" = "Too Many Requests (RFC 6585)",
  "431" = "Request Header Fields Too Large (RFC 6585)",
  "444" = "No Response (Nginx)",
  "449" = "Retry With (Microsoft)",
  "450" = "Blocked by Windows Parental Controls (Microsoft)",
  "451" = "Unavailable For Legal Reasons (Internet draft)",
  "499" = "Client Closed Request (Nginx)",
  "500" = "Internal Server Error",
  "501" = "Not Implemented",
  "502" = "Bad Gateway",
  "503" = "Service Unavailable",
  "504" = "Gateway Timeout",
  "505" = "HTTP Version Not Supported",
  "506" = "Variant Also Negotiates (RFC 2295)",
  "507" = "Insufficient Storage (WebDAV; RFC 4918)",
  "508" = "Loop Detected (WebDAV; RFC 5842)",
  "509" = "Bandwidth Limit Exceeded (Apache bw/limited extension)",
  "510" = "Not Extended (RFC 2774)",
  "511" = "Network Authentication Required (RFC 6585)",
  "598" = "Network read timeout error (Unknown)",
  "599" = "Network connect timeout error (Unknown)"
)
