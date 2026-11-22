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

wb_find <- function(files, locate) {
  err <- NULL
  for (rel in wb_rels(files)) {
    p <- tryCatch(wb_parse(wb_files_get(files, rel)$lines, rel), error = function(e) {
      if (is.null(err)) err <<- conditionMessage(e)
      NULL
    })
    if (is.null(p)) next
    hit <- locate(p)
    if (!is.null(hit)) return(list(rel = rel, p = p, hit = hit))
  }
  if (!is.null(err)) wb_bad(err)
  NULL
}

wb_find_function <- function(files, name) {
  r <- wb_find(files, function(p) wb_function(p, name))
  if (is.null(r)) wb_bad(sprintf("Function %s() not found.", name))
  list(rel = r$rel, p = r$p, f = r$hit)
}

wb_find_target <- function(files, name) {
  r <- wb_find(files, function(p) wb_target(p, name))
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
    list(remove = integer(), replace = setNames(list(paste0(ch$arg, " = ", text)), i[1]), add = character())
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
