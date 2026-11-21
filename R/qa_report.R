# QA report: a PDF (Quarto + Typst) for the client. It never states more than
# the review ledger supports: while `qa_check()` fails it is a marked draft.

#' Render the QA report as a PDF
#'
#' Summarises the review state of the code (cover with counts, findings per
#' block, review history) with Quarto and Typst. While the QA check fails the
#' report is a clearly marked draft that lists the open items instead of
#' confirming the review.
#'
#' @param path Project root.
#' @param ref Optional git ref (branch, tag, commit) to report instead of the
#'   working tree. It is checked out into a temporary worktree that is removed
#'   afterwards.
#' @param output Path of the PDF.
#' @param signatures If `TRUE`, add signature lines for analyst and reviewer;
#'   otherwise the report states that it is valid without signature.
#' @param final If `TRUE`, refuse to render unless `qa_check()` passes.
#' @param title Report title.
#'
#' The organisation line of the cover comes from
#' `getOption("pipeworks.organisation")` and is omitted when unset.
#' @return The output path, invisibly.
#' @export
qa_report <- function(path = ".", ref = NULL, output = "qa-report.pdf", signatures = FALSE,
                      final = FALSE, title = NULL) {
  check_project(path)
  if (!nzchar(Sys.which("quarto"))) {
    stop("Quarto is needed to render the QA report (https://quarto.org/docs/get-started/); ",
         "it was not found on the PATH.", call. = FALSE)
  }
  project <- basename(normalizePath(path, mustWork = TRUE))
  root <- path
  if (!is.null(ref)) {
    wt <- local_worktree(path, ref)
    withr::defer(remove_worktree(path, wt$dir))
    root <- wt$project
  }
  if (isTRUE(final)) suppressMessages(qa_check(root))
  data <- report_data(root, ref = ref, signatures = signatures, title = title, project = project)
  if (isTRUE(final) && isTRUE(data$dirty)) {
    stop("Commit your changes first: the working copy has uncommitted changes in code or review entries, ",
         "so a final report cannot name a code version.", call. = FALSE)
  }
  if (isTRUE(final) && data$counts$items == 0) {
    stop("The project has no reviewable items; a final report cannot confirm a review of nothing.", call. = FALSE)
  }

  work <- withr::local_tempdir()
  template <- system.file("report", "qa-report.qmd", package = "pipeworks")
  if (!nzchar(template)) stop("The report template was not found in the pipeworks installation.", call. = FALSE)
  file.copy(template, file.path(work, "qa-report.qmd"))
  writeLines(jsonlite::toJSON(data, auto_unbox = TRUE, null = "null", na = "null", pretty = TRUE),
             file.path(work, "qa-data.json"), useBytes = TRUE)

  log <- withr::with_dir(work, system2(
    "quarto", c("render", "qa-report.qmd", "--to", "typst"), stdout = TRUE, stderr = TRUE
  ))
  pdf <- file.path(work, "qa-report.pdf")
  if (!file.exists(pdf)) {
    stop("Quarto could not render the QA report:\n", paste(utils::tail(log, 20), collapse = "\n"), call. = FALSE)
  }
  dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
  if (!isTRUE(suppressWarnings(file.copy(pdf, output, overwrite = TRUE)))) {
    stop("Could not write the QA report to `", output, "`.", call. = FALSE)
  }
  invisible(output)
}

# Check `ref` out into a temporary detached worktree. Returns the worktree
# `dir` and `project`, the project folder inside it (the project may sit below
# the repository root).
local_worktree <- function(path, ref) {
  top <- git_run(path, c("rev-parse", "--show-toplevel"))[1]
  prefix <- git_run(path, c("rev-parse", "--show-prefix"))
  dir <- tempfile("pipeworks-worktree-")
  git_run(path, c("worktree", "add", "--detach", dir, ref))
  project <- if (length(prefix) && nzchar(prefix[1])) file.path(dir, prefix[1]) else dir
  list(dir = dir, project = project, top = top)
}

remove_worktree <- function(path, dir) {
  git_try(path, c("worktree", "remove", "--force", dir))
  unlink(dir, recursive = TRUE)
  git_try(path, c("worktree", "prune"))
  invisible()
}

#' Everything the report template shows, as a list
#' @noRd
report_data <- function(path = ".", ref = NULL, signatures = FALSE, title = NULL,
                        project = basename(normalizePath(path, mustWork = TRUE))) {
  # the check itself, without the git history (see qa_check())
  st <- qa_status(path, authors = FALSE)
  ext <- attr(st, "external")
  pass <- qa_passing(st)
  check_ok <- all(pass) && !nrow(ext)
  dirty <- is.null(ref) && has_uncommitted(path, st)
  empty <- nrow(st) == 0
  passed <- check_ok && !dirty && !empty
  reason <- if (passed) "none" else if (dirty) "uncommitted" else if (empty) "empty"
    else if (nrow(ext)) "external" else "open"

  verdict <- as.character(st$status)
  verdict[st$self_reviewed %in% TRUE] <- "self_reviewed"
  verdict[is.na(st$self_reviewed)] <- "authorship_unknown"
  counts <- list(
    items = nrow(st),
    correct = sum(pass & st$status %in% c("correct", "check_again")),
    questionable = sum(pass & st$status == "questionable"),
    wrong_open = sum(!pass)
  )

  commit <- git_head(path)
  branch <- git_try(path, c("rev-parse", "--abbrev-ref", "HEAD"))
  ref_label <- if (!is.null(ref)) ref else if (length(branch) && branch[1] != "HEAD") branch[1] else NA_character_

  version <- if (is.na(commit)) "not under version control"
    else if (dirty) paste0("Working copy with uncommitted changes (based on commit ", substr(commit, 1, 7), ")")
    else paste0(if (!is.na(ref_label)) ref_label else "detached HEAD", " \u00b7 commit ", substr(commit, 1, 7))
  if (is.na(commit) && dirty) version <- "Working copy with uncommitted changes"

  na_to_null <- function(x) if (length(x) && !is.na(x)) x else NULL
  distinct <- function(x) as.list(sort(unique(x[!is.na(x)])))
  items_of <- function(rows) lapply(seq_len(nrow(rows)), function(i) list(
    id = rows$id[i], kind = rows$kind[i],
    title = if (is.na(rows$title[i])) "" else rows$title[i],
    verdict = rows$verdict[i], reviewer = na_to_null(rows$reviewer[i]),
    date = na_to_null(substr(rows$date[i], 1, 10)), hash7 = substr(rows$hash[i], 1, 7),
    comment = na_to_null(rows$comment[i])
  ))
  st$verdict <- verdict
  stale <- verdict %in% c("changed", "unreviewed")
  st$reviewer[stale] <- NA_character_
  st$date[stale] <- NA_character_
  st$comment[stale] <- NA_character_
  blocks <- lapply(unique(st$block), function(b) list(block = b, items = items_of(st[st$block == b, , drop = FALSE])))
  edges <- block_edges(path, st)

  list(
    project = project,
    title = if (is.null(title)) "QA report" else title,
    organisation = na_to_null(getOption("pipeworks.organisation", NA_character_)),
    ref = na_to_null(ref_label),
    version = version,
    dirty = dirty,
    draft_reason = reason,
    commit = if (is.na(commit)) NULL else substr(commit, 1, 7),
    date = format(Sys.Date()),
    # from the review entries; complete only when every item is reviewed
    analysts = distinct(st$last_author),
    analysts_complete = all(pass),
    scope = report_scope(st),
    external = as.list(unique(ext$path)),
    reviewers = distinct(st$reviewer),
    counts = counts,
    passed = passed,
    signatures = isTRUE(signatures),
    blocks = blocks,
    edges = edges,
    levels = block_levels(vapply(blocks, `[[`, "", "block"), edges),
    open = lapply(which(!pass), function(i) list(
      id = st$id[i], verdict = verdict[i], block = st$block[i]
    )),
    history = review_history(path)
  )
}

# "Scope: ..." line of the cover: what the review covers, exactly.
report_scope <- function(st) {
  sources <- sort(unique(st$file[st$kind == "file"]))
  paste0(
    "Scope: all R code in R/ and _targets.R",
    if (length(sources)) paste0(" and the report sources (", paste(sources, collapse = ", "), ")"),
    ". Data files are not reviewed."
  )
}

# TRUE if code, review entries or factory sources under `path` differ from HEAD
# (modified, staged or untracked). Output files elsewhere in the project do not count.
has_uncommitted <- function(path, st) {
  if (is.na(git_head(path))) return(FALSE)
  length(git_dirty(path, c("R", "_targets.R", "qa", st$file[st$kind == "file"]))) > 0
}

# Block-level dependencies `from -> to` (the block that is used, the block that
# uses it): a function calls a function, a target runs a function, a target
# mentions another target. Recovered from the source text, nothing is run.
block_edges <- function(path, st) {
  block_of <- stats::setNames(st$block, st$name)
  fn_block <- block_of[st$kind == "function"]
  tg_block <- block_of[st$kind == "target"]
  pairs <- list()
  add <- function(from, to) if (!is.na(from) && !is.na(to) && from != to) pairs[[length(pairs) + 1L]] <<- c(from, to)
  for (i in which(st$kind == "function")) {
    for (cl in st$calls[[i]]) add(fn_block[cl], st$block[i])
  }
  for (i in which(st$kind == "target")) {
    if (!is.na(st$fn[i])) add(fn_block[st$fn[i]], st$block[i])
    lines <- tryCatch(readLines(file.path(path, st$file[i]), warn = FALSE, encoding = "UTF-8")[st$line1[i]:st$line2[i]],
                      error = function(e) character())
    used <- tryCatch(all.names(parse(text = lines, keep.source = FALSE)), error = function(e) character())
    for (t in setdiff(intersect(used, names(tg_block)), st$name[i])) add(tg_block[t], st$block[i])
  }
  pairs <- unique(pairs)
  lapply(pairs, function(p) list(from = unname(p[1]), to = unname(p[2])))
}

# Column for each block in the diagram: the longest chain of blocks it depends on.
block_levels <- function(blocks, edges) {
  level <- stats::setNames(rep(0L, length(blocks)), blocks)
  for (round in seq_along(blocks)) {
    for (e in edges) level[[e$to]] <- min(max(level[[e$to]], level[[e$from]] + 1L), length(blocks) - 1L)
  }
  lapply(sort(unique(level)), function(l) as.list(names(level)[level == l]))
}

# Merge commits (first-parent history of HEAD) that brought review entries in:
# the entries a merge adds relative to its first parent. Rounds = most distinct
# review dates of one item among those entries.
review_history <- function(path) {
  head <- git_head(path)
  if (is.na(head)) return(list())
  log <- git_try(path, c("-c", "log.showSignature=false", "log", "--first-parent", "--merges", "--format=%H%x1f%P%x1f%s%x1f%cs", head))
  out <- list()
  for (line in log) {
    f <- strsplit(line, "\x1f", fixed = TRUE)[[1]]
    sha <- f[1]
    parent <- strsplit(f[2], " ", fixed = TRUE)[[1]][1]
    files <- git_try(path, c("diff", "--name-only", "--relative", "--diff-filter=A", parent, sha, "--", "qa/reviews"))
    files <- files[grepl("\\.json$", files)]
    if (!length(files)) next
    entries <- lapply(files, function(file) {
      txt <- git_try(path, c("show", paste0(sha, ":./", file)))
      e <- tryCatch(jsonlite::fromJSON(paste(txt, collapse = "\n")), error = function(e) NULL)
      if (is.null(e)) NULL else list(item = e$item, date = substr(e$date, 1, 10))
    })
    entries <- Filter(Negate(is.null), entries)
    if (!length(entries)) next
    item <- vapply(entries, `[[`, "", "item")
    date <- vapply(entries, `[[`, "", "date")
    rounds <- max(vapply(split(date, item), function(d) length(unique(d)), integer(1)))
    out[[length(out) + 1L]] <- list(
      branch = merge_branch(f[3]), items = length(unique(item)), rounds = rounds, merged = f[4]
    )
  }
  out
}

# "Merge branch 'dev/x' into 'main'" -> "dev/x"; other subjects stay as they are.
merge_branch <- function(subject) {
  m <- regmatches(subject, regexec("^Merge (?:remote-tracking )?branch '([^']+)'", subject))[[1]]
  if (length(m) == 2) m[2] else subject
}
