#' Open the pipeline in the pipeworks editor
#'
#' Reads the targets project in `path`, starts a small web server inside the
#' R session and shows the editor from it in the RStudio Viewer pane, or in
#' the browser outside RStudio. The console stays free.
#'
#' The page stays connected to R: it refreshes by itself when files in `R/`,
#' `_targets.R`, the report sources, `qa/` or the git branch change (the
#' review status at once, the pipeline structure in a background process),
#' records verdicts like [qa_review()] (each one committed on its own), and
#' opens items in RStudio. Edits of the pipeline made in the editor are not
#' written back yet.
#'
#' The server listens on `127.0.0.1` only and answers only requests that carry
#' its random token. There is one server per project: calling `pipeworks()`
#' again reuses it (open tabs keep working) and shows the editor again. It
#' stops with [pipeworks_stop()] or when the R session ends.
#'
#' On RStudio Server and Posit Workbench the page is reached through the
#' server's proxy; that address is allowed automatically. If the page still
#' answers "Forbidden host" or "Forbidden origin" (it shows what it received),
#' allow the address with `options(pipeworks.allowed_origins =
#' "https://your.server")`.
#'
#' @param path Root folder of the targets project, containing `_targets.R`.
#' @param viewer Whether to use the RStudio Viewer pane when available.
#' @param mode `"review"` (structure read-only, verdict buttons), `"build"`
#'   (editing, no verdict buttons) or `"auto"`: Review when there are open
#'   items (not passing [qa_check()]) last changed by someone other than the
#'   current git user, else Build. The page can switch modes at any time.
#' @return The address of the editor (on RStudio Server the proxied one),
#'   invisibly.
#' @seealso [pipeworks_html()] for a static snapshot without a server.
#' @export
#' @examples
#' \dontrun{
#' path <- example_project(git = TRUE)
#' pipeworks(path)
#' pipeworks_stop(path)
#' }
pipeworks <- function(path = ".", viewer = getOption("pipeworks.viewer", TRUE), mode = c("auto", "review", "build")) {
  check_project(path)
  mode <- match.arg(mode)
  key <- normalizePath(path, mustWork = TRUE)
  state <- pw_servers[[key]]
  if (!is.null(state) && pw_running(state)) {
    new_mode <- resolve_mode(key, mode)
    if (!identical(new_mode, state$mode)) {
      state$mode <- new_mode
      state$version <- state$version + 1L
    }
  } else {
    if (!is.null(state)) pw_shutdown(state)
    state <- pw_start(key, mode)
    assign(key, state, envir = pw_servers)
  }
  # the Viewer translates local addresses itself; a browser needs the public one
  in_viewer <- isTRUE(viewer) && rstudio_available()
  url <- pw_public_url(state)
  show_url(if (in_viewer) pw_url(state) else url, viewer)
  invisible(url)
}

#' Stop the pipeworks server of a project
#'
#' Stops the server [pipeworks()] started for `path`. Open editor pages then
#' show that the connection to R is lost.
#'
#' @param path Root folder of the targets project.
#' @return `TRUE` if a server was stopped, `FALSE` if none was running,
#'   invisibly.
#' @export
pipeworks_stop <- function(path = ".") {
  key <- pw_find_server(path)
  if (is.na(key)) return(invisible(FALSE))
  state <- pw_servers[[key]]
  rm(list = key, envir = pw_servers)
  pw_shutdown(state)
  invisible(TRUE)
}

# The key in `servers` of the server for `path`: the normalised path, else the
# server whose stored real path equals the real path of `path` (or `path` as
# given, when the folder is gone); NA when there is none.
pw_find_server <- function(path, servers = pw_servers) {
  key <- normalizePath(path, mustWork = FALSE)
  if (exists(key, envir = servers, inherits = FALSE)) return(key)
  real <- tryCatch(normalizePath(path, mustWork = TRUE), error = function(e) sub("[/\\\\]+$", "", path))
  for (k in ls(servers, all.names = TRUE)) {
    if (identical(servers[[k]]$real_path, real)) return(k)
  }
  NA_character_
}

#' Write the editor as a standalone HTML file
#'
#' @param model A `pipeworks_model` from [read_pipeline()].
#' @param file Path of the HTML file to write. Its folder is created if needed.
#' @return `file`, invisibly.
#' @export
pipeworks_html <- function(model, file) {
  html <- editor_page(model_json(model))
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  writeLines(html, file, useBytes = TRUE)
  invisible(file)
}

# The editor template with `json` (from `model_json()`) embedded.
editor_page <- function(json) {
  template <- system.file("app", "index.html", package = "pipeworks", mustWork = TRUE)
  html <- paste(readLines(template, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  placeholder <- '<script id="pipeworks-data" type="application/json">null</script>'
  if (!grepl(placeholder, html, fixed = TRUE)) stop("The editor template has no data placeholder.", call. = FALSE)
  data <- sprintf('<script id="pipeworks-data" type="application/json">%s</script>', json)
  sub(placeholder, data, html, fixed = TRUE)
}

#' Convert a pipeworks model to JSON
#'
#' @param model A `pipeworks_model` from [read_pipeline()].
#' @return A JSON string that is safe to embed in an HTML `<script>` tag.
#' @export
model_json <- function(model) {
  json <- jsonlite::toJSON(unclass(model), auto_unbox = TRUE, null = "null", na = "null", pretty = FALSE)
  # "<" only occurs inside strings; escaping all of them keeps "</script>" and
  # "<!--" from breaking the page.
  gsub("<", "\\u003c", json, fixed = TRUE)
}
