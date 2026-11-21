# Who may talk to the live server and how it reaches the user: the token,
# the allowed hosts and origins (local, RStudio Server, the
# `pipeworks.allowed_origins` option), showing the page and opening files.

# 32 hex digits. Sources, best first: /dev/urandom, `openssl::rand_bytes()`
# (Windows, when installed), else an MD5 over several weak sources
# (`pw_token_mixed()`). Never touches the user's RNG stream.
pw_token <- function() {
  bytes <- raw()
  if (file.exists("/dev/urandom")) {
    bytes <- tryCatch({
      con <- file("/dev/urandom", "rb", raw = TRUE)
      on.exit(close(con))
      readBin(con, "raw", 16L)
    }, error = function(e) raw())
  }
  if (length(bytes) < 16L && requireNamespace("openssl", quietly = TRUE)) {
    bytes <- tryCatch(as.raw(openssl::rand_bytes(16L)), error = function(e) raw())
  }
  if (length(bytes) < 16L) return(pw_token_mixed())
  paste(format(as.hexmode(as.integer(bytes)), width = 2), collapse = "")
}

# Fallback token: MD5 of the time in microseconds, the process time and id, a
# fresh temp file name and numbers drawn after re-seeding from the clock (in
# a preserved-seed block, so the user's `set.seed()` neither predicts it nor
# is disturbed).
pw_token_mixed <- function() {
  drawn <- withr::with_preserve_seed({
    set.seed(NULL)
    sample.int(.Machine$integer.max, 8L)
  })
  text <- paste(
    format(Sys.time(), "%Y-%m-%d %H:%M:%OS6"), paste(proc.time(), collapse = ","),
    Sys.getpid(), tempfile("pw"), paste(drawn, collapse = ","), sep = "|"
  )
  file <- tempfile("pw-token-")
  on.exit(unlink(file), add = TRUE)
  writeLines(text, file)
  unname(tools::md5sum(file))
}

# `scheme://host[:port]` of a URL.
pw_origin_of <- function(url) regmatches(url, regexpr("^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]+", url))

# Allow `origins` (and their hosts) on top of what `state` already allows.
pw_allow <- function(state, origins) {
  origins <- unique(origins[nzchar(origins)])
  state$origins <- unique(c(state$origins, origins))
  state$hosts <- unique(c(state$hosts, sub("^[^:]+://", "", origins)))
  invisible(state)
}

# The local addresses of the server's port.
pw_allow_local <- function(state) {
  local <- paste0(c("127.0.0.1:", "localhost:"), state$port)
  state$hosts <- unique(c(local, state$hosts))
  state$origins <- unique(c(paste0("http://", local), state$origins))
  invisible(state)
}

# Allowed hosts and origins of a request: the state's plus the option
# `pipeworks.allowed_origins` (read per request, so setting it needs no
# restart).
pw_allowed <- function(state) {
  extra <- as.character(getOption("pipeworks.allowed_origins", character()))
  extra <- extra[nzchar(extra)]
  list(
    hosts = unique(c(state$hosts, sub("^[^:]+://", "", extra))),
    origins = unique(c(state$origins, extra))
  )
}

pw_forbidden <- function(what, host, origin) {
  pw_text(paste0(
    "Forbidden ", what, ". pipeworks received Host: ", host %||% "(none)",
    ", Origin: ", origin %||% "(none)", ".\n",
    "If this is the address you opened pipeworks under (e.g. RStudio Server), allow it in R with\n",
    "  options(pipeworks.allowed_origins = \"", origin %||% "https://your.server", "\")\n",
    "and reload the page."
  ), 403L)
}

# The address RStudio Server or Workbench gives the local URL, else NULL.
pw_rstudio_server_url <- function(url) {
  if (!requireNamespace("rstudioapi", quietly = TRUE) || !rstudioapi::isAvailable()) return(NULL)
  mode <- tryCatch(rstudioapi::versionInfo()$mode, error = function(e) NULL)
  if (!identical(mode, "server")) return(NULL)
  tryCatch(rstudioapi::translateLocalUrl(url, absolute = TRUE), error = function(e) NULL)
}

# Viewer pane in RStudio (it translates local URLs itself), else the browser.
show_url <- function(url, viewer) {
  if (isTRUE(viewer) && requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    rstudioapi::viewer(url)
  } else {
    utils::browseURL(url)
  }
}

# Open `file` at `line`: RStudio, else `file.edit()` only in an interactive
# GUI session (elsewhere it would start a terminal editor). Returns
# `list(ok, error)`.
open_in_editor <- function(file, line) {
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    rstudioapi::navigateToFile(file, line = line)
    return(list(ok = TRUE))
  }
  if (interactive() && .Platform$GUI %in% c("AQUA", "Rgui", "RStudio")) {
    utils::file.edit(file)
    return(list(ok = TRUE))
  }
  list(ok = FALSE, error = sprintf("No editor can be opened from this R session; open %s:%d yourself.", file, as.integer(line)))
}
