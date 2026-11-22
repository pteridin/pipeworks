# Locate chunks of a source file by parse tokens (never by regex over raw
# text), so later steps can splice editor changes into exactly these spans.
# All spans are parse-data positions (line/col as in `getParseData()`, with
# `keep.source = TRUE, encoding = "UTF-8"` so columns count characters); use
# `pd_char()` / `splice_lines()` to turn them into character indices.

# Parse `lines` of `file`. Returns `lines`, `pd` (parse data) and `kids`
# (child ids per parent).
wb_parse <- function(lines, file) {
  exprs <- tryCatch(
    parse(text = lines, keep.source = TRUE, encoding = "UTF-8"),
    error = function(e) stop("Cannot parse ", file, ": ", conditionMessage(e), call. = FALSE)
  )
  pd <- utils::getParseData(exprs, includeText = NA)
  if (is.null(pd)) pd <- data.frame(line1 = integer(), col1 = integer(), line2 = integer(), col2 = integer(),
                                    id = integer(), parent = integer(), token = character(),
                                    terminal = logical(), text = character())
  list(lines = lines, pd = pd, kids = split(pd$id, pd$parent))
}

# Children of `id` in source order, comments dropped.
wb_children <- function(p, id) {
  k <- p$pd[p$pd$parent == id & p$pd$token != "COMMENT", , drop = FALSE]
  k[order(k$line1, k$col1), , drop = FALSE]
}

wb_tops <- function(p) wb_children(p, 0L)

# Source text of a parse-data span (may cover several lines).
wb_text <- function(p, line1, col1, line2, col2) {
  l <- p$lines
  a <- pd_char(l[line1], col1)
  b <- pd_char(l[line2], col2)
  if (line1 == line2) return(substr(l[line1], a, b))
  paste(c(substring(l[line1], a), l[seq_len(line2 - line1 - 1L) + line1], substr(l[line2], 1L, b)), collapse = "\n")
}

# Does `id` call a function called `fn` (plain or `pkg::fn`)? Its call name.
wb_callee <- function(p, id) {
  k <- wb_children(p, id)
  if (nrow(k) < 3 || k$token[1] != "expr" || k$token[2] != "'('") return(NA_character_)
  sym <- p$pd[p$pd$parent == k$id[1] & p$pd$token == "SYMBOL_FUNCTION_CALL", ]
  if (nrow(sym) == 1L) sym$text else NA_character_
}

# Arguments of the call expression `id`: `args` (name, span, value text, `id`
# of the value expression; `name` is "" for positional arguments), the
# `open_paren` and `close_paren` positions.
wb_call_args <- function(p, id) {
  k <- wb_children(p, id)
  open <- which(k$token == "'('")[1]
  close <- utils::tail(which(k$token == "')'"), 1L)
  inner <- k[seq_len(max(close - open - 1L, 0L)) + open, , drop = FALSE]
  group <- cumsum(inner$token == "','")
  args <- list()
  for (g in unique(group)) {
    part <- inner[group == g & inner$token != "','", , drop = FALSE]
    if (!nrow(part)) next
    named <- nrow(part) >= 2L && part$token[1] %in% c("SYMBOL_SUB", "STR_CONST") && part$token[2] == "EQ_SUB"
    nm <- ""
    value <- part[nrow(part), ]
    if (named) {
      nm <- part$text[1]
      if (part$token[1] == "STR_CONST") nm <- gsub("^[\"']|[\"']$", "", wb_text(p, part$line1[1], part$col1[1], part$line2[1], part$col2[1]))
      if (nrow(part) == 2L) value <- NULL  # `name =` with no value
    }
    last <- part[nrow(part), ]
    args[[length(args) + 1L]] <- data.frame(
      name = nm, line1 = part$line1[1], col1 = part$col1[1], line2 = last$line2, col2 = last$col2,
      text = if (is.null(value)) "" else wb_text(p, value$line1, value$col1, value$line2, value$col2),
      id = if (is.null(value)) NA_integer_ else value$id,
      stringsAsFactors = FALSE
    )
  }
  args <- if (length(args)) do.call(rbind, args) else
    data.frame(name = character(), line1 = integer(), col1 = integer(), line2 = integer(), col2 = integer(),
               text = character(), id = integer(), stringsAsFactors = FALSE)
  list(
    args = args,
    open_paren = c(line = k$line1[open], col = k$col1[open]),
    close_paren = c(line = k$line1[close], col = k$col1[close])
  )
}

# Every top-level `name <- <rhs>` (also `=`): the top expression and its rhs.
wb_assignments <- function(p, name) {
  out <- list()
  for (id in wb_tops(p)$id) {
    k <- wb_children(p, id)
    if (nrow(k) != 3L || k$token[1] != "expr" || !k$token[2] %in% c("LEFT_ASSIGN", "EQ_ASSIGN")) next
    lhs <- wb_children(p, k$id[1])
    if (nrow(lhs) != 1L || !lhs$token %in% c("SYMBOL", "STR_CONST") ||
        !identical(sub("^[\"'`]|[\"'`]$", "", lhs$text), name)) next
    out[[length(out) + 1L]] <- list(id = id, lhs = lhs, rhs = k$id[3])
  }
  out
}

# The first top-level `name <- <rhs>`.
wb_assignment <- function(p, name) {
  a <- wb_assignments(p, name)
  if (length(a)) a[[1]] else NULL
}

# Number of top-level function definitions called `name`.
wb_n_functions <- function(p, name) {
  sum(vapply(wb_assignments(p, name), function(a) {
    fk <- wb_children(p, a$rhs)
    nrow(fk) > 0L && fk$token[1] %in% c("FUNCTION", "'\\\\'")
  }, logical(1)))
}

# A top-level function definition `name <- function(...) ...`.
wb_function <- function(p, name) {
  a <- wb_assignment(p, name)
  if (is.null(a)) return(NULL)
  fk <- wb_children(p, a$rhs)
  if (!nrow(fk) || !fk$token[1] %in% c("FUNCTION", "'\\\\'")) return(NULL)
  top <- p$pd[p$pd$id == a$id, ]
  open <- which(fk$token == "'('")[1]
  close <- which(fk$token == "')'")[1]
  inner <- fk[seq_len(close - open - 1L) + open, , drop = FALSE]
  group <- cumsum(inner$token == "','")
  formals <- list()
  for (g in unique(group)) {
    part <- inner[group == g & inner$token != "','", , drop = FALSE]
    if (!nrow(part) || part$token[1] != "SYMBOL_FORMALS") next
    last <- part[nrow(part), ]
    formals[[length(formals) + 1L]] <- data.frame(
      name = part$text[1], line1 = part$line1[1], col1 = part$col1[1],
      line2 = last$line2, col2 = last$col2, stringsAsFactors = FALSE
    )
  }
  formals <- if (length(formals)) do.call(rbind, formals) else
    data.frame(name = character(), line1 = integer(), col1 = integer(), line2 = integer(), col2 = integer(),
               stringsAsFactors = FALSE)
  body <- fk[nrow(fk), ]
  braced <- nrow(wb_children(p, body$id)) > 0 && wb_children(p, body$id)$token[1] == "'{'"
  doc1 <- top$line1
  while (doc1 > 1L && grepl("^\\s*#'", p$lines[doc1 - 1L])) doc1 <- doc1 - 1L
  list(
    id = a$id, doc1 = as.integer(doc1), line1 = top$line1, line2 = top$line2, name_id = a$lhs$id,
    formals = formals,
    open_paren = c(line = fk$line1[open], col = fk$col1[open]),
    close_paren = c(line = fk$line1[close], col = fk$col1[close]),
    body_id = body$id, body_braced = braced
  )
}

# Every target-defining call (`TARGET_CALLS`, also `pkg::fn`) in the file, in
# source order: top level, inside `list()`, `tar_map()` or a template holder.
# `name_id` is the expression of the name argument.
wb_targets <- function(p) {
  pd <- p$pd
  sym <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text %in% TARGET_CALLS, , drop = FALSE]
  sym <- sym[order(sym$line1, sym$col1), , drop = FALSE]
  out <- list()
  for (j in seq_len(nrow(sym))) {
    call_id <- pd$parent[pd$id == pd$parent[pd$id == sym$id[j]]]
    ca <- wb_call_args(p, call_id)
    args <- ca$args
    by_name <- which(args$name == "name")
    pos <- which(args$name == "")
    n <- if (length(by_name)) by_name[1] else if (length(pos)) pos[1] else NA_integer_
    if (is.na(n)) next
    value <- tryCatch(str2lang(args$text[n]), error = function(e) NULL)
    nm <- arg_name(value)
    if (is.na(nm)) next
    cmd <- which(args$name == "command")
    if (!length(cmd)) {
      rest <- setdiff(pos, n)
      cmd <- if (length(rest)) rest[1] else integer()
    }
    row <- pd[pd$id == call_id, ]
    out[[length(out) + 1L]] <- list(
      id = call_id, name = nm, fn = sym$text[j], line1 = row$line1, line2 = row$line2,
      close_paren = ca$close_paren, args = args[c("name", "line1", "col1", "line2", "col2", "text")],
      cmd_id = if (length(cmd)) args$id[cmd[1]] else NA_integer_, name_id = args$id[n], name_arg = n
    )
  }
  out
}

# The first target-defining call whose name argument is `name`.
wb_target <- function(p, name) {
  for (t in wb_targets(p)) if (identical(t$name, name)) return(t)
  NULL
}

# The top-level `holder <- list(...)`.
wb_block_list <- function(p, holder) {
  a <- wb_assignment(p, holder)
  if (is.null(a) || !identical(wb_callee(p, a$rhs), "list")) return(NULL)
  ca <- wb_call_args(p, a$rhs)
  list(id = a$rhs, args = ca$args, close_paren = ca$close_paren)
}

# The top-level `list(...)` of `_targets.R` that has a `pipeline_*` symbol argument.
wb_composition <- function(p) {
  for (id in wb_tops(p)$id) {
    if (!identical(wb_callee(p, id), "list")) next
    ca <- wb_call_args(p, id)
    if (any(grepl("^pipeline_[[:alnum:]._]*$", ca$args$text[ca$args$name == ""]))) {
      return(list(id = id, args = ca$args, close_paren = ca$close_paren))
    }
  }
  NULL
}

item_base <- function(lines, line1, line2) md5_lines(lines[line1:line2])

# Base hash of an item in the parsed file `p`: a function from the first line
# of its contiguous roxygen block to its last line, a target over its call.
# The model and the stale check of `apply_changes()` both use this. `NA` if
# the file does not define the item.
wb_item_base <- function(p, item) {
  name <- sub("^[a-z]+:", "", item)
  span <- if (startsWith(item, "function:")) {
    f <- wb_function(p, name)
    if (!is.null(f)) c(f$doc1, f$line2)
  } else if (startsWith(item, "target:")) {
    t <- wb_target(p, name)
    if (!is.null(t)) c(t$line1, t$line2)
  }
  if (is.null(span)) NA_character_ else item_base(p$lines, span[1], span[2])
}
