% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/http.R
\name{http_get}
\alias{http_get}
\title{Asynchronous HTTP GET request}
\usage{
http_get(url, headers = character(), file = NULL, options = list(timeout =
  600), on_progress = NULL)
}
\arguments{
\item{url}{URL to connect to.}

\item{headers}{HTTP headers to send.}

\item{file}{If not \code{NULL}, it must be a string, specifying a file.
The body of the response is written to this file.}

\item{options}{Options to set on the handle. Passed to
\code{\link[curl:handle_setopt]{curl::handle_setopt()}}.}

\item{on_progress}{Progress handler function. It is only used if the
response body is written to a file.}
}
\value{
Deferred object.
}
\description{
Start an HTTP GET request in the background, and report its completion
via a deferred.
}
\examples{
afun <- async(function() {
  http_get("https://eu.httpbin.org/status/200")$
    then(~ .$status_code)
})
synchronise(afun())
}
\seealso{
Other asyncronous HTTP calls: \code{\link{http_head}}
}
\concept{asyncronous HTTP calls}
