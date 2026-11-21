#' Record a review verdict for an item
#'
#' Writes one JSON file to `qa/reviews/` and commits it right away, alone (one
#' commit per verdict; other staged work stays staged). Verdicts are only possible for committed code: every code file
#' (`R/`, `_targets.R`, report sources) must be committed, and the item's last
#' author must be known from the git history.
#'
#' @param item Full item id (e.g. `"function:clean_cs"`) or a unique name.
#' @param verdict `"correct"`, `"questionable"` or `"wrong"`.
#' @param comment Required for `"questionable"` and `"wrong"`.
#' @param path Project root.
#' @param commit If `FALSE`, only write the entry and leave committing to you.
#' @return The entry (a list), invisibly.
#' @export
qa_review <- function(item, verdict = c("correct", "questionable", "wrong"), comment = NULL, path = ".", commit = TRUE) {
  verdict <- match.arg(verdict)
  res <- record_verdict(path, item, verdict, comment, commit = commit)
  if (!isTRUE(res$committed) && commit) {
    stop("The verdict was saved to ", res$file, " but not committed: ", res$error, call. = FALSE)
  }
  entry <- res$entry
  message("\u2714 ", entry$item, ": ", verdict, " (hash ", substr(entry$hash, 1, 7), ")",
          if (isTRUE(res$committed)) paste0(", committed ", substr(res$commit, 1, 7)))
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
