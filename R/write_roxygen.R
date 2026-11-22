# Roxygen field splicing and text generators for write-back. Pure: lines in,
# lines out. Generated text mirrors the page's wrap()/roxygenFor()/fnBlock()/
# tarCall() (inst/app/index.html), except that continuation lines of a tag
# are indented, as the write-back design asks.

wrap_text <- function(text, width = 76L) {
  pars <- strsplit(text, "\n", fixed = TRUE)[[1]]
  if (!length(pars)) pars <- ""
  unlist(lapply(pars, function(par) {
    words <- strsplit(trimws(par), "\\s+")[[1]]
    if (!length(words)) return("")
    out <- character()
    line <- ""
    for (w in words) {
      if (nzchar(line) && nchar(paste(line, w)) > width) {
        out <- c(out, line)
        line <- w
      } else {
        line <- if (nzchar(line)) paste(line, w) else w
      }
    }
    c(out, line)
  }), use.names = FALSE)
}

# `#' ` lines wrapped at 76 columns. `tag` (e.g. "@param x") is put in front
# of `text`; its continuation lines are indented `#'   `.
rox_lines <- function(text, tag = NULL) {
  full <- if (is.null(tag)) text else paste(tag, text)
  w <- wrap_text(full)
  pre <- if (is.null(tag)) "#' " else c("#' ", rep("#'   ", max(length(w) - 1L, 0L)))
  trimws(paste0(pre[seq_along(w)], w), "right")
}

rox_paragraphs <- function(text) {
  pars <- strsplit(text, "\n\n+")[[1]]
  out <- character()
  for (p in pars) out <- c(out, if (length(out)) "#'", rox_lines(p))
  out
}

rox_body <- function(line) trimws(sub("^#'", "", line))
rox_is_blank <- function(line) !nzchar(rox_body(line))
rox_is_tag <- function(line) startsWith(rox_body(line), "@")

# Sections of a block: data frame with field, param, start, end (line range
# without the separator lines around it), and tag (the spelled tag or NA).
rox_sections <- function(block) {
  n <- length(block)
  tag_at <- which(vapply(block, rox_is_tag, logical(1)))
  head_end <- if (length(tag_at)) tag_at[1] - 1L else n
  secs <- list()
  add <- function(field, param, start, end, tag = NA_character_) {
    secs[[length(secs) + 1L]] <<- data.frame(field = field, param = param,
      start = start, end = end, tag = tag, stringsAsFactors = FALSE)
  }
  if (head_end >= 1L) {
    blank <- vapply(block[seq_len(head_end)], rox_is_blank, logical(1))
    idx <- which(!blank)
    if (length(idx)) {
      first_end <- idx[1]
      while (first_end < head_end && !blank[first_end + 1L]) first_end <- first_end + 1L
      add("title", NA_character_, idx[1], first_end)
      rest <- idx[idx > first_end]
      if (length(rest)) add("description", NA_character_, rest[1], rest[length(rest)])
    }
  }
  bounds <- c(tag_at, n + 1L)
  for (k in seq_along(tag_at)) {
    s <- bounds[k]
    e <- bounds[k + 1L] - 1L
    while (e > s && rox_is_blank(block[e])) e <- e - 1L
    m <- regmatches(rox_body(block[s]), regexec("^@(\\w+)\\s*(\\S*)", rox_body(block[s])))[[1]]
    tg <- m[2]
    field <- switch(tg, title = "title", description = "description",
      param = "param", `return` = , returns = "returns", family = "family", NA_character_)
    if (is.na(field)) field <- paste0("tag:", tg)
    add(field, if (identical(field, "param")) m[3] else NA_character_, s, e, tg)
  }
  if (length(secs)) do.call(rbind, secs) else
    data.frame(field = character(), param = character(), start = integer(),
      end = integer(), tag = character(), stringsAsFactors = FALSE)
}

rox_new_lines <- function(field, value, param, tag = NA_character_, as_tag = FALSE) {
  if (field == "title") return(if (as_tag) rox_lines(value, "@title") else rox_lines(value))
  if (field == "description") {
    return(if (as_tag) rox_lines(value, "@description") else rox_paragraphs(value))
  }
  tg <- if (!is.na(tag)) tag else switch(field, param = "param", returns = "return", family = "family")
  rox_lines(value, paste0("@", tg, if (field == "param") paste0(" ", param)))
}

rox_set <- function(block, field, value, param = NULL, formals = character()) {
  stopifnot(field %in% c("title", "description", "returns", "family", "param"))
  p <- if (is.null(param)) NA_character_ else param
  if (is.null(value) && !length(block)) return(block)
  if (!length(block)) {
    block <- if (field == "title") character() else "#' TODO: one-line title"
  }
  secs <- rox_sections(block)
  hit <- which(secs$field == field & (field != "param" | secs$param %in% p))
  n <- length(block)

  if (length(hit)) {
    s <- secs$start[hit[1]]
    e <- secs$end[hit[1]]
    if (is.null(value)) {
      # also drop one separator line next to a removed head section
      if (field %in% c("title", "description")) {
        if (s > 1L && rox_is_blank(block[s - 1L])) s <- s - 1L
        else if (e < n && rox_is_blank(block[e + 1L])) e <- e + 1L
      }
      return(block[-(s:e)])
    }
    as_tag <- !is.na(secs$tag[hit[1]]) && field %in% c("title", "description")
    new <- rox_new_lines(field, value, p, secs$tag[hit[1]], as_tag)
    return(c(block[seq_len(s - 1L)], new, block[-seq_len(e)]))
  }
  if (is.null(value)) return(block)
  new <- rox_new_lines(field, value, p)

  if (field == "title") {
    return(c(new, if (n) "#'", block))
  }
  if (field == "description") {
    t <- secs[secs$field == "title", , drop = FALSE]
    after <- if (nrow(t)) t$end[1] else 0L
    nxt <- if (after < n) block[after + 1L] else NULL
    add <- c(if (after > 0L) "#'", new)
    if (!is.null(nxt) && !rox_is_blank(nxt)) add <- c(add, "#'")
    return(append(block, add, after = after))
  }
  # tags: before the first section that sorts later (unknown tags last)
  key <- function(f, prm) {
    switch(sub(":.*", "", f),
      title = , description = 0, param = 1 + min(match(prm, formals), 998L, na.rm = TRUE) / 1000,
      returns = 2, family = 3, Inf)
  }
  mine <- key(field, p)
  later <- which(vapply(seq_len(nrow(secs)), function(i) {
    f <- secs$field[i]
    if (!startsWith(f, "tag:") && !f %in% c("param", "returns", "family")) return(FALSE)
    key(f, secs$param[i]) > mine
  }, logical(1)))
  if (length(later)) {
    at <- secs$start[later[1]] - 1L
    return(append(block, new, after = at))
  }
  at <- if (nrow(secs)) max(secs$end) else n
  sep <- if (!any(startsWith(secs$field, "tag:") | secs$field %in% c("param", "returns", "family")) &&
    n && !rox_is_blank(block[n])) "#'"
  block <- append(block, c(sep, new), after = n)
  block
}

indent_lines <- function(x, n) {
  ifelse(nzchar(x), paste0(strrep(" ", n), x), x)
}

roxygen_text <- function(fn) {
  out <- character()
  out <- c(out, rox_lines(if (length(fn$title) && nzchar(fn$title)) fn$title else "TODO: one-line title"), "#'")
  if (length(fn$description) && nzchar(fn$description)) {
    for (p in strsplit(fn$description, "\n\n+")[[1]]) out <- c(out, rox_lines(p), "#'")
  }
  for (x in fn$formals) {
    d <- fn$params[[x$name]]
    if (is.null(d) || !nzchar(d)) d <- "TODO: describe this argument."
    out <- c(out, rox_lines(d, paste("@param", x$name)))
  }
  out <- c(out, rox_lines(if (length(fn$returns) && nzchar(fn$returns)) fn$returns else "TODO: describe the result.", "@return"))
  if (length(fn$family) && nzchar(fn$family)) out <- c(out, rox_lines(fn$family, "@family"))
  for (k in fn$keywords) out <- c(out, rox_lines(k, "@keywords"))
  out
}

function_text <- function(fn) {
  nm <- if (length(fn$name) && nzchar(fn$name)) fn$name else "unnamed"
  fm <- vapply(fn$formals, function(x) {
    if (is.null(x$default) || is.na(x$default)) x$name else paste0(x$name, " = ", x$default)
  }, character(1))
  body <- if (length(fn$body) && nzchar(fn$body)) fn$body else "# TODO"
  c(roxygen_text(fn),
    paste0(nm, " <- function(", paste(fm, collapse = ", "), ") {"),
    indent_lines(strsplit(body, "\n", fixed = TRUE)[[1]], 2L),
    "}")
}

target_text <- function(name, fn, args, format = NULL, pattern = NULL) {
  arg_text <- vapply(args, function(a) {
    if (isTRUE(a$named)) paste0(a$name, " = ", a$value) else a$value
  }, character(1))
  cmd <- paste0(fn, "(", paste(arg_text, collapse = ", "), ")")
  opts <- character()
  if (!is.null(format) && !is.na(format) && nzchar(format) && format != "rds") {
    opts <- c(opts, sprintf("format = \"%s\"", format))
  }
  if (!is.null(pattern) && !is.na(pattern) && nzchar(pattern)) {
    opts <- c(opts, paste0("pattern = ", pattern))
  }
  one <- paste0("tar_target(", name, ", ", cmd,
    if (length(opts)) paste0(", ", paste(opts, collapse = ", ")), ")")
  if (nchar(one) <= 76L && !grepl("\n", cmd, fixed = TRUE)) return(one)
  c("tar_target(",
    paste0("  ", name, ","),
    indent_lines(strsplit(cmd, "\n", fixed = TRUE)[[1]], 2L) |>
      (\(l) { l[length(l)] <- paste0(l[length(l)], if (length(opts)) ","); l })(),
    if (length(opts)) paste0("  ", opts, c(rep(",", length(opts) - 1L), "")),
    ")")
}
