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
  # git writes UTF-8 (file contents as committed, metadata by default); mark
  # it so, whatever the session locale
  out <- as.character(out)
  Encoding(out) <- "UTF-8"
  list(
    out = out,
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

# Paths below `specs` (relative to `path`) that are modified, staged or
# untracked; `character()` when clean (or outside git).
git_dirty <- function(path, specs) {
  specs <- unique(specs[file.exists(file.path(path, specs))])
  if (!length(specs)) return(character())
  out <- git_try(path, c("status", "--porcelain", "--untracked-files=all", "--", specs))
  sub("^.. ", "", out)
}

# Uncommitted code files of the project: `R/`, `_targets.R` and the factory
# sources (`file` items) of `items`.
uncommitted_code <- function(path, items) {
  git_dirty(path, c("R", "_targets.R", items$file[items$kind == "file"]))
}

# Hash of every item (named by id) of the code tree at `commit`: all `R/**.R`,
# `_targets.R` and the factory source files `extra`, relative to `path` (which
# may be below the repo root). A version that does not parse counts as "no
# items". Cached per commit in `cache`.
git_item_hashes <- function(path, commit, extra, cache) {
  if (!is.null(cache[[commit]])) return(cache[[commit]])
  src <- tryCatch(read_source_text(git_tree_texts(path, commit, extra)), error = function(e) NULL)
  hashes <- if (is.null(src) || !nrow(src$items)) character() else stats::setNames(src$items$hash, src$items$id)
  cache[[commit]] <- hashes
  hashes
}

# Lines of the code files (and `extra` files) at `commit`, named by path.
git_tree_texts <- function(path, commit, extra = character()) {
  tree <- git_run(path, c("ls-tree", "-r", "--name-only", commit))
  keep <- tree[is_code_file(tree) | tree %in% extra]
  texts <- list()
  for (f in sort(keep)) {
    lines <- git_try(path, c("show", paste0(commit, ":./", f)))
    if (!is.null(lines)) texts[[f]] <- lines
  }
  texts
}

#' Who last changed the hash of each item
#'
#' The author of an item is the author of its *introducing commit*: the most
#' recent commit (topological order) whose version of the item has the current
#' hash while none of its parents' versions has it. Reformatting and comment
#' edits do not change a hash, so they never count; a merge commit is credited
#' only when it itself produced the hash (e.g. a conflict resolution). Versions
#' are hashed from the whole code tree at each commit. An item whose
#' working-tree hash differs from `HEAD` has uncommitted changes and gets no
#' author. Outside git, or in a repo without commits, all fields are `NA`.
#'
#' @param path Root folder of the project (may be below the repo root).
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
  head <- git_head(path)
  if (is.na(head) || !nrow(items)) return(out)

  log <- git_run(path, c("-c", "log.showSignature=false", "log", "--topo-order", "--format=%H%x1f%an%x1f%ae%x1f%P", head))
  parts <- strsplit(log, "\x1f", fixed = TRUE)
  shas <- vapply(parts, `[`, character(1), 1)
  field <- function(i) vapply(parts, function(p) if (length(p) >= i) p[i] else "", character(1))
  email <- field(3)
  meta <- list(name = field(2), email = ifelse(nzchar(email), email, NA_character_),
               parents = strsplit(field(4), " ", fixed = TRUE))
  idx <- function(sha) match(sha, shas)

  extra <- items$file[items$kind == "file"]
  cache <- new.env()
  has <- function(sha, id, hash) {
    h <- git_item_hashes(path, sha, extra, cache)
    id %in% names(h) && identical(h[[id]], hash)
  }

  for (i in seq_len(nrow(items))) {
    id <- items$id[i]
    hash <- items$hash[i]
    if (!has(head, id, hash)) next
    seen <- character()
    found <- integer()
    todo <- head
    while (length(todo)) {
      sha <- todo[1]
      todo <- todo[-1]
      if (sha %in% seen) next
      seen <- c(seen, sha)
      with_hash <- Filter(function(p) has(p, id, hash), meta$parents[[idx(sha)]])
      if (length(with_hash)) todo <- c(todo, with_hash) else found <- c(found, idx(sha))
    }
    k <- min(found)
    out$author_name[i] <- meta$name[k]
    out$author_email[i] <- meta$email[k]
    out$commit[i] <- shas[k]
  }
  out
}
