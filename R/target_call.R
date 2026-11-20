#' Describe how a target's command calls a function
#'
#' Matches the arguments of a target command such as
#' `score_histogram(raw_data, title = "Raw")` against the function's formals,
#' so every argument is known by its formal name and classified as a
#' dependency on another target, a constant, or an expression.
#'
#' @param command The target command as a string (from [targets::tar_manifest()]).
#' @param functions Function records from [read_functions()].
#' @param targets Names of all targets in the pipeline.
#' @return A list with `mode` (`"function"`, `"factory"` or `"expression"`),
#'   `fn`, `args` and, for factories, `factory` and `source`.
#' @family readers
#' @export
target_call <- function(command, functions, targets) {
  expr <- tryCatch(str2lang(command), error = function(e) NULL)
  out <- list(mode = "expression", fn = NA_character_, args = list())
  if (is.null(expr) || !is.call(expr)) return(out)

  head <- expr[[1]]
  if (is_namespaced(head, "tarchetypes")) return(factory_call(expr, head, out))
  if (!is.name(head)) return(out)
  fn <- as.character(head)
  if (is.null(functions[[fn]])) return(out)

  stub <- function_stub(functions[[fn]])
  matched <- tryCatch(match.call(stub, expr, expand.dots = FALSE), error = function(e) NULL)
  if (is.null(matched)) return(out)
  supplied <- names(as.list(expr))[-1]
  if (is.null(supplied)) supplied <- character()
  args <- as.list(matched)[-1]
  out$mode <- "function"
  out$fn <- fn
  out$args <- lapply(names(args), function(arg) classify_arg(arg, args[[arg]], arg %in% supplied, targets))
  out
}

classify_arg <- function(name, value, named, targets) {
  vars <- if (is.name(value) || is.call(value)) all.vars(value) else character()
  kind <- if (is.name(value) && as.character(value) %in% targets) {
    "target"
  } else if (!length(vars)) {
    "constant"
  } else {
    "expression"
  }
  list(
    name = name,
    value = deparse_one(value),
    kind = kind,
    named = named,
    targets = intersect(vars, targets)
  )
}

function_stub <- function(record) {
  fn <- function() NULL
  formals(fn) <- record$.expr[[2]]
  fn
}

is_namespaced <- function(x, pkg) {
  is.call(x) && identical(x[[1]], as.name("::")) && identical(as.character(x[[2]]), pkg)
}

# tar_render() and friends expand to tarchetypes::tar_*_run(path = ...).
factory_call <- function(expr, head, out) {
  out$mode <- "factory"
  out$factory <- sub("_run$", "", as.character(head[[3]]))
  path <- as.list(expr)$path
  out$source <- if (is.character(path)) path else NA_character_
  out
}
