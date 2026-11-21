# The verdict path shared by `qa_review()`, `qa_walk()` and the review server:
# validate, write the entry, commit exactly that entry.

# Same checks as `qa_review()` always had; writes the entry and, with
# `commit = TRUE`, commits it alone. A failed commit does not throw: the entry
# stays on disk and the result says why (`retry_uncommitted()` picks it up).
record_verdict <- function(path, item, verdict, comment = NULL, commit = TRUE) {
  check_project(path)
  verdict <- match.arg(verdict, c("correct", "questionable", "wrong"))
  if (!git_available()) stop("`git` was not found on the PATH; recording a verdict needs git.", call. = FALSE)
  busy <- git_busy(path)
  if (!is.na(busy)) stop("Cannot record a verdict: ", busy, ".", call. = FALSE)
  if (verdict != "correct" && (is.null(comment) || !nzchar(trimws(paste(comment, collapse = ""))))) {
    stop("A comment is required for verdict \"", verdict, "\".", call. = FALSE)
  }
  src <- read_source(path)
  items <- src$items
  row <- resolve_item(item, items)

  if (is.na(git_head(path))) stop("Commit your code first: this project has no commits yet.", call. = FALSE)
  if (!git_file_clean(path, row$file)) {
    stop("Commit ", row$file, " first: ", row$id, " has uncommitted changes.", call. = FALSE)
  }
  # An item can depend on other files (callees, map templates), so the whole
  # code tree must be committed before a verdict names a code version.
  dirty <- uncommitted_code(path, items)
  if (length(dirty)) {
    stop("Commit ", paste(dirty, collapse = ", "), " first: verdicts are only recorded for committed code, ",
         "and ", row$id, " may depend on it.", call. = FALSE)
  }

  who <- git_user(path)
  if (is.na(who$email) || is.na(who$name)) {
    stop("Your git identity is not set; verdicts are matched by email. Run `git config user.name \"Your Name\"` and `git config user.email you@example.org`.", call. = FALSE)
  }

  hashes <- stats::setNames(items$hash, items$id)
  dep_names <- if (row$kind == "function") row$calls[[1]] else if (!is.na(row$fn)) row$fn else character()
  dep_ids <- unique(paste0("function:", dep_names))
  dep_ids <- dep_ids[dep_ids %in% names(hashes)]
  depends <- if (length(dep_ids)) as.list(hashes[dep_ids]) else structure(list(), names = character())

  auth <- last_authors(path, items[items$id == row$id, , drop = FALSE])
  if (is.na(auth$author_email)) {
    stop("Cannot tell who last changed ", row$id, " from the git history, so the four-eyes rule cannot be ",
         "checked. Commit every file it depends on (and make sure git does not ignore them).", call. = FALSE)
  }
  entry <- list(
    item = row$id,
    hash = row$hash,
    verdict = verdict,
    comment = if (is.null(comment)) NA_character_ else paste(comment, collapse = "\n"),
    reviewer = who$name,
    reviewer_email = who$email,
    author = auth$author_name,
    author_email = auth$author_email,
    date = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
    commit = git_head(path),
    depends = depends
  )
  file <- write_review(path, entry)
  out <- list(entry = entry, file = file, committed = FALSE, commit = NA_character_, error = NA_character_)
  if (commit) {
    sha <- tryCatch(commit_verdict(path, file, paste("qa:", verdict, row$id)), error = function(e) e)
    if (inherits(sha, "error")) out$error <- conditionMessage(sha)
    else {
      out$committed <- TRUE
      out$commit <- sha
    }
  }
  out
}


# Entries live in `qa/reviews/` below the project; git gets the project-relative
# name (no path normalisation, which differs for files that do not exist yet).
review_rel <- function(path, file) paste0("qa/reviews/", basename(file))

# Commit only `file` (an entry below `path`) with `message`; returns the sha.
# Other staged work stays staged. Hooks run; errors carry git's message. A
# failed commit unstages the entry again, so the user's next commit does not
# sweep it in.
commit_verdict <- function(path, file, message) {
  rel <- review_rel(path, file)
  git_run(path, c("add", "--", rel))
  tryCatch(
    git_run(path, c("commit", "-q", "--only", "-m", message, "--", rel)),
    error = function(e) {
      git_try(path, c("reset", "-q", "--", rel))
      stop(conditionMessage(e), call. = FALSE)
    }
  )
  git_head(path)
}

# Why git cannot take a commit right now ("merge in progress", ...), else NA.
git_busy <- function(path) {
  dir <- git_try(path, c("rev-parse", "--git-dir"))
  if (!length(dir)) return(NA_character_)
  dir <- dir[1]
  if (!grepl("^(/|[A-Za-z]:)", dir)) dir <- file.path(path, dir)
  marks <- c(
    "merge in progress" = "MERGE_HEAD",
    "rebase in progress" = "rebase-merge",
    "rebase in progress" = "rebase-apply",
    "cherry-pick in progress" = "CHERRY_PICK_HEAD",
    "index.lock present" = "index.lock"
  )
  hit <- file.exists(file.path(dir, marks))
  if (any(hit)) names(marks)[hit][1] else NA_character_
}

# Review entry files (full paths, like `write_review()`) that are added,
# modified or untracked; never deletions or renames.
uncommitted_reviews <- function(path) {
  opts <- c("-c", "core.quotepath=off")
  new <- git_try(path, c(opts, "ls-files", "--others", "--exclude-standard", "--", "qa/reviews"))
  changed <- git_try(path, c(opts, "diff", "--name-only", "--no-renames", "--diff-filter=AM", "--relative", "HEAD", "--", "qa/reviews"))
  rel <- sort(unique(c(new, changed)))
  rel <- rel[grepl("\\.json$", rel)]
  if (length(rel)) file.path(path, rel) else character()
}

# Commit every uncommitted entry, one commit each.
retry_uncommitted <- function(path) {
  busy <- git_busy(path)
  if (!is.na(busy)) stop("Cannot commit verdicts: ", busy, ".", call. = FALSE)
  files <- uncommitted_reviews(path)
  error <- rep(NA_character_, length(files))
  for (i in seq_along(files)) {
    entry <- tryCatch(jsonlite::read_json(files[i]), error = function(e) NULL)
    msg <- if (is.null(entry)) paste("qa: review", basename(files[i])) else paste("qa:", entry$verdict, entry$item)
    r <- tryCatch(commit_verdict(path, files[i], msg), error = function(e) e)
    if (inherits(r, "error")) error[i] <- conditionMessage(r)
  }
  data.frame(file = files, committed = is.na(error), error = error, stringsAsFactors = FALSE)
}
