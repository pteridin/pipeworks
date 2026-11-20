#' Open the pipeline in the pipeworks editor
#'
#' Reads the targets project in `path` and shows it in the RStudio Viewer
#' pane, or in the browser outside RStudio. The console stays free.
#'
#' This version shows a snapshot: run `pipeworks()` again after editing your
#' files to refresh it. Edits made in the editor are not written back yet.
#'
#' @param path Root folder of the targets project, containing `_targets.R`.
#' @param viewer Whether to use the RStudio Viewer pane when available.
#' @return The `pipeworks_model`, invisibly.
#' @export
#' @examples
#' \dontrun{
#' pipeworks(example_project())
#' }
pipeworks <- function(path = ".", viewer = getOption("pipeworks.viewer", TRUE)) {
  model <- read_pipeline(path)
  file <- pipeworks_html(model, file.path(tempfile("pipeworks-"), "index.html"))
  if (viewer && requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    rstudioapi::viewer(file)
  } else {
    utils::browseURL(file)
  }
  invisible(model)
}

#' Write the editor as a standalone HTML file
#'
#' @param model A `pipeworks_model` from [read_pipeline()].
#' @param file Path of the HTML file to write. Its folder is created if needed.
#' @return `file`, invisibly.
#' @export
pipeworks_html <- function(model, file) {
  template <- system.file("app", "index.html", package = "pipeworks", mustWork = TRUE)
  html <- paste(readLines(template, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  placeholder <- '<script id="pipeworks-data" type="application/json">null</script>'
  if (!grepl(placeholder, html, fixed = TRUE)) stop("The editor template has no data placeholder.", call. = FALSE)
  data <- sprintf('<script id="pipeworks-data" type="application/json">%s</script>', model_json(model))
  html <- sub(placeholder, data, html, fixed = TRUE)
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  writeLines(html, file, useBytes = TRUE)
  invisible(file)
}

#' Convert a pipeworks model to JSON
#'
#' @param model A `pipeworks_model` from [read_pipeline()].
#' @return A JSON string that is safe to embed in an HTML `<script>` tag.
#' @export
model_json <- function(model) {
  json <- jsonlite::toJSON(unclass(model), auto_unbox = TRUE, null = "null", na = "null", pretty = FALSE)
  # Keep "</script>" inside strings from closing the tag.
  gsub("</", "<\\/", json, fixed = TRUE)
}

#' Copy the example survey project
#'
#' Copies the small targets project that ships with pipeworks, so you can try
#' the editor without touching your own pipeline.
#'
#' @param dest Folder to copy the project into. It must not exist yet.
#' @return The path of the copied project, invisibly.
#' @export
example_project <- function(dest = file.path(tempdir(), "survey")) {
  src <- system.file("examples", "survey", package = "pipeworks", mustWork = TRUE)
  if (dir.exists(dest)) stop(dest, " already exists.", call. = FALSE)
  dir.create(dest, recursive = TRUE)
  files <- list.files(src, recursive = TRUE, all.files = TRUE, no.. = TRUE)
  files <- files[!grepl("^(_targets/|\\.Rproj\\.user/)|^report\\.html$", files)]
  for (f in files) {
    dir.create(file.path(dest, dirname(f)), recursive = TRUE, showWarnings = FALSE)
    file.copy(file.path(src, f), file.path(dest, f))
  }
  invisible(normalizePath(dest))
}
