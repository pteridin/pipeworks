# HTTP side of the live server: request checks and the JSON API.
#
#   GET  /              editor page (`?token=` required), model + `live`
#   GET  /api/version   {version}
#   GET  /api/model     model + `live` + `model_error`
#   POST /api/verdict   {item, verdict, comment} -> record_verdict()
#   POST /api/retry     retry_uncommitted()
#   POST /api/open      {item} -> open its file at its line
#   POST /api/edit      {changes} -> apply_changes(); 200 {ok, write_id, version,
#                       files, notes}; 400 {error} (bad change, no changes);
#                       409 {error, item, file} (stale base)
#   POST /api/undo      {write_id} -> undo_changes(); 200 {ok, version, files};
#                       404 unknown id; 409 {error} when a file changed since
#
# Every request must name an allowed host (127.0.0.1:<port>, localhost:<port>,
# the RStudio Server address, `pipeworks.allowed_origins`); API calls carry
# the token in `X-Pipeworks-Token`; POSTs with a foreign `Origin` are refused.
# Served pages use relative addresses only (`api/...`, `?token=`), so they
# also work below a proxy path.

pw_routes <- c(
  "/api/version" = "GET", "/api/model" = "GET",
  "/api/verdict" = "POST", "/api/retry" = "POST", "/api/open" = "POST",
  "/api/edit" = "POST", "/api/undo" = "POST"
)

# The httpuv app of `state`. Tests call `$call(req)` with fake requests.
pw_app <- function(state) {
  list(call = function(req) {
    tryCatch(pw_handle(state, req), error = function(e) pw_json(list(error = conditionMessage(e)), 500L))
  })
}

pw_handle <- function(state, req) {
  method <- req$REQUEST_METHOD %||% ""
  route <- req$PATH_INFO %||% "/"
  allowed <- pw_allowed(state)
  host <- req$HTTP_HOST
  origin <- req$HTTP_ORIGIN
  if (!isTRUE((host %||% "") %in% allowed$hosts)) return(pw_forbidden("host", host, origin))
  if (method == "POST" && !is.null(origin) && !origin %in% allowed$origins) {
    return(pw_forbidden("origin", host, origin))
  }

  if (route %in% c("/", "/index.html")) {
    if (method != "GET") return(pw_text("Method not allowed.", 405L))
    if (!identical(pw_query(req$QUERY_STRING)[["token"]], state$token)) return(pw_html(pw_locked_page, 403L))
    return(pw_html(editor_page(model_json(pw_payload(state)))))
  }

  if (!identical(req$HTTP_X_PIPEWORKS_TOKEN, state$token)) return(pw_json(list(error = "Missing or wrong token."), 403L))
  if (!route %in% names(pw_routes)) return(pw_json(list(error = "Not found."), 404L))
  if (method != pw_routes[[route]]) return(pw_json(list(error = "Method not allowed."), 405L))
  body <- if (method == "POST") tryCatch(pw_body(req), error = function(e) e) else list()
  if (inherits(body, "error")) return(pw_json(list(error = "The request body is not valid JSON."), 400L))

  switch(route,
    "/api/version" = pw_json(list(version = state$version)),
    "/api/model" = pw_json(pw_payload(state)),
    "/api/verdict" = pw_api_verdict(state, body),
    "/api/retry" = pw_api_retry(state),
    "/api/open" = pw_api_open(state, body),
    "/api/edit" = pw_api_edit(state, body),
    "/api/undo" = pw_api_undo(state, body)
  )
}

pw_api_verdict <- function(state, body) {
  if (!is_string(body$item) || !is_string(body$verdict) || !(is.null(body$comment) || is_string(body$comment))) {
    return(pw_json(list(error = "Send `item` and `verdict` (strings) and optionally `comment`."), 400L))
  }
  if (!body$verdict %in% c("correct", "questionable", "wrong")) {
    return(pw_json(list(error = "`verdict` must be one of \"correct\", \"questionable\", \"wrong\"."), 400L))
  }
  res <- tryCatch(record_verdict(state$path, body$item, body$verdict, body$comment), error = function(e) e)
  if (inherits(res, "error")) return(pw_json(list(error = conditionMessage(res)), 409L))
  pw_refresh_after_write(state)
  pw_json(list(
    ok = TRUE,
    committed = res$committed,
    commit = res$commit,
    error = res$error,
    entry = res$entry,
    file = review_rel(state$path, res$file),
    version = state$version
  ))
}

pw_api_retry <- function(state) {
  res <- tryCatch(retry_uncommitted(state$path), error = function(e) e)
  if (inherits(res, "error")) return(pw_json(list(error = conditionMessage(res)), 409L))
  pw_refresh_after_write(state)
  results <- lapply(seq_len(nrow(res)), function(i) list(
    file = review_rel(state$path, res$file[i]), committed = res$committed[i], error = res$error[i]
  ))
  pw_json(list(ok = all(res$committed), results = results, version = state$version))
}

pw_api_open <- function(state, body) {
  if (!is_string(body$item)) return(pw_json(list(error = "Send `item` (a string)."), 400L))
  items <- state$items
  row <- if (is.null(items)) integer() else which(items$id == body$item)
  if (!length(row)) return(pw_json(list(error = paste0("Unknown item: ", body$item)), 404L))
  row <- row[1]
  res <- state$open_file(file.path(state$path, items$file[row]), items$line1[row])
  if (is.list(res) && isFALSE(res$ok)) return(pw_json(list(ok = FALSE, error = res$error %||% "Cannot open the file.")))
  pw_json(list(ok = TRUE))
}

pw_api_edit <- function(state, body) {
  changes <- body$changes
  if (!is.list(changes) || !length(changes) || !all(vapply(changes, is.list, logical(1)))) {
    return(pw_json(list(error = "Send `changes` (a non-empty list of change objects)."), 400L))
  }
  pw_save_buffers()
  res <- tryCatch(apply_changes(state$path, unname(changes)), error = function(e) e)
  if (inherits(res, "pipeworks_stale")) {
    return(pw_json(list(error = conditionMessage(res), item = res$item, file = res$file), 409L))
  }
  if (inherits(res, "pipeworks_bad_change")) return(pw_json(list(error = conditionMessage(res)), 400L))
  if (inherits(res, "error")) return(pw_json(list(error = conditionMessage(res)), 500L))
  id <- pw_remember_write(state, res$undo)
  pw_refresh_after_code_write(state)
  pw_json(list(
    ok = TRUE, write_id = id, version = state$version,
    files = I(as.character(unlist(res$files))), notes = I(as.character(unlist(res$notes)))
  ))
}

pw_api_undo <- function(state, body) {
  if (!is_string(body$write_id)) return(pw_json(list(error = "Send `write_id` (a string)."), 400L))
  id <- body$write_id
  if (!exists(id, envir = state$writes, inherits = FALSE)) {
    return(pw_json(list(error = paste0("Unknown write: ", id)), 404L))
  }
  pw_save_buffers()
  res <- tryCatch(undo_changes(state$path, get(id, envir = state$writes)), error = function(e) e)
  if (inherits(res, "pipeworks_stale")) {
    return(pw_json(list(error = conditionMessage(res), item = res$item, file = res$file), 409L))
  }
  if (inherits(res, "error")) return(pw_json(list(error = conditionMessage(res)), 409L))
  rm(list = id, envir = state$writes)
  pw_refresh_after_code_write(state)
  pw_json(list(ok = TRUE, version = state$version, files = I(as.character(res))))
}

# Keep the undo record of a write under a new id ("w1", "w2", ...); the
# oldest beyond 100 are dropped.
pw_remember_write <- function(state, undo) {
  state$write_seq <- state$write_seq + 1L
  id <- paste0("w", state$write_seq)
  assign(id, undo, envir = state$writes)
  old <- state$write_seq - 100L
  if (old >= 1L && exists(paste0("w", old), envir = state$writes, inherits = FALSE)) {
    rm(list = paste0("w", old), envir = state$writes)
  }
  id
}

# Unsaved RStudio buffers would be overwritten or lost: save them first.
pw_save_buffers <- function() {
  if (rstudio_available()) try(rstudioapi::documentSaveAll(), silent = TRUE)
  invisible()
}

# A code write changed the sources: refresh the review status now, start the
# structure rebuild and take the code group into the fingerprint so the
# watcher does not start a second one. The page sees the new version at once.
pw_refresh_after_code_write <- function(state) {
  pw_refresh_qa(state)
  pw_start_bg(state)
  state$fingerprint$code <- pw_fingerprint(state)$code
  state$version <- state$version + 1L
  invisible(state)
}

# A verdict or retry changed `qa/` and the git refs: refresh now and take
# those groups into the fingerprint, so the watcher does not refresh again.
# The code group stays as it was, so code changes are never swallowed.
pw_refresh_after_write <- function(state) {
  pw_refresh_qa(state)
  now <- pw_fingerprint(state)
  state$fingerprint$qa <- now$qa
  state$fingerprint$git <- now$git
  invisible(state)
}

# ---- Helpers ---------------------------------------------------------------

is_string <- function(x) is.character(x) && length(x) == 1L && !is.na(x)

pw_query <- function(qs) {
  qs <- sub("^\\?", "", qs %||% "")
  parts <- strsplit(qs, "&", fixed = TRUE)[[1]]
  kv <- strsplit(parts, "=", fixed = TRUE)
  vals <- vapply(kv, function(x) if (length(x) > 1) httpuv::decodeURIComponent(x[2]) else "", character(1))
  as.list(stats::setNames(vals, vapply(kv, function(x) x[1] %||% "", character(1))))
}

pw_body <- function(req) {
  input <- req$rook.input
  bytes <- if (is.null(input)) raw() else input$read()
  if (!length(bytes)) return(list())
  text <- rawToChar(bytes)
  Encoding(text) <- "UTF-8"
  body <- jsonlite::fromJSON(text, simplifyVector = FALSE)
  if (!is.list(body)) stop("not an object")
  body
}

pw_headers <- function(type) {
  list(
    "Content-Type" = type,
    "Cache-Control" = "no-store",
    "X-Content-Type-Options" = "nosniff",
    "Referrer-Policy" = "no-referrer"
  )
}

pw_json <- function(x, status = 200L) {
  body <- jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
  list(status = status, headers = pw_headers("application/json; charset=utf-8"), body = as.character(body))
}

pw_text <- function(text, status) list(status = status, headers = pw_headers("text/plain; charset=utf-8"), body = text)

pw_html <- function(html, status = 200L) list(status = status, headers = pw_headers("text/html; charset=utf-8"), body = html)

# Shown for `/` without a valid token. After a reload the address bar has no
# token any more (the editor removes it); the editor keeps it in
# sessionStorage under "pipeworks-token" and this page puts it back once.
pw_locked_page <- paste0(
  '<!doctype html><meta charset="utf-8"><title>pipeworks</title>',
  '<p>This pipeworks page needs its access token. Run <code>pipeworks()</code> in R again.</p>',
  '<script>try{var t=sessionStorage.getItem("pipeworks-token");',
  'if(t&&location.search.indexOf("token=")<0)location.replace("?token="+encodeURIComponent(t));}catch(e){}</script>'
)
