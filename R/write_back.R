# Write-back: turn one editor change into a chunk-level splice of in-memory
# file texts. `files` is a plain named list (rel path -> `read_text()` result)
# with attribute `root`; every `chg_*` returns a modified copy and never
# touches the disk. Static: no project code is evaluated.

wb_bad <- function(msg) {
  stop(structure(class = c("pipeworks_bad_change", "error", "condition"),
    list(message = msg, call = NULL)))
}

wb_files <- function(path) structure(list(), root = path)

wb_files_get <- function(files, rel) {
  if (!is.null(files[[rel]])) return(files[[rel]])
  read_text(file.path(attr(files, "root"), rel))
}

# R/**.R (like tar_source()) and _targets.R, on disk plus already loaded.
wb_rels <- function(files) {
  root <- attr(files, "root")
  on_disk <- list.files(file.path(root, "R"), pattern = "\\.[Rr]$", recursive = TRUE)
  rels <- c(if (length(on_disk)) file.path("R", on_disk),
    if (file.exists(file.path(root, "_targets.R"))) "_targets.R", names(files))
  sort(unique(rels))
}

# Search all files. `count(p)` is how many definitions file `p` holds; more
# than one in total is refused rather than editing the first.
wb_find <- function(files, locate, count, what) {
  err <- NULL
  found <- NULL
  n <- 0L
  for (rel in wb_rels(files)) {
    p <- tryCatch(wb_parse(wb_files_get(files, rel)$lines, rel), error = function(e) {
      if (is.null(err)) err <<- conditionMessage(e)
      NULL
    })
    if (is.null(p)) next
    k <- count(p)
    if (k > 0L && is.null(found)) found <- list(rel = rel, p = p, hit = locate(p))
    n <- n + k
  }
  if (n > 1L) wb_bad(sprintf("%s is defined %d times; change it in RStudio.", what, n))
  if (is.null(found) && !is.null(err)) wb_bad(err)
  found
}

wb_find_function <- function(files, name) {
  r <- wb_find(files, function(p) wb_function(p, name), function(p) wb_n_functions(p, name),
    sprintf("Function %s()", name))
  if (is.null(r)) wb_bad(sprintf("Function %s() not found.", name))
  list(rel = r$rel, p = r$p, f = r$hit)
}

wb_n_targets <- function(p, name) sum(vapply(wb_targets(p), function(t) identical(t$name, name), logical(1)))

wb_find_target <- function(files, name) {
  r <- wb_find(files, function(p) wb_target(p, name), function(p) wb_n_targets(p, name),
    sprintf("Target %s", name))
  if (is.null(r)) wb_bad(sprintf("Target %s not found.", name))
  list(rel = r$rel, p = r$p, t = r$hit)
}

wb_put <- function(files, rel, lines) {
  txt <- wb_files_get(files, rel)
  txt$lines <- lines
  files[[rel]] <- txt
  files
}

wb_edit <- function(line1, col1, line2, col2, text) {
  data.frame(line1 = as.integer(line1), col1 = as.integer(col1), line2 = as.integer(line2),
    col2 = as.integer(col2), text = text, stringsAsFactors = FALSE)
}

wb_edits <- function(...) {
  e <- list(...)
  if (!length(e)) return(wb_edit(integer(), integer(), integer(), integer(), character()))
  do.call(rbind, e)
}

wb_splice <- function(files, rel, p, edits) wb_put(files, rel, splice_lines(p$lines, edits))

quote_r <- function(x) {
  x <- gsub("\\", "\\\\", x, fixed = TRUE)
  x <- gsub("\"", "\\\"", x, fixed = TRUE)
  x <- gsub("\n", "\\n", x, fixed = TRUE)
  paste0("\"", x, "\"")
}

# --- argument lists (call arguments and formals share one shape) -----------

# Display column of character `chars` of `line` (tabs advance to multiples of 8).
wb_col_of <- function(line, chars) wb_end_col(substr(line, 1L, chars)) - 1L

# Cut arguments `idx` of `args`, each with one separating comma. Other
# comments are never touched: an argument alone on its lines is cut line by
# line (with its own trailing comment), otherwise only its span goes. Cutting
# the tail of the list takes the comma after the last kept argument instead
# (that comma's trailing comment stays on its line).
wb_cut <- function(p, args, idx) {
  if (!length(idx)) return(wb_edits())
  lines <- p$lines
  n <- nrow(args)
  idx <- sort(idx)
  comma_after <- function(i) {
    line <- lines[args$line2[i]]
    c0 <- pd_char(line, args$col2[i])
    m <- regexpr("^\\s*,", substring(line, c0 + 1L))
    if (m < 0) NA_integer_ else c0 + attr(m, "match.length")
  }
  tail_run <- integer()
  i <- n
  while (i >= 1L && i %in% idx) {
    tail_run <- c(i, tail_run)
    i <- i - 1L
  }
  edits <- list()
  handled <- integer()
  k <- if (length(tail_run)) tail_run[1] - 1L else 0L
  if (k >= 1L) {
    cm <- comma_after(k)
    if (!is.na(cm)) {
      cl <- args$line2[k]
      ccol <- wb_col_of(lines[cl], cm)
      if (args$line1[tail_run[1]] == cl && args$line2[n] == cl) {
        edits[[1]] <- wb_edit(cl, ccol, cl, args$col2[n], "")
        handled <- tail_run
      } else {
        edits[[1]] <- wb_edit(cl, ccol, cl, ccol, "")
      }
    }
  }
  for (i in setdiff(idx, handled)) {
    l1 <- args$line1[i]
    l2 <- args$line2[i]
    first <- lines[l1]
    last <- lines[l2]
    prefix <- substr(first, 1L, pd_char(first, args$col1[i]) - 1L)
    e <- pd_char(last, args$col2[i])
    cm <- if (i < n) comma_after(i) else NA_integer_
    after <- substring(last, (if (is.na(cm)) e else cm) + 1L)
    own <- !nzchar(trimws(prefix)) && (!nzchar(trimws(after)) || startsWith(trimws(after), "#")) &&
      (i == n || !is.na(cm))
    if (own && l2 < length(lines)) {
      edits[[length(edits) + 1L]] <- wb_edit(l1, 1L, l2 + 1L, 0L, "")
      next
    }
    end_chars <- if (is.na(cm)) e else cm
    # eat the blanks after the comma unless a comment or the line end follows
    if (!is.na(cm)) {
      ws <- regexpr("^\\s+", after)
      if (ws > 0 && !startsWith(trimws(after), "#")) end_chars <- end_chars + attr(ws, "match.length")
    }
    edits[[length(edits) + 1L]] <- wb_edit(l1, args$col1[i], l2, wb_col_of(last, end_chars), "")
  }
  do.call(wb_edits, unname(edits))
}

# Display column just past the end of `line` (tabs advance to multiples of 8).
wb_end_col <- function(line) {
  end <- 0L
  for (ch in strsplit(line, "", fixed = TRUE)[[1]]) {
    end <- if (ch == "\t") (end %/% 8L + 1L) * 8L else end + 1L
  }
  end + 1L
}

# Layout of an argument list: `indent` is the leading whitespace of the last
# argument if every argument after the first starts its own line (one per
# line), else NULL.
wb_arg_layout <- function(p, args) {
  if (!nrow(args)) return(NULL)
  prefix <- vapply(seq_len(nrow(args)), function(i) {
    line <- p$lines[args$line1[i]]
    substr(line, 1L, pd_char(line, args$col1[i]) - 1L)
  }, character(1))
  own <- !nzchar(trimws(prefix))
  if (all(own[-1]) && (nrow(args) > 1L || own[1])) prefix[nrow(args)] else NULL
}

# Append `texts` after the last argument. With one-per-line layout every new
# argument goes on its own line with the same indentation (the comma stays
# right after the argument, a trailing comment stays on its line).
wb_append <- function(p, args, close_paren, texts, indent = wb_arg_layout(p, args)) {
  if (!length(texts)) return(wb_edits())
  if (!nrow(args)) {
    return(wb_edit(close_paren[["line"]], close_paren[["col"]], close_paren[["line"]],
      close_paren[["col"]] - 1L, paste(texts, collapse = ", ")))
  }
  last <- args[nrow(args), ]
  if (is.null(indent)) {
    return(wb_edit(last$line2, last$col2 + 1L, last$line2, last$col2, paste0(", ", paste(texts, collapse = ", "))))
  }
  lines_new <- paste0(indent, texts, c(rep(",", length(texts) - 1L), ""), collapse = "\n")
  if (close_paren[["line"]] == last$line2) {
    return(wb_edit(last$line2, last$col2 + 1L, last$line2, last$col2, paste0(",\n", lines_new)))
  }
  eol <- wb_end_col(p$lines[last$line2])
  wb_edits(
    wb_edit(last$line2, last$col2 + 1L, last$line2, last$col2, ","),
    wb_edit(last$line2, eol, last$line2, eol - 1L, paste0("\n", lines_new))
  )
}

# Two passes, because removing and appending next to each other would
# overlap: first cut/replace, then re-parse and append.
# `locate(p)` returns list(args, close_paren) or NULL; `plan(args)` returns
# list(remove = <idx>, replace = named list idx -> text, add = <texts>).
wb_edit_args <- function(files, rel, locate, plan) {
  p <- wb_parse(wb_files_get(files, rel)$lines, rel)
  ca <- locate(p)
  pl <- plan(ca$args)
  indent <- wb_arg_layout(p, ca$args)
  e1 <- wb_cut(p, ca$args, pl$remove)
  rp <- lapply(names(pl$replace), function(i) {
    a <- ca$args[as.integer(i), ]
    wb_edit(a$line1, a$col1, a$line2, a$col2, pl$replace[[i]])
  })
  edits <- do.call(wb_edits, c(list(e1), rp))
  if (nrow(edits)) {
    files <- wb_splice(files, rel, p, edits)
    p <- wb_parse(wb_files_get(files, rel)$lines, rel)
    ca <- locate(p)
    # kept arguments only: removed ones are gone after the re-parse
  }
  if (length(pl$add)) {
    files <- wb_splice(files, rel, p, wb_append(p, ca$args, ca$close_paren, pl$add, indent))
  }
  files
}

# --- change kinds ------------------------------------------------------------

chg_set_doc <- function(files, ch) {
  r <- wb_find_function(files, ch$fn)
  f <- r$f
  lines <- r$p$lines
  block <- if (f$doc1 < f$line1) lines[f$doc1:(f$line1 - 1L)] else character()
  new <- rox_set(block, ch$field, ch$value, param = ch$param, formals = f$formals$name)
  if (identical(new, block)) return(files)
  wb_put(files, r$rel, c(lines[seq_len(f$doc1 - 1L)], new, lines[f$line1:length(lines)]))
}

wb_default <- function(x) {
  d <- x$default
  if (is.null(d) || length(d) != 1L || is.na(d)) NA_character_ else as.character(d)
}

chg_set_formals <- function(files, ch) {
  r <- wb_find_function(files, ch$fn)
  want <- ch$formals
  nm <- vapply(want, function(x) x$name, character(1))
  def <- vapply(want, wb_default, character(1))
  locate <- function(p) {
    f <- wb_function(p, ch$fn)
    list(args = f$formals, close_paren = f$close_paren, p = p)
  }
  wb_edit_args(files, r$rel, locate, function(args) {
    # source default text of each formal
    src <- vapply(seq_len(nrow(args)), function(i) {
      t <- wb_text(r$p, args$line1[i], args$col1[i], args$line2[i], args$col2[i])
      if (grepl("=", t, fixed = TRUE)) trimws(sub("^[^=]*=", "", t)) else NA_character_
    }, character(1))
    kept <- match(args$name, nm)
    replace <- list()
    for (i in which(!is.na(kept))) {
      d <- def[kept[i]]
      if (!identical(trimws(d), src[i])) replace[[as.character(i)]] <- if (is.na(d)) args$name[i] else paste0(args$name[i], " = ", d)
    }
    new <- which(!nm %in% args$name)
    list(remove = which(is.na(kept)), replace = replace,
      add = ifelse(is.na(def[new]), nm[new], paste0(nm[new], " = ", def[new])))
  })
}

chg_set_body <- function(files, ch) {
  r <- wb_find_function(files, ch$fn)
  f <- r$f
  if (!f$body_braced) wb_bad(sprintf("%s() has no braced body; change it in RStudio.", ch$fn))
  b <- r$p$pd[r$p$pd$id == f$body_id, ]
  indent <- sub("^(\\s*).*$", "\\1", r$p$lines[f$line1])
  body <- strsplit(gsub("\r", "", ch$body, fixed = TRUE), "\n", fixed = TRUE)[[1]]
  pd <- tryCatch(utils::getParseData(parse(text = body, keep.source = TRUE, encoding = "UTF-8")),
    error = function(e) wb_bad(sprintf("The body of %s() does not parse: %s", ch$fn, conditionMessage(e))))
  # lines that continue a multi-line string keep their text
  inside <- integer()
  if (!is.null(pd)) {
    str <- pd[pd$token == "STR_CONST" & pd$line2 > pd$line1, , drop = FALSE]
    for (j in seq_len(nrow(str))) inside <- c(inside, (str$line1[j] + 1L):str$line2[j])
  }
  shifted <- ifelse(seq_along(body) %in% inside | !nzchar(body), body, paste0(indent, "  ", body))
  inner <- if (length(body)) paste0("\n", paste(shifted, collapse = "\n")) else ""
  text <- paste0("{", inner, "\n", indent, "}")
  wb_splice(files, r$rel, r$p, wb_edit(b$line1, b$col1, b$line2, b$col2, text))
}

chg_set_target_arg <- function(files, ch) {
  stopifnot(ch$arg %in% c("format", "pattern", "description"))
  r <- wb_find_target(files, ch$target)
  text <- if (is.null(ch$value)) NULL else if (ch$arg == "pattern") ch$value else quote_r(ch$value)
  locate <- function(p) {
    t <- wb_target(p, ch$target)
    list(args = t$args, close_paren = t$close_paren)
  }
  wb_edit_args(files, r$rel, locate, function(args) {
    i <- which(args$name == ch$arg)
    if (!length(i)) return(list(remove = integer(), replace = list(), add = if (!is.null(text)) paste0(ch$arg, " = ", text)))
    if (is.null(text)) return(list(remove = i, replace = list(), add = character()))
    list(remove = integer(), replace = stats::setNames(list(paste0(ch$arg, " = ", text)), i[1]), add = character())
  })
}

chg_set_call <- function(files, ch) {
  r <- wb_find_target(files, ch$target)
  if (is.na(r$t$cmd_id) || is.na(wb_callee(r$p, r$t$cmd_id))) {
    wb_bad(sprintf("The command of target %s is not a plain function call; change it in RStudio.", ch$target))
  }
  locate <- function(p) {
    t <- wb_target(p, ch$target)
    wb_call_args(p, t$cmd_id)
  }
  wb_edit_args(files, r$rel, locate, function(args) {
    key_src <- paste(args$name, args$text, sep = "\r")
    key_new <- vapply(ch$args, function(a) paste(if (isTRUE(a$named)) a$name else "", a$value, sep = "\r"), character(1))
    kept <- rep(FALSE, length(key_new))
    keep_src <- logical(nrow(args))
    for (i in seq_along(key_src)) {
      j <- which(key_new == key_src[i] & !kept)
      if (length(j)) {
        kept[j[1]] <- TRUE
        keep_src[i] <- TRUE
      }
    }
    text <- function(a) if (isTRUE(a$named)) paste0(a$name, " = ", a$value) else a$value
    slot_new <- vapply(ch$args, function(a) if (isTRUE(a$named)) a$name else "", character(1))
    # an argument whose value changed keeps its place (same name, or the next
    # positional one); the rest is cut or appended
    replace <- list()
    for (i in which(!keep_src)) {
      j <- which(slot_new == args$name[i] & !kept)
      if (!length(j)) next
      kept[j[1]] <- TRUE
      keep_src[i] <- TRUE
      replace[[as.character(i)]] <- text(ch$args[[j[1]]])
    }
    add <- vapply(ch$args[!kept], text, character(1))
    list(remove = which(!keep_src), replace = replace, add = add)
  })
}

# --- renames, removal, new targets --------------------------------------------

wb_note <- function(files, text) {
  attr(files, "notes") <- c(attr(files, "notes"), text)
  files
}

# Every file, parsed. A rename has to see all of them, so a file that does not
# parse is refused.
wb_parse_all <- function(files) {
  rels <- wb_rels(files)
  out <- lapply(rels, function(rel) {
    tryCatch(wb_parse(wb_files_get(files, rel)$lines, rel), error = function(e) wb_bad(conditionMessage(e)))
  })
  stats::setNames(out, rels)
}

wb_check_name <- function(x, what = "name") {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x) || make.names(x) != x) {
    wb_bad(sprintf("%s is not a valid %s.", if (is.character(x) && length(x) == 1L) x else "This", what))
  }
}

# Refuse `to` when a function or target of that name exists.
wb_check_free <- function(parsed, to) {
  for (rel in names(parsed)) {
    if (wb_n_functions(parsed[[rel]], to)) wb_bad(sprintf("%s is already a function in %s.", to, rel))
    if (wb_n_targets(parsed[[rel]], to)) wb_bad(sprintf("%s is already a target in %s.", to, rel))
  }
}

# Replace one SYMBOL / STR_CONST token by `to` (a string keeps its quotes).
wb_token_edit <- function(row, to) {
  text <- if (row$token == "STR_CONST") paste0(substr(row$text, 1L, 1L), to, substr(row$text, 1L, 1L)) else to
  wb_edit(row$line1, row$col1, row$line2, row$col2, text)
}

wb_token_edits <- function(rows, to) {
  do.call(wb_edits, lapply(seq_len(nrow(rows)), function(i) wb_token_edit(rows[i, ], to)))
}

wb_parent <- function(p, id) p$pd$parent[p$pd$id == id]

# Source lines of the report sources: the static `path` of every
# `tar_render()` / `tar_quarto()` call, as a named list path -> lines.
wb_reports <- function(files, parsed) {
  root <- attr(files, "root")
  out <- list()
  for (p in parsed) {
    for (t in wb_targets(p)) {
      if (!t$fn %in% c("tar_render", "tar_quarto")) next
      i <- which(t$args$name == "path")
      if (!length(i)) i <- setdiff(which(t$args$name == ""), t$name_arg)
      if (!length(i)) next
      path <- tryCatch(str2lang(t$args$text[i[1]]), error = function(e) NULL)
      if (!is.character(path) || length(path) != 1L) next
      full <- file.path(root, path)
      lines <- if (!is.null(files[[path]])) files[[path]]$lines else if (file.exists(full) && !dir.exists(full)) read_utf8(full)
      if (length(lines)) out[[path]] <- lines
    }
  }
  out
}

# Refuse when a report reads a target by `tar_read()` / `tar_load()` matching
# `rx` (the one regex over raw text: it only reads).
wb_check_reports <- function(reports, rx, msg) {
  for (path in names(reports)) {
    if (any(grepl(rx, reports[[path]], perl = TRUE))) wb_bad(sprintf(msg, path))
  }
}

wb_rx_escape <- function(x) gsub("([.\\\\|()\\[\\]{}^$*+?])", "\\\\\\1", x, perl = TRUE)

# Number of templates of the `tar_map()` call `id`: each target call counts
# one, each holder symbol its number of elements.
wb_map_templates <- function(parsed, p, id) {
  args <- wb_call_args(p, id)$args
  n <- 0L
  for (i in which(args$name == "")) {
    if (is.na(args$id[i])) next
    if (wb_callee(p, args$id[i]) %in% TARGET_CALLS) {
      n <- n + 1L
      next
    }
    for (q in parsed) {
      bl <- wb_block_list(q, args$text[i])
      if (!is.null(bl)) {
        n <- n + nrow(bl$args)
        break
      }
    }
  }
  n
}

# The `tar_map()` target `t` (in file `rel`) is a template of: directly inside
# it, or an element of a holder `x <- list(...)` that a map names by symbol.
# Returns NULL or list(n = number of templates, exclude = rel -> token ids of
# the map and the holder).
wb_map_of <- function(parsed, rel, t) {
  p <- parsed[[rel]]
  id <- t$id
  repeat {
    id <- wb_parent(p, id)
    if (!length(id) || id == 0L) break
    if (identical(wb_callee(p, id), "tar_map")) {
      return(list(n = wb_map_templates(parsed, p, id), exclude = stats::setNames(list(parse_descendants(p$kids, id)), rel)))
    }
  }
  container <- wb_parent(p, t$id)
  holder <- NULL
  for (a_id in wb_tops(p)$id) {
    k <- wb_children(p, a_id)
    if (nrow(k) == 3L && k$token[2] %in% c("LEFT_ASSIGN", "EQ_ASSIGN") && k$id[3] == container &&
        identical(wb_callee(p, container), "list")) {
      lhs <- wb_children(p, k$id[1])
      if (nrow(lhs) == 1L) holder <- list(name = gsub("^[\"'`]|[\"'`]$", "", lhs$text), id = a_id)
    }
  }
  if (is.null(holder)) return(NULL)
  for (mrel in names(parsed)) {
    q <- parsed[[mrel]]
    calls <- q$pd$id[q$pd$token == "SYMBOL_FUNCTION_CALL" & q$pd$text == "tar_map"]
    for (s in calls) {
      map_id <- wb_parent(q, wb_parent(q, s))
      args <- wb_call_args(q, map_id)$args
      if (!holder$name %in% args$text[args$name == ""]) next
      exclude <- list()
      exclude[[mrel]] <- parse_descendants(q$kids, map_id)
      exclude[[rel]] <- c(exclude[[rel]], parse_descendants(p$kids, holder$id))
      return(list(n = wb_map_templates(parsed, q, map_id), exclude = exclude))
    }
  }
  NULL
}

chg_rename_function <- function(files, ch) {
  fn <- ch$fn
  to <- ch$to
  wb_check_name(to, "function name")
  r <- wb_find_function(files, fn)
  parsed <- wb_parse_all(files)
  wb_check_free(parsed, to)
  n <- 0L
  for (rel in names(parsed)) {
    p <- parsed[[rel]]
    pd <- p$pd
    calls <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text == fn, , drop = FALSE]
    calls <- calls[!calls$parent %in% pd$parent[pd$token %in% c("NS_GET", "NS_GET_INT")], , drop = FALSE]
    n <- n + nrow(calls)
    rows <- calls
    if (rel == r$rel) rows <- rbind(rows, pd[pd$id == r$f$name_id, , drop = FALSE])
    if (nrow(rows)) files <- wb_splice(files, rel, p, wb_token_edits(rows, to))
  }
  wb_note(files, sprintf("Renamed %d call(s) of %s(); calls by string or in reports are not followed.", n, fn))
}

chg_rename_target <- function(files, ch) {
  target <- ch$target
  to <- ch$to
  wb_check_name(to, "target name")
  r <- wb_find_target(files, target)
  parsed <- wb_parse_all(files)
  wb_check_free(parsed, to)
  reports <- wb_reports(files, parsed)
  wb_check_reports(reports, sprintf("tar_(read|load)\\(\\s*%s\\s*[,)]", wb_rx_escape(target)),
    paste0("The report %s reads target ", target, "; rename it there and in RStudio."))
  map <- wb_map_of(parsed, r$rel, r$t)
  if (!is.null(map)) {
    prefix <- paste0(target, "_")
    for (rel in names(parsed)) {
      pd <- parsed[[rel]]$pd
      hit <- pd$token == "SYMBOL" & startsWith(pd$text, prefix) & !pd$id %in% map$exclude[[rel]]
      if (any(hit)) {
        wb_bad(sprintf("Target %s is a map template and %s uses its variant %s; rename it in RStudio.",
          target, rel, pd$text[hit][1]))
      }
    }
    wb_check_reports(reports, sprintf("tar_(read|load)\\(\\s*%s", wb_rx_escape(prefix)),
      paste0("The report %s reads variants of the map template ", target, "; rename it there and in RStudio."))
  }
  for (rel in names(parsed)) {
    p <- parsed[[rel]]
    pd <- p$pd
    ids <- integer()
    for (t in wb_targets(p)) {
      ids <- c(ids, setdiff(parse_descendants(p$kids, t$id), parse_descendants(p$kids, t$name_id)))
    }
    # `x$target` / `x@target` are not references
    field <- pd$parent[pd$token %in% c("'$'", "'@'")]
    rows <- pd[pd$id %in% unique(ids) & pd$token == "SYMBOL" & pd$text == target & !pd$parent %in% field, , drop = FALSE]
    if (rel == r$rel) {
      rows <- rbind(rows, pd[pd$parent == r$t$name_id & pd$token %in% c("SYMBOL", "STR_CONST"), , drop = FALSE])
    }
    if (nrow(rows)) files <- wb_splice(files, rel, p, wb_token_edits(rows, to))
  }
  files
}

chg_remove_target <- function(files, ch) {
  target <- ch$target
  r <- wb_find_target(files, target)
  container <- wb_parent(r$p, r$t$id)
  if (!length(container) || container == 0L || is.na(wb_callee(r$p, container))) {
    wb_bad(sprintf("Target %s is not an element of a list; remove it in RStudio.", target))
  }
  map <- wb_map_of(wb_parse_all(files), r$rel, r$t)
  if (!is.null(map) && map$n <= 1L) {
    wb_bad(sprintf("Target %s is the only template of its tar_map(); remove the map in RStudio.", target))
  }
  locate <- function(p) {
    t <- wb_target(p, target)
    wb_call_args(p, wb_parent(p, t$id))
  }
  wb_edit_args(files, r$rel, locate, function(args) {
    list(remove = which(args$id == r$t$id), replace = list(), add = character())
  })
}

# Append one element (`text`, lines) to a list: comma after the last element's
# expression, the new element on its own line, indented like the last one
# (two spaces for an empty list).
wb_append_element <- function(p, lst, text) {
  args <- lst$args
  cp <- lst$close_paren
  if (!nrow(args)) {
    line <- p$lines[cp[["line"]]]
    before <- substr(line, 1L, pd_char(line, cp[["col"]]) - 1L)
    body <- paste0("  ", text, collapse = "\n")
    if (!nzchar(trimws(before))) return(wb_edit(cp[["line"]], 1L, cp[["line"]], 0L, paste0(body, "\n")))
    return(wb_edit(cp[["line"]], cp[["col"]], cp[["line"]], cp[["col"]] - 1L, paste0("\n", body, "\n")))
  }
  indent <- wb_arg_layout(p, args)
  if (is.null(indent)) indent <- paste0(sub("^(\\s*).*$", "\\1", p$lines[args$line1[nrow(args)]]), "  ")
  joined <- paste(c(text[1], if (length(text) > 1L) paste0(indent, text[-1])), collapse = "\n")
  wb_append(p, args, cp, joined, indent = indent)
}

chg_add_target <- function(files, ch) {
  block <- ch$block
  if (!is.character(block) || length(block) != 1L || !grepl("^R/.+\\.[Rr]$", block)) {
    wb_bad("The block must be a file R/<name>.R.")
  }
  stem <- sub("\\.[Rr]$", "", basename(block))
  holder <- paste0("pipeline_", stem)
  wb_check_name(holder, "block list name")
  wb_check_name(ch$target, "target name")
  fn <- ch$fn
  wb_check_name(fn$name, "function name")
  parsed <- wb_parse_all(files)
  for (rel in names(parsed)) {
    if (wb_n_targets(parsed[[rel]], ch$target)) wb_bad(sprintf("%s is already a target in %s.", ch$target, rel))
  }
  fn_lines <- NULL
  if (!any(vapply(parsed, wb_n_functions, integer(1), name = fn$name) > 0L)) {
    if (!length(fn$body) || !nzchar(trimws(fn$body))) fn$body <- sprintf("stop(\"Not implemented: %s()\")", fn$name)
    fn_lines <- function_text(fn)
  }
  call_lines <- target_text(ch$target, fn$name, ch$args, ch$format, ch$pattern)
  p <- parsed[[block]]
  bl <- if (!is.null(p)) wb_block_list(p, holder)
  if (!is.null(p) && is.null(bl) && !is.null(wb_assignment(p, holder))) {
    wb_bad(sprintf("%s in %s is not a list(...); add the target in RStudio.", holder, block))
  }
  if (!is.null(bl)) {
    files <- wb_splice(files, block, p, wb_append_element(p, bl, call_lines))
    if (length(fn_lines)) {
      lines <- wb_files_get(files, block)$lines
      a <- wb_assignment(wb_parse(lines, block), holder)
      at <- a$lhs$line1
      # keep comment lines directly above the holder with it
      while (at > 1L && grepl("^\\s*#", lines[at - 1L])) at <- at - 1L
      before <- lines[seq_len(at - 1L)]
      blank <- length(before) && nzchar(trimws(before[length(before)]))
      files <- wb_put(files, block, c(before, if (blank) "", fn_lines, "", lines[at:length(lines)]))
    }
    return(files)
  }
  # no block list yet: create it and add it to the composition in _targets.R
  tp <- parsed[["_targets.R"]]
  comp <- if (!is.null(tp)) wb_composition(tp)
  if (is.null(comp)) wb_bad(sprintf("Cannot find the list of blocks in _targets.R; add %s there by hand.", holder))
  if (!holder %in% comp$args$text[comp$args$name == ""]) {
    files <- wb_splice(files, "_targets.R", tp, wb_append_element(tp, comp, holder))
  }
  new <- c(fn_lines, if (length(fn_lines)) "", paste0(holder, " <- list("), paste0("  ", call_lines), ")")
  if (is.null(p)) {
    files[[block]] <- list(lines = new, eol = "\n", final_nl = TRUE)
    return(files)
  }
  lines <- p$lines
  blank <- length(lines) && nzchar(trimws(lines[length(lines)]))
  wb_put(files, block, c(lines, if (blank) "", new))
}

# --- the transaction ---------------------------------------------------------

wb_stale <- function(item, file, message = NULL) {
  if (is.null(message)) {
    message <- sprintf("%s in %s changed since the page loaded it. The view is refreshed; try again.", item, file)
  }
  stop(structure(class = c("pipeworks_stale", "error", "condition"),
    list(message = message, call = NULL, item = item, file = file)))
}

# kind -> (item prefix, required string fields, required list fields)
WB_KINDS <- list(
  set_doc = list(item = "function:", str = c("fn", "field"), lst = character()),
  set_formals = list(item = "function:", str = "fn", lst = "formals"),
  set_body = list(item = "function:", str = c("fn", "body"), lst = character()),
  set_target_arg = list(item = "target:", str = c("target", "arg"), lst = character()),
  set_call = list(item = "target:", str = "target", lst = "args"),
  rename_function = list(item = "function:", str = c("fn", "to"), lst = character()),
  rename_target = list(item = "target:", str = c("target", "to"), lst = character()),
  remove_target = list(item = "target:", str = "target", lst = character()),
  add_target = list(item = NULL, str = c("target", "block"), lst = "fn")
)

wb_is_string <- function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x)

wb_validate <- function(changes) {
  if (!is.list(changes) || !length(changes)) wb_bad("No changes to write.")
  for (ch in changes) {
    kind <- if (is.list(ch)) ch$kind
    if (!wb_is_string(kind) || is.null(WB_KINDS[[kind]])) {
      wb_bad(sprintf("Unknown change kind %s.", if (wb_is_string(kind)) kind else "(missing)"))
    }
    spec <- WB_KINDS[[kind]]
    need <- c(if (!is.null(spec$item)) c("item", "base"), spec$str)
    for (f in need) {
      if (!wb_is_string(ch[[f]])) wb_bad(sprintf("%s: field %s must be a string.", kind, f))
    }
    for (f in spec$lst) {
      if (!is.list(ch[[f]])) wb_bad(sprintf("%s: field %s must be a list.", kind, f))
    }
    if (!is.null(spec$item)) {
      own <- ch[[if (startsWith(spec$item, "function:")) "fn" else "target"]]
      if (!identical(ch$item, paste0(spec$item, own))) {
        wb_bad(sprintf("%s: item %s does not match %s.", kind, ch$item, own))
      }
    }
    if (kind == "set_doc" && identical(ch$field, "param") && !wb_is_string(ch$param)) {
      wb_bad("set_doc: field param needs a param name.")
    }
  }
  invisible(changes)
}

# Stale check against the files as they are on disk (`orig`), so changes
# earlier in the request cannot make a later item look stale.
wb_check_base <- function(orig, ch) {
  r <- tryCatch(
    if (startsWith(ch$item, "function:")) wb_find_function(orig, sub("^function:", "", ch$item)) else
      wb_find_target(orig, sub("^target:", "", ch$item)),
    pipeworks_bad_change = function(e) {
      if (grepl("not found\\.$", conditionMessage(e))) NULL else stop(e)
    }
  )
  if (is.null(r)) wb_stale(ch$item, NA_character_)
  if (!identical(wb_item_base(r$p, ch$item), ch$base)) wb_stale(ch$item, r$rel)
  invisible(r)
}

apply_changes <- function(path, changes) {
  wb_validate(changes)
  orig <- wb_files(path)
  files <- orig
  touched <- character()
  for (ch in changes) {
    if (!is.null(ch$item) && !ch$item %in% touched) {
      wb_check_base(orig, ch)
      touched <- c(touched, ch$item)
    }
    files <- get(paste0("chg_", ch$kind))(files, ch)
  }
  rels <- names(files)
  disk <- function(rel) file.path(path, rel)
  before <- lapply(rels, function(rel) if (file.exists(disk(rel))) read_text(disk(rel)))
  names(before) <- rels
  changed <- vapply(rels, function(rel) {
    is.null(before[[rel]]) || !identical(before[[rel]]$lines, files[[rel]]$lines)
  }, logical(1))
  rels <- rels[changed]
  for (rel in rels) {
    tryCatch(wb_parse(files[[rel]]$lines, rel), error = function(e) {
      stop(sprintf("Bug: the change would break %s; nothing was written.", rel), call. = FALSE)
    })
  }
  written <- character()
  tryCatch({
    for (rel in rels) {
      write_text(disk(rel), files[[rel]])
      written <- c(written, rel)
    }
  }, error = function(e) {
    for (rel in written) {
      if (is.null(before[[rel]])) unlink(disk(rel)) else try(write_text(disk(rel), before[[rel]]), silent = TRUE)
    }
    stop(e)
  })
  undo <- lapply(rels, function(rel) list(
    before = if (is.null(before[[rel]])) character() else before[[rel]]$lines,
    after = files[[rel]]$lines, existed = !is.null(before[[rel]])
  ))
  names(undo) <- rels
  notes <- attr(files, "notes")
  list(files = rels, notes = if (is.null(notes)) character() else as.character(notes), undo = undo)
}

# First index at which `needle` occurs in `hay` (all of them).
wb_find_seq <- function(hay, needle) {
  n <- length(needle)
  if (!n || length(hay) < n) return(integer())
  hits <- which(hay == needle[1])
  hits[vapply(hits, function(i) i + n - 1L <= length(hay) && identical(hay[i:(i + n - 1L)], needle), logical(1))]
}

# Where `after` (a region of the edit) sits in `cur`: the single occurrence,
# widened by context lines of the kept text until it is unique. `NULL` if it
# is gone or still ambiguous.
wb_undo_place <- function(cur, prefix, region, suffix) {
  for (k in 0:max(length(prefix), length(suffix))) {
    pre <- utils::tail(prefix, min(k, length(prefix)))
    suf <- utils::head(suffix, min(k, length(suffix)))
    needle <- c(pre, region, suf)
    if (!length(needle)) next
    hits <- wb_find_seq(cur, needle)
    if (length(hits) == 1L) return(list(from = hits + length(pre), n = length(region)))
    if (!length(hits)) return(NULL)
  }
  NULL
}

undo_changes <- function(path, undo) {
  stale <- function(rel) wb_stale(NA_character_, rel, sprintf("%s changed since that edit; undo it in RStudio.", rel))
  plan <- list()
  for (rel in names(undo)) {
    u <- undo[[rel]]
    file <- file.path(path, rel)
    if (!file.exists(file)) stale(rel)
    txt <- read_text(file)
    if (!isTRUE(u$existed)) {
      if (!identical(txt$lines, u$after)) stale(rel)
      plan[[rel]] <- list(delete = TRUE)
      next
    }
    b <- u$before
    a <- u$after
    m <- min(length(a), length(b))
    pre <- 0L
    while (pre < m && identical(a[pre + 1L], b[pre + 1L])) pre <- pre + 1L
    suf <- 0L
    while (suf < m - pre && identical(a[length(a) - suf], b[length(b) - suf])) suf <- suf + 1L
    region <- a[seq_len(length(a) - pre - suf) + pre]
    at <- wb_undo_place(txt$lines, a[seq_len(pre)], region, a[seq_len(suf) + length(a) - suf])
    if (is.null(at)) stale(rel)
    restore <- b[seq_len(length(b) - pre - suf) + pre]
    lines <- txt$lines
    txt$lines <- c(lines[seq_len(at$from - 1L)], restore, lines[seq_len(length(lines) - at$from - at$n + 1L) + at$from + at$n - 1L])
    plan[[rel]] <- list(txt = txt)
  }
  for (rel in names(plan)) {
    if (isTRUE(plan[[rel]]$delete)) unlink(file.path(path, rel)) else write_text(file.path(path, rel), plan[[rel]]$txt)
  }
  names(plan)
}
