# Static source model: parses `R/*.R` and `_targets.R` (never runs them) into
# reviewable items with stable hashes. A hash covers the parse tokens of an item
# without comments and whitespace, so formatting changes do not invalidate a review.

TARGET_CALLS <- c(
  "tar_target", "tar_render", "tar_quarto", "tar_combine", "tar_file",
  "tar_file_read", "tar_force", "tar_change", "tar_age"
)

#' Read the reviewable items of a targets project from its source files
#'
#' Parses `R/*.R` and `_targets.R` without running them and returns one item
#' per function, target, `tar_map()`, other top-level object and factory source
#' file (the `.Rmd`/`.qmd` of `tar_render()`/`tar_quarto()`).
#'
#' @param path Root folder of the targets project.
#' @return A list with `items` (a data frame, one row per item, with the
#'   columns `id`, `kind`, `name`, `file`, `line1`, `line2`, `hash`, `block`,
#'   `map`, `fn`, `calls`, `title`) and `files`, the parsed source files.
#' @noRd
read_source <- function(path = ".") {
  r_files <- sort(list.files(file.path(path, "R"), pattern = "\\.[Rr]$"))
  files <- file.path("R", r_files)
  if (file.exists(file.path(path, "_targets.R"))) files <- c(files, "_targets.R")
  read_lines <- function(f) {
    full <- file.path(path, f)
    if (file.exists(full) && !dir.exists(full)) readLines(full, warn = FALSE, encoding = "UTF-8")
  }
  texts <- stats::setNames(lapply(files, read_lines), files)
  build_source(texts, read_lines)
}

# Same as `read_source()`, but from a named list `file -> lines`, so old
# versions (e.g. from git) can be hashed without touching disk. Factory source
# files get a `file` item only when their text is in `texts`.
read_source_text <- function(texts) {
  build_source(texts, function(f) texts[[f]])
}

build_source <- function(texts, read_extra) {
  files <- names(texts)
  is_code <- function(f) f == "_targets.R" || grepl("^R/", f)
  parsed <- lapply(files, function(f) parse_source_file(f, texts[[f]], is_r = grepl("^R/", f)))
  recs <- unlist(parsed, recursive = FALSE)

  fn_recs <- Filter(function(r) r$kind == "function", recs)
  fn_names <- vapply(fn_recs, `[[`, character(1), "name")
  dup <- fn_names[duplicated(fn_names)]
  if (length(dup)) {
    where <- vapply(fn_recs[fn_names == dup[1]], `[[`, character(1), "file")
    stop("Function `", dup[1], "` is defined more than once: ", paste(where, collapse = ", "), call. = FALSE)
  }

  # Which targets does a top-level assignment hold (for map templates)?
  holders <- list()
  for (r in recs) {
    if (r$kind == "target" && !is.na(r$holder)) holders[[r$holder]] <- c(holders[[r$holder]], r$name)
  }

  map_of <- character()
  map_where <- character()
  for (i in seq_along(recs)) {
    r <- recs[[i]]
    if (r$kind != "map") next
    templates <- unique(c(r$nested, unlist(holders[r$symbols], use.names = FALSE)))
    where <- paste0(r$file, ":", r$line1)
    if (!length(templates)) {
      stop("tar_map() at ", where, " has no templates pipeworks can resolve", call. = FALSE)
    }
    id <- paste0("map:", paste(templates, collapse = "+"))
    if (id %in% names(map_where)) {
      stop("tar_map() at ", where, " has the same templates as the tar_map() at ", map_where[[id]], call. = FALSE)
    }
    map_where[[id]] <- where
    recs[[i]]$name <- paste(templates, collapse = "+")
    recs[[i]]$id <- id
    for (t in templates) if (is.na(map_of[t])) map_of[t] <- id
  }

  for (i in seq_along(recs)) {
    r <- recs[[i]]
    if (r$kind == "function") {
      recs[[i]]$calls <- setdiff(intersect(r$names, fn_names), r$name)
    } else if (r$kind == "target") {
      hit <- intersect(r$names, fn_names)
      recs[[i]]$fn <- if (length(hit)) hit[1] else NA_character_
      recs[[i]]$map <- if (r$name %in% names(map_of)) map_of[[r$name]] else NA_character_
    }
  }

  for (path in unique(unlist(lapply(recs, `[[`, "source_path")))) {
    lines <- read_extra(path)
    if (is.null(lines)) next
    recs[[length(recs) + 1L]] <- source_record(
      "file", path, path, 1L, max(length(lines), 1L), md5_text(paste0(paste(lines, collapse = "\n"), "\n"))
    )
  }

  list(items = items_frame(recs), files = files[vapply(files, is_code, logical(1))])
}

source_record <- function(kind, name, file, line1, line2, hash, ...) {
  rec <- list(
    id = paste0(kind, ":", name), kind = kind, name = name, file = file,
    line1 = as.integer(line1), line2 = as.integer(line2), hash = hash,
    map = NA_character_, fn = NA_character_, calls = character(), title = NA_character_,
    holder = NA_character_, names = character(), nested = character(),
    symbols = character(), source_path = character()
  )
  extra <- list(...)
  rec[names(extra)] <- extra
  rec
}

items_frame <- function(recs) {
  col <- function(field, type) vapply(recs, function(r) r[[field]], type)
  items <- data.frame(
    id = col("id", character(1)), kind = col("kind", character(1)),
    name = col("name", character(1)), file = col("file", character(1)),
    line1 = col("line1", integer(1)), line2 = col("line2", integer(1)),
    hash = col("hash", character(1)), block = col("file", character(1)),
    map = col("map", character(1)), fn = col("fn", character(1)),
    stringsAsFactors = FALSE
  )
  items$calls <- lapply(recs, `[[`, "calls")
  items$title <- col("title", character(1))
  items
}

parse_source_file <- function(file, lines, is_r) {
  exprs <- tryCatch(
    parse(text = lines, keep.source = TRUE),
    error = function(e) stop("Cannot parse ", file, ": ", conditionMessage(e), call. = FALSE)
  )
  pd <- utils::getParseData(exprs, includeText = NA)
  if (is.null(pd)) return(list())
  kids <- split(pd$id, pd$parent)
  tops <- pd[pd$parent == 0 & pd$token == "expr", ]
  tops <- tops[order(tops$line1, tops$col1), ]

  node_hash <- function(id) {
    ids <- parse_descendants(kids, id)
    rows <- pd[match(ids, pd$id), ]
    rows <- rows[rows$terminal & rows$token != "COMMENT", ]
    rows <- rows[order(rows$line1, rows$col1), ]
    long <- rows$token == "STR_CONST" & grepl("^\\[\\d+ chars quoted", rows$text)
    for (i in which(long)) rows$text[i] <- utils::getParseText(pd, rows$id[i])
    md5_text(paste(rows$text, collapse = " "))
  }

  recs <- list()
  seen <- integer()
  for (i in seq_len(nrow(tops))) {
    top <- tops[i, ]
    e <- exprs[[i]]
    holder <- assignment_name(e)

    if (is_r && is_function_assignment(e)) {
      recs[[length(recs) + 1L]] <- source_record(
        "function", holder, file, top$line1, top$line2, node_hash(top$id),
        title = roxygen_title(lines, top$line1), names = unique(all.names(e[[3]]))
      )
      next
    }

    ids <- parse_descendants(kids, top$id)
    callee <- pd[pd$id %in% ids & pd$token == "SYMBOL_FUNCTION_CALL" &
                   pd$text %in% c(TARGET_CALLS, "tar_map"), ]
    callee <- callee[order(callee$line1, callee$col1), ]
    if (!nrow(callee)) {
      head <- if (!is.na(holder)) holder else top_call_name(e)
      if (is.na(holder)) {
        seen[head] <- if (is.na(seen[head])) 1L else seen[[head]] + 1L
        oname <- paste0(head, "#", seen[[head]])
      } else {
        oname <- holder
      }
      recs[[length(recs) + 1L]] <- source_record(
        "object", oname, file, top$line1, top$line2, node_hash(top$id),
        id = paste0("object:", file, ":", oname)
      )
      next
    }

    calls <- lapply(seq_len(nrow(callee)), function(j) {
      id <- pd$parent[pd$id == pd$parent[pd$id == callee$id[j]]]
      cl <- pd[pd$id == id, ]
      list(id = id, fn = callee$text[j], row = cl, call = str2lang(utils::getParseText(pd, id)))
    })
    maps <- Filter(function(x) x$fn == "tar_map", calls)
    targets <- Filter(function(x) x$fn != "tar_map", calls)

    for (x in targets) {
      m <- match_call_args(x$call, if (x$fn %in% c("tar_render", "tar_quarto")) c("name", "path") else c("name", "command"))
      tname <- arg_name(m$name)
      if (is.na(tname)) next
      cmd_names <- if (!is.null(m$command)) unique(all.names(m$command)) else character()
      desc <- match_call_args(x$call, "description")$description
      recs[[length(recs) + 1L]] <- source_record(
        "target", tname, file, x$row$line1, x$row$line2, node_hash(x$id),
        title = if (is.character(desc) && length(desc) == 1) desc else NA_character_,
        holder = holder, names = cmd_names,
        source_path = if (is.character(m$path) && length(m$path) == 1) m$path else character()
      )
    }
    for (x in maps) {
      inside <- parse_descendants(kids, x$id)
      nested <- character()
      for (y in targets) {
        if (!y$id %in% inside) next
        tname <- arg_name(match_call_args(y$call, c("name", "command"))$name)
        if (!is.na(tname)) nested <- c(nested, tname)
      }
      args <- as.list(x$call)[-1]
      unnamed <- if (is.null(names(args))) rep(TRUE, length(args)) else !nzchar(names(args))
      symbols <- vapply(args[unnamed][vapply(args[unnamed], is.name, logical(1))], as.character, character(1))
      recs[[length(recs) + 1L]] <- source_record(
        "map", "", file, x$row$line1, x$row$line2, node_hash(x$id),
        nested = nested, symbols = unname(symbols)
      )
    }
  }
  recs
}

parse_descendants <- function(kids, id) {
  out <- id
  queue <- id
  while (length(queue)) {
    queue <- unlist(kids[as.character(queue)], use.names = FALSE)
    out <- c(out, queue)
  }
  out
}

assignment_name <- function(e) {
  if (is.call(e) && length(e) == 3 && as.character(e[[1]])[1] %in% c("<-", "=", "<<-") &&
      (is.name(e[[2]]) || is.character(e[[2]]))) {
    as.character(e[[2]])
  } else {
    NA_character_
  }
}

top_call_name <- function(e) {
  if (!is.call(e)) return("expr")
  head <- e[[1]]
  if (is.call(head) && as.character(head[[1]])[1] %in% c("::", ":::")) head <- head[[3]]
  if (is.name(head) || is.character(head)) as.character(head) else "call"
}

# Match call arguments to formal names the way R does (exact names first, then
# position); arguments beyond the formals are dropped.
match_call_args <- function(call, formals) {
  args <- as.list(call)[-1]
  nms <- names(args)
  if (is.null(nms)) nms <- rep("", length(args))
  out <- args[nms %in% formals]
  names(out) <- nms[nms %in% formals]
  free <- setdiff(formals, names(out))
  positional <- args[!nzchar(nms)]
  for (i in seq_len(min(length(free), length(positional)))) out[free[i]] <- positional[i]
  out
}

arg_name <- function(x) {
  if (is.name(x) || (is.character(x) && length(x) == 1)) as.character(x) else NA_character_
}

# First paragraph of the roxygen block directly above `line` (without tags).
roxygen_title <- function(lines, line) {
  i <- line - 1L
  block <- character()
  while (i >= 1L && grepl("^\\s*#'", lines[i])) {
    block <- c(sub("^\\s*#'\\s?", "", lines[i]), block)
    i <- i - 1L
  }
  stop_at <- which(grepl("^\\s*@", block))
  if (length(stop_at)) block <- block[seq_len(stop_at[1] - 1L)]
  block <- block[cumsum(nzchar(trimws(block))) > 0]
  blank <- which(!nzchar(trimws(block)))
  if (length(blank)) block <- block[seq_len(blank[1] - 1L)]
  if (length(block)) paste(trimws(block), collapse = " ") else NA_character_
}

md5_text <- function(text) {
  f <- tempfile()
  on.exit(unlink(f))
  writeBin(charToRaw(enc2utf8(text)), f)
  unname(tools::md5sum(f))
}
