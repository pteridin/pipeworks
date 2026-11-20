#' Record a review verdict for an item
#'
#' Writes one JSON file to `qa/reviews/`. Commit it so the verdict travels with
#' the branch. Verdicts are only possible for committed code.
#'
#' @param item Full item id (e.g. `"function:clean_cs"`) or a unique name.
#' @param verdict `"correct"`, `"questionable"` or `"wrong"`.
#' @param comment Required for `"questionable"` and `"wrong"`.
#' @param path Project root.
#' @return The entry (a list), invisibly.
#' @export
qa_review <- function(item, verdict = c("correct", "questionable", "wrong"), comment = NULL, path = ".") {
  verdict <- match.arg(verdict)
  if (!git_available()) stop("`git` was not found on the PATH; qa_review() needs it.", call. = FALSE)
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
  write_review(path, entry)
  message("\u2714 ", row$id, ": ", verdict, " (hash ", substr(row$hash, 1, 7), ")")
  invisible(entry)
}

resolve_item <- function(item, items) {
  if (length(item) != 1 || is.na(item)) stop("`item` must be a single item id or name.", call. = FALSE)
  hit <- which(items$id == item)
  if (!length(hit)) hit <- which(items$name == item)
  if (length(hit) > 1) {
    stop("`", item, "` is ambiguous; use one of: ", paste(items$id[hit], collapse = ", "), call. = FALSE)
  }
  if (!length(hit)) {
    near <- items$id[agrepl(item, items$id, max.distance = 0.2, ignore.case = TRUE) |
                       agrepl(item, items$name, max.distance = 0.2, ignore.case = TRUE)]
    stop("Unknown item `", item, "`.",
         if (length(near)) paste0(" Close matches: ", paste(near, collapse = ", "), "."), call. = FALSE)
  }
  items[hit, , drop = FALSE]
}
