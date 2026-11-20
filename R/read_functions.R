#' Read the documented functions of a targets project
#'
#' Parses every `.R` file in the project's `R/` folder and returns one record
#' per top-level function definition (`name <- function(...)`), combined with
#' its roxygen block if it has one. Nothing is sourced or evaluated.
#'
#' @param path Root folder of the targets project.
#' @return A named list with one element per function. Each element is a list
#'   with the source location (`file`, `doc_line`, `line`, `end_line`), the
#'   roxygen fields (`title`, `description`, `params`, `returns`, `family`,
#'   `keywords`), the `formals` and the `body` text.
#' @family readers
#' @export
read_functions <- function(path = ".") {
  dir <- file.path(path, "R")
  files <- sort(list.files(dir, pattern = "\\.[Rr]$", full.names = TRUE))
  fns <- unlist(lapply(files, read_functions_file, root = path), recursive = FALSE)
  if (is.null(fns)) fns <- list()
  link_function_calls(fns)
}

read_functions_file <- function(file, root) {
  rel <- file.path("R", basename(file))
  lines <- readLines(file, warn = FALSE, encoding = "UTF-8")
  exprs <- parse(file, keep.source = TRUE, encoding = "UTF-8")
  refs <- attr(exprs, "srcref")
  defs <- list()
  for (i in seq_along(exprs)) {
    e <- exprs[[i]]
    if (!is_function_assignment(e)) next
    name <- as.character(e[[2]])
    ref <- refs[[i]]
    defs[[name]] <- new_function_record(name, rel, e[[3]], lines, ref[[1]], ref[[3]])
  }
  blocks <- roxygen2::parse_file(file, env = NULL)
  for (block in blocks) {
    if (!is_function_assignment(block$call)) next
    name <- as.character(block$call[[2]])
    if (is.null(defs[[name]])) next
    defs[[name]] <- add_roxygen(defs[[name]], block)
  }
  defs
}

is_function_assignment <- function(e) {
  is.call(e) &&
    (identical(e[[1]], as.name("<-")) || identical(e[[1]], as.name("="))) &&
    is.name(e[[2]]) &&
    is.call(e[[3]]) &&
    identical(e[[3]][[1]], as.name("function"))
}

new_function_record <- function(name, file, fn_expr, lines, start, end) {
  formals <- as.list(fn_expr[[2]])
  list(
    name = name,
    file = file,
    doc_line = start,
    line = start,
    end_line = end,
    title = NA_character_,
    description = NA_character_,
    params = list(),
    returns = NA_character_,
    family = NA_character_,
    keywords = character(),
    formals = lapply(seq_along(formals), function(i) {
      # A formal without default is the empty symbol, which cannot be bound to a variable.
      empty <- identical(formals[[i]], quote(expr = ))
      list(name = names(formals)[i], default = if (empty) NA_character_ else deparse_one(formals[[i]]))
    }),
    body = function_body_text(lines[start:end]),
    calls = character(),
    called_by = character(),
    .expr = fn_expr
  )
}

add_roxygen <- function(record, block) {
  tags <- block$tags
  value <- function(tag) {
    hits <- Filter(function(t) identical(t$tag, tag), tags)
    if (length(hits)) paste(unlist(lapply(hits, `[[`, "val")), collapse = "\n\n") else NA_character_
  }
  record$doc_line <- min(vapply(tags, function(t) as.integer(t$line), integer(1)), record$line)
  record$title <- value("title")
  record$description <- value("description")
  record$returns <- value("return")
  record$family <- value("family")
  kw <- value("keywords")
  record$keywords <- if (is.na(kw)) character() else strsplit(kw, "\\s+")[[1]]
  params <- Filter(function(t) identical(t$tag, "param"), tags)
  record$params <- stats::setNames(
    lapply(params, function(t) t$val$description),
    vapply(params, function(t) t$val$name, character(1))
  )
  record
}

# Body between `function(...) {` and the closing `}`, dedented. Falls back to
# the whole definition when the function does not use that layout.
function_body_text <- function(src) {
  n <- length(src)
  if (n >= 2 && grepl("\\{\\s*$", src[1]) && grepl("^\\s*\\}\\s*$", src[n])) {
    body <- src[-c(1, n)]
    indent <- min(c(nchar(sub("\\S.*$", "", body[nzchar(trimws(body))])), Inf))
    if (is.finite(indent) && indent > 0) body <- substring(body, indent + 1)
    return(paste(body, collapse = "\n"))
  }
  paste(src, collapse = "\n")
}

link_function_calls <- function(fns) {
  names_all <- names(fns)
  for (name in names_all) {
    used <- intersect(all.names(fns[[name]]$.expr[[3]]), setdiff(names_all, name))
    fns[[name]]$calls <- used
    for (callee in used) fns[[callee]]$called_by <- c(fns[[callee]]$called_by, name)
  }
  fns
}

deparse_one <- function(x) paste(deparse(x, width.cutoff = 500L), collapse = " ")
