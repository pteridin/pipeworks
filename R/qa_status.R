# Status table and CI gate: the static source model combined with the review
# ledger. Nothing here runs pipeline code.

status_levels <- c("unreviewed", "changed", "check_again", "correct", "questionable", "wrong")

#' Review status of every item
#'
#' Combines the static source model with the review ledger. For each item the
#' latest entry decides: no entry is `unreviewed`; a different hash is
#' `changed`; a matching hash gives the recorded verdict, except that a
#' `correct` verdict whose recorded callee hashes (`depends`) no longer match is
#' `check_again` (a hint, not a reset). `self_reviewed` flags a matching entry
#' whose reviewer is the person who wrote the code (compared by the emails
#' stored in the entry, case-insensitively and mapped through `qa/people`); it
#' is `NA` ("authorship unknown") when the entry lacks either email.
#'
#' An item is *done* when it passes [qa_check()]: `correct`, `check_again` or
#' (when allowed) `questionable`, reviewed by someone other than its last
#' author, with both known.
#'
#' @param path Project root.
#' @param base Optional git ref (e.g. `"main"`). Adds `changed_vs_base`: whether
#'   the item's hash differs from (or is missing at) that ref.
#' @param orphans If `TRUE`, return the review entries whose item no longer
#'   exists instead.
#' @param authors If `FALSE`, skip reading the git history: `last_author` then
#'   comes from the matching review entry only (`NA` for unreviewed or changed
#'   items). The status itself never needs the history.
#' @return A data frame of class `pipeworks_qa_status`. Its attribute
#'   `external` lists calls that load code from outside `R/` and `_targets.R`
#'   (`source()`, `sys.source()`, `tar_source()` of another folder): code
#'   pipeworks cannot review, which makes [qa_check()] fail.
#' @export
qa_status <- function(path = ".", base = NULL, orphans = FALSE, authors = TRUE) {
  src <- read_source(path)
  items <- src$items
  reviews <- read_reviews(path)

  if (isTRUE(orphans)) return(reviews[!(reviews$item %in% items$id), , drop = FALSE])

  people <- read_people(path)
  hashes <- stats::setNames(items$hash, items$id)
  n <- nrow(items)

  pick <- vapply(items$id, function(id) {
    hit <- which(reviews$item == id)
    if (length(hit)) hit[length(hit)] else NA_integer_
  }, integer(1))
  e <- reviews[pick, , drop = FALSE]
  has_entry <- !is.na(pick)
  matches <- has_entry & !is.na(e$hash) & e$hash == items$hash

  stale_dep <- vapply(seq_len(n), function(i) {
    if (!matches[i]) return(FALSE)
    d <- e$depends[[i]]
    length(d) > 0 && any(vapply(names(d), function(k) !(k %in% names(hashes)) || hashes[[k]] != d[[k]], logical(1)))
  }, logical(1))

  status <- ifelse(!has_entry, "unreviewed",
            ifelse(!matches, "changed",
            ifelse(stale_dep & e$verdict == "correct", "check_again", e$verdict)))

  # NA when the entry cannot tell (missing reviewer or author email): fails closed
  self_reviewed <- rep(FALSE, n)
  self_reviewed[matches] <- person_of(e$reviewer_email[matches], people) == person_of(e$author_email[matches], people)

  # last author: from the matching entry when reviewed, else from git
  last_author <- ifelse(matches, e$author, NA_character_)
  need <- !matches
  if (isTRUE(authors) && any(need)) {
    la <- last_authors(path, items[need, , drop = FALSE])
    last_author[need] <- la$author_name
  }

  changed_vs_base <- rep(NA, n)
  if (!is.null(base)) {
    if (!git_available()) stop("`base` needs git, which was not found on the PATH.", call. = FALSE)
    if (is.null(git_try(path, c("rev-parse", "--verify", "--quiet", paste0(base, "^{commit}"))))) {
      stop("Cannot resolve `base` ref `", base, "` (is this a git repository with that ref?).", call. = FALSE)
    }
    old <- git_item_hashes(path, base, items$file[items$kind == "file"], new.env())
    changed_vs_base <- is.na(match(items$id, names(old))) | old[match(items$id, names(old))] != items$hash
    changed_vs_base[is.na(changed_vs_base)] <- TRUE
  }

  out <- items
  out$status <- status
  out$self_reviewed <- self_reviewed
  out$reviewer <- ifelse(has_entry, e$reviewer, NA_character_)
  out$date <- ifelse(has_entry, e$date, NA_character_)
  out$comment <- ifelse(has_entry, e$comment, NA_character_)
  out$last_author <- last_author
  out$changed_vs_base <- changed_vs_base
  rownames(out) <- NULL
  attr(out, "external") <- src$external
  class(out) <- c("pipeworks_qa_status", "data.frame")
  out
}

#' @export
print.pipeworks_qa_status <- function(x, ...) {
  counts <- table(factor(x$status, levels = status_levels))
  cat("QA status: ", nrow(x), " items, ", sum(qa_passing(x)), " done\n", sep = "")
  cat(paste0("  ", format(names(counts)), "  ", counts, collapse = "\n"), "\n", sep = "")
  if (any(x$self_reviewed %in% TRUE)) cat("  self-reviewed: ", sum(x$self_reviewed %in% TRUE), "\n", sep = "")
  if (anyNA(x$self_reviewed)) cat("  authorship unknown: ", sum(is.na(x$self_reviewed)), "\n", sep = "")
  show <- function(title, rows) {
    if (!any(rows)) return()
    cat("\n", title, ":\n", sep = "")
    cat(sprintf("  %-12s %s%s", x$status[rows], x$id[rows], who_note(x$self_reviewed[rows])), sep = "\n")
  }
  pass <- qa_passing(x)
  show("Not passing", !pass)
  show("Check again (passes)", pass & x$status == "check_again")
  show("Questionable (passes, with doubt)", pass & x$status == "questionable")
  ext <- attr(x, "external")
  if (!is.null(ext) && nrow(ext)) {
    cat("\nWarning:\n")
    cat(paste0("  ", external_messages(ext)), sep = "\n")
  }
  invisible(x)
}

# " (self-reviewed)", " (authorship unknown)" or "" per item.
who_note <- function(self_reviewed) {
  ifelse(is.na(self_reviewed), " (authorship unknown)", ifelse(self_reviewed, " (self-reviewed)", ""))
}

# The one definition of "done": the item passes `qa_check()`.
qa_passing <- function(st, allow_questionable = TRUE) {
  st$status %in% c("correct", "check_again", if (allow_questionable) "questionable") & st$self_reviewed %in% FALSE
}

#' CI gate: fail while items are not properly reviewed
#'
#' Passes only if every item is `correct` (or `questionable`, when allowed),
#' none is self-reviewed and every reviewed item's authorship is known, and no
#' code is loaded from outside `R/` and `_targets.R`. `check_again` items are
#' listed but never fail. The check never needs the git history.
#'
#' @param path Project root.
#' @param allow_questionable Whether `questionable` verdicts pass.
#' @return The status table, invisibly. Signals an error on failure.
#' @export
qa_check <- function(path = ".", allow_questionable = TRUE) {
  st <- qa_status(path, authors = FALSE)
  s <- as.character(st$status)
  bad <- list(
    unreviewed = s == "unreviewed",
    changed = s == "changed",
    wrong = s == "wrong",
    questionable = if (allow_questionable) rep(FALSE, length(s)) else s == "questionable",
    `self-reviewed` = st$self_reviewed %in% TRUE,
    `authorship unknown` = is.na(st$self_reviewed)
  )
  counts <- vapply(bad, sum, integer(1))
  ext <- attr(st, "external")
  again <- st$id[s == "check_again"]
  if (length(again)) {
    message("Note: callees changed since review, check again: ", paste(again, collapse = ", "))
  }
  failing <- !qa_passing(st, allow_questionable)
  if (any(failing) || nrow(ext)) {
    note <- ifelse(is.na(st$self_reviewed), ", authorship unknown", ifelse(st$self_reviewed, ", self-reviewed", ""))
    lines <- sprintf("  %s%s: %s", s, note, st$id)[failing]
    counts <- c(counts, `unreviewable code source` = nrow(ext))
    stop("QA check failed: ", paste(counts[counts > 0], names(counts)[counts > 0], collapse = ", "),
         "\n", paste(c(paste0("  ", external_messages(ext)), lines), collapse = "\n"), call. = FALSE)
  }
  message("\u2714 QA check passed: ", nrow(st), " items reviewed")
  invisible(st)
}
