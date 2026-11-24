// Raw libcurl declarations for src/stream.zig.
//
// The `curl` package wraps the common options; the stream needs a few it does
// not expose (`CURLOPT_TIMEOUT` set to "infinite", the write callback and the
// error buffer on a handle it owns). build.zig translates this file into the
// `curl_c` module.
#include <curl/curl.h>
#include <stdlib.h> // getenv, for the opt-in stream tracing
