#' Read a targets project into the pipeworks model
#'
#' Combines what targets knows about the pipeline ([targets::tar_manifest()],
#' [targets::tar_network()] and the build status) with the roxygen
#' documentation of the project's functions ([read_functions()]).
#'
#' This runs `_targets.R` in a separate R process, the same way
#' [targets::tar_manifest()] does. Nothing is built.
#'
#' @param path Root folder of the targets project, containing `_targets.R`.
#' @param status Whether to read the build status. Set to `FALSE` to skip the
#'   call to [targets::tar_outdated()], which can be slow for large pipelines.
#' @return A `pipeworks_model`: a list with `project`, `targets`, `functions`,
#'   `edges`, `families` and `files`.
#' @family readers
#' @export
#' @examples
#' \dontrun{
#' model <- read_pipeline(example_project())
#' model
#' }
read_pipeline <- function(path = ".", status = TRUE) {
  path <- normalizePath(path, mustWork = TRUE)
  if (!file.exists(file.path(path, "_targets.R"))) {
    stop("No _targets.R found in ", path, call. = FALSE)
  }
  withr::local_dir(path)

  fns <- read_functions(".")
  manifest <- targets::tar_manifest(fields = c("name", "command", "pattern", "description", "format"))
  network <- targets::tar_network(targets_only = FALSE, outdated = FALSE)
  target_names <- manifest$name
  states <- if (status) read_status(target_names) else stats::setNames(rep("unknown", length(target_names)), target_names)

  types <- stats::setNames(network$vertices$type, network$vertices$name)
  edges <- network$edges
  target_edges <- edges[edges$from %in% target_names & edges$to %in% target_names, , drop = FALSE]
  fn_edges <- edges[edges$from %in% names(fns) & edges$to %in% target_names, , drop = FALSE]

  targets <- lapply(seq_len(nrow(manifest)), function(i) {
    row <- manifest[i, ]
    call <- target_call(row$command, fns, target_names)
    list(
      name = row$name,
      type = unname(types[row$name]),
      command = row$command,
      pattern = na_to_null(row$pattern),
      description = na_to_null(row$description),
      format = row$format %||% "rds",
      status = unname(states[row$name]),
      mode = call$mode,
      fn = na_to_null(call$fn),
      args = call$args,
      factory = call$factory,
      source = na_to_null(call$source),
      deps = target_edges$from[target_edges$to == row$name]
    )
  })
  names(targets) <- target_names

  for (name in names(fns)) {
    fns[[name]]$used_by <- unique(fn_edges$to[fn_edges$from == name])
  }

  model <- list(
    project = basename(path),
    root = path,
    read_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    targets = unname(targets),
    functions = unname(lapply(fns, function(f) f[names(f) != ".expr"])),
    edges = lapply(seq_len(nrow(target_edges)), function(i) list(from = target_edges$from[i], to = target_edges$to[i])),
    families = unique(stats::na.omit(vapply(fns, function(f) f$family, character(1)))),
    files = read_source_files(targets)
  )
  structure(model, class = "pipeworks_model")
}

read_status <- function(target_names) {
  states <- stats::setNames(rep("new", length(target_names)), target_names)
  if (!dir.exists(targets::tar_config_get("store"))) return(states)
  progress <- tryCatch(targets::tar_progress(), error = function(e) NULL)
  if (!is.null(progress)) {
    known <- progress[progress$name %in% target_names, ]
    states[known$name] <- ifelse(known$progress == "errored", "errored", "uptodate")
  }
  outdated <- tryCatch(targets::tar_outdated(), error = function(e) character())
  outdated <- intersect(outdated, target_names)
  states[outdated] <- ifelse(states[outdated] == "errored", "errored", ifelse(states[outdated] == "new", "new", "outdated"))
  states
}

read_source_files <- function(targets) {
  paths <- c("_targets.R", sort(list.files("R", pattern = "\\.[Rr]$", full.names = TRUE)))
  sources <- unlist(lapply(targets, function(t) t$source))
  paths <- unique(c(paths, sources[file.exists(sources)]))
  lapply(paths, function(p) list(path = p, text = paste(readLines(p, warn = FALSE, encoding = "UTF-8"), collapse = "\n")))
}

na_to_null <- function(x) if (is.null(x) || length(x) == 0 || is.na(x)) NULL else x

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) y else x

#' @export
print.pipeworks_model <- function(x, ...) {
  modes <- table(vapply(x$targets, `[[`, character(1), "mode"))
  cat("<pipeworks_model> ", x$project, "\n", sep = "")
  cat("  ", length(x$targets), " targets (", paste(names(modes), modes, sep = ": ", collapse = ", "), ")\n", sep = "")
  cat("  ", length(x$edges), " dependencies\n", sep = "")
  cat("  ", length(x$functions), " functions in ", length(unique(vapply(x$functions, `[[`, character(1), "file"))), " files\n", sep = "")
  cat("  families: ", if (length(x$families)) paste(x$families, collapse = ", ") else "none", "\n", sep = "")
  invisible(x)
}
