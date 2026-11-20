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
#' Each target also carries its `block` (the file it is written in, from the
#' static source model) and, for `tar_map()` variants, its `map` (`id`,
#' `template`, `variant`); `maps` lists the maps with their templates,
#' variants and a colour index. In a git repository with commits every target
#' and function gets its review status (`qa`, see [qa_status()]; a factory
#' target also `qa_file`, the status of its report source) and the model a
#' `qa_summary` (`total`, `done` = items passing [qa_check()], `open`, `wrong`,
#' `check_again` and `outside`, the items without a box on the canvas);
#' outside git both are `NULL`. The git history is not read: the last author
#' shown comes from the review entries.
#'
#' @return A `pipeworks_model`: a list with `project`, `targets`, `functions`,
#'   `edges`, `blocks`, `maps`, `qa_summary` and `files`.
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
  branches <- if (status) read_branches(target_names) else integer()
  src <- tryCatch(read_source("."), error = function(e) {
    warning("Cannot place targets in blocks: ", conditionMessage(e), call. = FALSE)
    NULL
  })
  items <- if (is.null(src)) NULL else src$items
  placed <- place_targets(target_names, items)
  maps <- map_records(items, placed)
  qa <- read_qa(".", items)

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
      deps = target_edges$from[target_edges$to == row$name],
      branches = if (!is.na(row$pattern) && row$name %in% names(branches)) branches[[row$name]] else NULL,
      block = placed$block[[i]],
      map = placed$map[[i]],
      qa = qa$item(target_item(row$name, placed$map[[i]])),
      # the report source of a factory target (`file:report.Rmd`) belongs to its box
      qa_file = if (length(call$source) && !is.na(call$source)) qa$item(paste0("file:", call$source))
    )
  })
  names(targets) <- target_names

  for (name in names(fns)) {
    fns[[name]]$used_by <- unique(fn_edges$to[fn_edges$from == name])
    fns[[name]]["qa"] <- list(qa$item(paste0("function:", name)))
  }
  for (i in seq_along(maps)) maps[[i]]["qa"] <- list(qa$item(maps[[i]]$id))
  blocks <- unique(stats::na.omit(unlist(placed$block)))
  blocks <- c(sort(blocks[grepl("^R/", blocks)]), blocks[!grepl("^R/", blocks)])

  # Review items without a box on the canvas: objects, rest items of blocks,
  # functions no target runs, report sources of no factory target.
  if (!is.null(qa$summary)) {
    boxed <- unique(c(
      vapply(targets, function(t) t$qa$item %||% NA_character_, character(1)),
      vapply(targets, function(t) t$qa_file$item %||% NA_character_, character(1)),
      paste0("function:", unlist(lapply(targets, `[[`, "fn"))),
      vapply(maps, `[[`, character(1), "id")
    ))
    qa$summary$outside <- qa$outside(boxed)
  }

  model <- list(
    project = basename(path),
    root = path,
    read_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    targets = unname(targets),
    functions = unname(lapply(fns, function(f) f[names(f) != ".expr"])),
    edges = lapply(seq_len(nrow(target_edges)), function(i) list(from = target_edges$from[i], to = target_edges$to[i])),
    blocks = blocks,
    maps = maps,
    qa_summary = qa$summary,
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

# Branch counts of dynamic targets that were built (named integer).
read_branches <- function(target_names) {
  if (!dir.exists(targets::tar_config_get("store"))) return(integer())
  pb <- tryCatch(targets::tar_progress_branches(), error = function(e) NULL)
  if (is.null(pb) || !nrow(pb) || !"branches" %in% names(pb)) return(integer())
  pb <- pb[pb$name %in% target_names, , drop = FALSE]
  stats::setNames(as.integer(pb$branches), pb$name)
}

# Match manifest names to the targets as written in the source: a plain
# target by name; a `tar_map()` variant to the template it comes from
# (`name == template` or `name` starts with `<template>_`, longest template
# first). Returns lists `block` and `map` (`NULL` where unknown / not mapped).
place_targets <- function(names, items) {
  n <- length(names)
  out <- list(block = vector("list", n), map = vector("list", n))
  if (is.null(items)) return(out)
  tg <- items[items$kind == "target", , drop = FALSE]
  mapped <- tg[!is.na(tg$map), , drop = FALSE]
  mapped <- mapped[order(-nchar(mapped$name)), , drop = FALSE]
  for (i in seq_len(n)) {
    name <- names[i]
    hit <- which(tg$name == name & is.na(tg$map))
    if (length(hit)) {
      out$block[[i]] <- tg$file[hit[1]]
      next
    }
    for (j in seq_len(nrow(mapped))) {
      t <- mapped$name[j]
      if (name == t || startsWith(name, paste0(t, "_"))) {
        out$block[[i]] <- mapped$file[j]
        variant <- if (name == t) "" else substring(name, nchar(t) + 2L)
        out$map[[i]] <- list(id = mapped$map[j], template = t, variant = variant)
        break
      }
    }
  }
  out
}

# One record per `tar_map()`: id, templates, variants seen in the manifest,
# the name of its first `values` column and a colour index 1..6.
map_records <- function(items, placed) {
  if (is.null(items)) return(list())
  mp <- items[items$kind == "map", , drop = FALSE]
  placed_maps <- Filter(Negate(is.null), placed$map)
  lapply(seq_len(nrow(mp)), function(k) {
    id <- mp$id[k]
    mine <- Filter(function(m) identical(m$id, id), placed_maps)
    variants <- unique(vapply(mine, `[[`, character(1), "variant"))
    list(
      id = id,
      templates = strsplit(mp$name[k], "+", fixed = TRUE)[[1]],
      variants = variants,
      param = map_param(mp$file[k], mp$line1[k]),
      file = mp$file[k],
      line = mp$line1[k],
      color_index = (k - 1L) %% 6L + 1L
    )
  })
}

# Name of the first column of `values` in the `tar_map()` call that starts on
# `line` of `file` (parsed, never run). `NULL` when it cannot be told statically.
map_param <- function(file, line) {
  exprs <- tryCatch(parse(file, keep.source = TRUE, encoding = "UTF-8"), error = function(e) NULL)
  pd <- if (is.null(exprs)) NULL else utils::getParseData(exprs, includeText = NA)
  if (is.null(pd)) return(NULL)
  sym <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text == "tar_map" & pd$line1 == line, , drop = FALSE]
  if (!nrow(sym)) return(NULL)
  id <- pd$parent[pd$id == pd$parent[pd$id == sym$id[1]]]
  call <- tryCatch(str2lang(utils::getParseText(pd, id)), error = function(e) NULL)
  if (is.null(call)) return(NULL)
  values <- match_call_args(call, "values")$values
  if (!is.call(values)) return(NULL)
  args <- as.list(values)[-1]
  nms <- names(args) %||% rep("", length(args))
  named <- nms[nzchar(nms)]
  if (length(named)) return(named[1])
  # tibble::tribble(~spec, ...)
  for (a in args) if (is.call(a) && identical(a[[1]], as.name("~")) && length(a) == 2) return(as.character(a[[2]]))
  NULL
}

target_item <- function(name, map) paste0("target:", if (is.null(map)) name else map$template)

# Review status per item id, only in a git repository with commits. Returns a
# list with `item(id)` (the status record or `NULL`) and `summary`.
read_qa <- function(path, items) {
  none <- list(item = function(id) NULL, summary = NULL)
  if (is.null(items) || is.na(git_head(path))) return(none)
  branch <- git_try(path, c("rev-parse", "--abbrev-ref", "HEAD"))
  branch <- if (length(branch)) branch[1] else NA_character_
  base <- NULL
  for (b in c("main", "master")) {
    if (!identical(branch, b) && !is.null(git_try(path, c("rev-parse", "--verify", "--quiet", paste0(b, "^{commit}"))))) {
      base <- b
      break
    }
  }
  # no git history walk: the last author shown comes from review entries only
  st <- tryCatch(qa_status(path, base = base, authors = FALSE), error = function(e) {
    warning("Cannot read the QA status: ", conditionMessage(e), call. = FALSE)
    NULL
  })
  if (is.null(st)) return(none)
  reviews <- read_reviews(path)
  hashes <- stats::setNames(st$hash, st$id)
  # source text now and at `base` of the items that changed against it (for the diff)
  changed <- if (is.null(base)) character() else st$id[st$changed_vs_base %in% TRUE]
  texts <- item_texts(read_source(path)$items, function(f) {
    full <- file.path(path, f)
    if (file.exists(full)) readLines(full, warn = FALSE, encoding = "UTF-8")
  }, changed)
  base_texts <- if (length(changed)) {
    tryCatch({
      bt <- git_tree_texts(path, base, st$file[st$kind == "file"])
      item_texts(read_source_text(bt)$items, function(f) bt[[f]], changed)
    }, error = function(e) list())
  } else list()
  str <- function(x) if (length(x) && !is.na(x)) x else NULL
  pass <- qa_passing(st)
  record <- function(i) {
    id <- st$id[i]
    hist <- reviews[reviews$item == id, , drop = FALSE]
    hist <- hist[rev(seq_len(nrow(hist))), , drop = FALSE]
    history <- lapply(seq_len(nrow(hist)), function(j) list(
      verdict = str(hist$verdict[j]), reviewer = str(hist$reviewer[j]), date = str(hist$date[j]),
      comment = str(hist$comment[j]), current = identical(hist$hash[j], hashes[[id]])
    ))
    list(
      item = id,
      status = st$status[i],
      verdict = if (length(history)) history[[1]]$verdict else NULL,
      reviewer = str(st$reviewer[i]),
      date = str(st$date[i]),
      comment = str(st$comment[i]),
      self_reviewed = isTRUE(st$self_reviewed[i]),
      authorship_unknown = is.na(st$self_reviewed[i]),
      passing = pass[i],
      last_author = str(st$last_author[i]),
      changed_vs_base = if (is.null(base)) NULL else isTRUE(st$changed_vs_base[i]),
      text = texts[[id]],
      base_text = base_texts[[id]],
      history = history
    )
  }
  recs <- stats::setNames(lapply(seq_len(nrow(st)), record), st$id)
  # done = passes qa_check(); check again passes and is only a hint
  done <- sum(pass)
  wrong <- sum(st$status == "wrong")
  outside <- function(boxed) {
    rows <- which(!st$id %in% boxed)
    lapply(rows, function(i) list(
      item = st$id[i], kind = st$kind[i], file = st$file[i], line1 = st$line1[i], line2 = st$line2[i],
      status = st$status[i], passing = pass[i]
    ))
  }
  list(
    item = function(id) recs[[id]],
    outside = outside,
    summary = list(
      total = nrow(st), done = done, open = nrow(st) - done - wrong, wrong = wrong,
      check_again = sum(pass & st$status == "check_again"),
      base = base, branch = if (is.na(branch)) NULL else branch
    )
  )
}

# Source lines (one string, "\n"-joined) of the items `ids`, by id.
item_texts <- function(items, lines_of, ids) {
  items <- items[items$id %in% ids, , drop = FALSE]
  out <- list()
  for (i in seq_len(nrow(items))) {
    lines <- lines_of(items$file[i])
    if (is.null(lines)) next
    out[[items$id[i]]] <- paste(lines[items$line1[i]:min(items$line2[i], length(lines))], collapse = "\n")
  }
  out
}

read_source_files <- function(targets) {
  r_files <- list.files("R", pattern = "\\.[Rr]$", recursive = TRUE, all.files = TRUE)
  paths <- c("_targets.R", file.path("R", sort(r_files, method = "radix")))
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
  cat("  blocks: ", if (length(x$blocks)) paste(x$blocks, collapse = ", ") else "none", "\n", sep = "")
  if (length(x$maps)) cat("  maps: ", paste(vapply(x$maps, `[[`, character(1), "id"), collapse = ", "), "\n", sep = "")
  if (!is.null(x$qa_summary)) {
    s <- x$qa_summary
    cat("  QA: ", s$done, " of ", s$total, " done, ", s$open, " open", if (s$wrong) paste0(", ", s$wrong, " wrong"),
        if (s$check_again) paste0(", ", s$check_again, " check again"), "\n", sep = "")
  }
  invisible(x)
}
