# Review ledger: one JSON file per verdict in `qa/reviews/`, never edited
# after writing, so branches merge without conflicts.

review_fields <- c("item", "hash", "verdict", "comment", "reviewer", "reviewer_email",
                   "author", "author_email", "date", "commit")

empty_reviews <- function() {
  out <- data.frame(
    item = character(), hash = character(), verdict = character(), comment = character(),
    reviewer = character(), reviewer_email = character(), author = character(),
    author_email = character(), date = character(), commit = character(),
    stringsAsFactors = FALSE
  )
  out$depends <- list()
  out
}

#' Read all review entries of a project
#' @param path Project root.
#' @return Data frame sorted by `date` (then by file-name suffix), zero rows without `qa/reviews/`.
#' @noRd
read_reviews <- function(path = ".") {
  files <- list.files(file.path(path, "qa", "reviews"), pattern = "\\.json$", full.names = TRUE)
  if (!length(files)) return(empty_reviews())
  str1 <- function(x) if (is.null(x) || !length(x) || is.na(x[[1]])) NA_character_ else as.character(x[[1]])
  # ties on date (never-overwrite suffixes): order by file stem first, then below
  files <- files[order(sub("\\.json$", "", basename(files)), method = "radix")]
  rows <- lapply(files, function(f) {
    e <- jsonlite::fromJSON(f, simplifyVector = FALSE)
    row <- as.data.frame(lapply(stats::setNames(review_fields, review_fields), function(k) str1(e[[k]])),
                         stringsAsFactors = FALSE)
    dep <- e$depends
    row$depends <- list(if (is.null(dep) || !length(dep)) stats::setNames(list(), character()) else lapply(dep, as.character))
    row
  })
  out <- do.call(rbind, rows)
  # date (second-resolution entries get ".000"), then the numeric `-N` suffix
  # of the file name, so "x" < "x-2" < "x-10"
  stems <- sub("\\.json$", "", basename(files))
  suffix <- vapply(stems, function(s) {
    if (grepl("-[0-9a-f]{7}-[0-9]+$", s)) as.integer(sub(".*-([0-9]+)$", "\\1", s)) else 1L
  }, integer(1), USE.NAMES = FALSE)
  day <- ifelse(is.na(out$date), "", sub("Z$", "", out$date))
  day <- ifelse(grepl("\\.", day), day, ifelse(nzchar(day), paste0(day, ".000"), day))
  out <- out[order(day, suffix, method = "radix"), , drop = FALSE]
  rownames(out) <- NULL
  out
}

#' Write one review entry as a JSON file
#' @param entry Named list with the fields of a review entry.
#' @return The file path.
#' @noRd
write_review <- function(path, entry) {
  dir <- file.path(path, "qa", "reviews")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  # "2026-11-20T10:00:00.123Z" -> "20261120T100000123Z" (also for old second-resolution dates)
  stamp <- gsub("[-:.]", "", entry$date)
  slug <- gsub("[^A-Za-z0-9]", "_", entry$item)
  base <- sprintf("%s-%s-%s", stamp, slug, substr(entry$hash, 1, 7))
  file <- file.path(dir, paste0(base, ".json"))
  n <- 1
  while (file.exists(file)) {
    n <- n + 1
    file <- file.path(dir, sprintf("%s-%d.json", base, n))
  }
  if (is.null(entry$depends) || !length(entry$depends)) {
    entry$depends <- structure(list(), names = character())
  }
  json <- jsonlite::toJSON(entry, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
  con <- file(file, "wb")
  on.exit(close(con))
  writeBin(charToRaw(enc2utf8(paste0(json, "\n"))), con)
  file
}

#' Read `qa/people`: DCF records with `Name:` and `Emails:` (comma separated)
#' @return Data frame `email` (lower case), `person`.
#' @noRd
read_people <- function(path = ".") {
  file <- file.path(path, "qa", "people")
  none <- data.frame(email = character(), person = character(), stringsAsFactors = FALSE)
  if (!file.exists(file)) return(none)
  d <- read.dcf(file, fields = c("Name", "Emails"))
  rows <- lapply(seq_len(nrow(d)), function(i) {
    emails <- trimws(strsplit(if (is.na(d[i, "Emails"])) "" else d[i, "Emails"], ",", fixed = TRUE)[[1]])
    emails <- emails[nzchar(emails)]
    if (is.na(d[i, "Name"]) || !length(emails)) return(NULL)
    data.frame(email = tolower(emails), person = unname(d[i, "Name"]), stringsAsFactors = FALSE)
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows)) do.call(rbind, rows) else none
}

#' Person name for an email (the lower-case email itself when unmapped, so
#' `Ann@X.org` and `ann@x.org` are the same person; `NA` stays `NA`)
#' @noRd
person_of <- function(email, people) {
  email <- tolower(email)
  hit <- people$person[match(email, people$email)]
  ifelse(is.na(hit), email, hit)
}
