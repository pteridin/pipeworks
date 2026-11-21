# Fail early with a readable message when `path` is not a project folder,
# e.g. when a function such as `q` or `c` was passed instead of a variable.
check_project <- function(path, arg = "path") {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    got <- if (is.function(path)) {
      "a function (is the variable name a typo? `q`, `c` and `t` are R functions)"
    } else {
      paste0("an object of class ", class(path)[1], " with length ", length(path))
    }
    stop(sprintf("`%s` must be the folder of a targets project as one string, but it is %s.", arg, got),
         call. = FALSE)
  }
  if (!dir.exists(path)) {
    stop(sprintf("`%s` is not an existing folder: %s", arg, path), call. = FALSE)
  }
  invisible(path)
}
