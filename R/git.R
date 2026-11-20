# Git layer: authorship for the QA engine. Everything goes through
# `system2("git", ...)`; nothing here runs pipeline code.

git_available <- function() nzchar(Sys.which("git"))

# Run git in `path`. Returns stdout lines; stops with git's message on failure.
git_run <- function(path, args) {
  if (!git_available()) stop("`git` was not found on the PATH.", call. = FALSE)
  res <- git_exec(path, args)
  if (res$status != 0) {
    msg <- trimws(paste(c(res$err, res$out), collapse = "\n"))
    stop("git ", paste(args, collapse = " "), " failed: ", msg, call. = FALSE)
  }
  res$out
}

git_exec <- function(path, args) {
  err <- tempfile("git-err-")
  on.exit(unlink(err), add = TRUE)
  out <- tryCatch(
    suppressWarnings(system2("git", c("-C", shQuote(path), shQuote(args)), stdout = TRUE, stderr = err)),
    error = function(e) structure(character(), status = 1L)
  )
  status <- attr(out, "status")
  list(
    out = enc2utf8(as.character(out)),
    err = if (file.exists(err)) readLines(err, warn = FALSE) else character(),
    status = if (is.null(status)) 0L else status
  )
}

# Like `git_run()`, but NULL instead of an error (also without git or repo).
git_try <- function(path, args) {
  if (!git_available() || !dir.exists(path)) return(NULL)
  res <- git_exec(path, args)
  if (res$status != 0) NULL else res$out
}

git_user <- function(path) {
  one <- function(key) {
    v <- git_try(path, c("config", key))
    if (length(v) && nzchar(v[1])) v[1] else NA_character_
  }
  list(name = one("user.name"), email = one("user.email"))
}

git_head <- function(path) {
  v <- git_try(path, c("rev-parse", "--verify", "--quiet", "HEAD"))
  if (length(v) && nzchar(v[1])) v[1] else NA_character_
}

# TRUE only if `file` is tracked and has no staged or unstaged change.
git_file_clean <- function(path, file) {
  if (is.null(git_try(path, c("ls-files", "--error-unmatch", "--", file)))) return(FALSE)
  st <- git_try(path, c("status", "--porcelain", "--", file))
  !is.null(st) && length(st) == 0
}

# Hash of every item of `file` as of `commit` (named by id); an old version
# that does not parse counts as "no items".
git_item_hashes <- function(path, commit, file) {
  lines <- git_try(path, c("show", paste0(commit, ":", file)))
  if (is.null(lines)) return(character())
  src <- tryCatch(read_source_text(stats::setNames(list(lines), file)), error = function(e) NULL)
  if (is.null(src) || !nrow(src$items)) return(character())
  stats::setNames(src$items$hash, src$items$id)
}

#' Who last changed the hash of each item
#'
#' For every item, the most recent commit in which its hash changed (or in
#' which it appeared), so reformatting and comment edits do not count. An item
#' whose working-tree hash differs from `HEAD` has uncommitted changes and gets
#' no author. Outside git, or in a repo without commits, all fields are `NA`.
#'
#' @param path Root folder of the project.
#' @param items The `items` data frame of `read_source()`.
#' @return A data frame with `id`, `author_name`, `author_email`, `commit`.
#' @noRd
last_authors <- function(path, items) {
  out <- data.frame(
    id = items$id,
    author_name = rep(NA_character_, nrow(items)),
    author_email = rep(NA_character_, nrow(items)),
    commit = rep(NA_character_, nrow(items)),
    stringsAsFactors = FALSE
  )
  if (is.na(git_head(path)) || !nrow(items)) return(out)

  for (f in unique(items$file)) {
    log <- git_try(path, c("log", "--format=%H%x1f%an%x1f%ae", "--", f))
    if (!length(log)) next
    parts <- strsplit(log, "\x1f", fixed = TRUE)
    commits <- vapply(parts, `[`, character(1), 1)
    names_ <- vapply(parts, function(p) if (length(p) >= 2) p[2] else NA_character_, character(1))
    emails <- vapply(parts, function(p) if (length(p) >= 3) p[3] else NA_character_, character(1))
    # Newest first; the version before the oldest commit has no items.
    versions <- lapply(commits, function(cm) git_item_hashes(path, cm, f))
    versions[[length(versions) + 1]] <- character()

    for (i in which(items$file == f)) {
      id <- items$id[i]
      cur <- vapply(versions, function(v) if (id %in% names(v)) v[[id]] else NA_character_, character(1))
      if (is.na(cur[1]) || cur[1] != items$hash[i]) next
      # Newest commit whose version differs from the next older one.
      k <- which(is.na(cur[-length(cur)]) != is.na(cur[-1]) |
        (!is.na(cur[-length(cur)]) & !is.na(cur[-1]) & cur[-length(cur)] != cur[-1]))
      if (!length(k)) next
      k <- k[1]
      out$author_name[i] <- names_[k]
      out$author_email[i] <- emails[k]
      out$commit[i] <- commits[k]
    }
  }
  out
}
