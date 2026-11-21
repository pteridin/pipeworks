#' Go through the items that need a verdict, one by one
#'
#' An interactive console walk for quick reviews: for each open item (and,
#' optionally, each `check_again` hint) it shows the status, the last author,
#' the item's code and its diff against `base`, then asks for a verdict. Every
#' verdict is recorded and committed on its own, exactly like [qa_review()].
#' Answer `c` (correct), `q` (questionable), `w` (wrong), `s` (skip) or `x`
#' (quit). Questionable and wrong verdicts ask for a comment.
#'
#' Like [qa_review()], the walk refuses to start when code is uncommitted, when
#' git is busy (merge, rebase, `index.lock`) and, without `input`, in a
#' non-interactive session.
#'
#' @param path Project root.
#' @param base Git ref to diff against. Default: `main`, else `master`; without
#'   either no diff is shown.
#' @param include Which items to walk: `"open"` (not passing [qa_check()]) and/or
#'   `"check_again"` (passing, but a callee changed).
#' @param input For testing: a function taking the prompt and returning the
#'   answer, used instead of [readline()].
#' @return A data frame `item`, `verdict`, `committed` (one row per verdict
#'   recorded), invisibly.
#' @examples
#' \dontrun{
#' qa_walk(example_project(git = TRUE))
#' }
#' @export
qa_walk <- function(path = ".", base = NULL, include = c("open", "check_again"), input = NULL) {
  include <- match.arg(include, c("open", "check_again"), several.ok = TRUE)
  if (is.null(input)) {
    if (!interactive()) stop("qa_walk() needs an interactive session.", call. = FALSE)
    input <- function(prompt) readline(prompt)
  }
  check_project(path)
  if (!git_available()) stop("`git` was not found on the PATH; recording a verdict needs git.", call. = FALSE)
  busy <- git_busy(path)
  if (!is.na(busy)) stop("Cannot record a verdict: ", busy, ".", call. = FALSE)
  items <- read_source(path)$items
  dirty <- uncommitted_code(path, items)
  if (length(dirty)) {
    stop("Commit ", paste(dirty, collapse = ", "), " first: verdicts are only recorded for committed code, ",
         "and the items may depend on it.", call. = FALSE)
  }
  who <- git_user(path)
  if (is.na(who$email) || is.na(who$name)) {
    stop("Your git identity is not set; verdicts are matched by email. Run `git config user.name \"Your Name\"` and `git config user.email you@example.org`.", call. = FALSE)
  }

  st <- qa_status(path)
  pick <- (("open" %in% include) & !qa_passing(st)) | (("check_again" %in% include) & st$status == "check_again")
  st <- st[pick, , drop = FALSE]
  st <- st[order(st$block, st$id), , drop = FALSE]
  done <- data.frame(item = character(), verdict = character(), committed = logical(), stringsAsFactors = FALSE)
  if (!nrow(st)) {
    cat("Nothing to review.\n")
    return(invisible(done))
  }

  base_items <- walk_base_items(path, base, items)
  authors <- last_authors(path, items[match(st$id, items$id), , drop = FALSE])
  people <- read_people(path)
  reviews <- read_reviews(path)
  me <- person_of(who$email, people)
  names <- c(c = "correct", q = "questionable", w = "wrong")

  cat(nrow(st), " item(s) to review as ", who$name, ". Answers: c, q, w, s, x.\n", sep = "")
  for (i in seq_len(nrow(st))) {
    row <- st[i, , drop = FALSE]
    cat("\n[", i, "/", nrow(st), "] ", row$id, "  (", row$status, ", last changed by ",
        if (is.na(row$last_author)) "unknown" else row$last_author, ")\n", sep = "")
    if (isTRUE(!is.na(authors$author_email[i]) && person_of(authors$author_email[i], people) == me)) {
      cat("You last changed this; your verdict will be flagged as self-review.\n")
    }
    cat(walk_show(path, row, items, base_items, reviews), sep = "\n")

    answer <- ask_choice(input, "[c]orrect  [q]uestionable  [w]rong  [s]kip  [x] quit: ", c(names(names), "s", "x"))
    if (answer == "x") break
    if (answer == "s") next
    comment <- NULL
    if (answer != "c") {
      repeat {
        comment <- trimws(input("Comment: "))
        if (nzchar(comment)) break
        cat("A comment is required.\n")
      }
    }
    res <- record_verdict(path, row$id, names[[answer]], comment)
    done[nrow(done) + 1L, ] <- list(row$id, names[[answer]], isTRUE(res$committed))
    if (isTRUE(res$committed)) {
      cat("Recorded ", names[[answer]], " for ", row$id, ", committed ", substr(res$commit, 1, 7), ".\n", sep = "")
    } else {
      cat("Saved ", names[[answer]], " for ", row$id, " but could not commit it: ", res$error, "\nStopping the walk.\n", sep = "")
      break
    }
  }
  invisible(done)
}

# Re-ask until the answer is one of `valid` (lower case, trimmed). Running out
# of input (NA or empty vector) counts as quitting.
ask_choice <- function(input, prompt, valid) {
  repeat {
    a <- input(prompt)
    if (!length(a) || is.na(a[1])) return("x")
    a <- tolower(trimws(a[1]))
    if (a %in% valid) return(a)
    cat("Please answer one of: ", paste(valid, collapse = ", "), ".\n", sep = "")
  }
}

# Items at the diff base (NULL: no base available). Default base: main, else master.
walk_base_items <- function(path, base, items) {
  if (is.null(base)) {
    for (b in c("main", "master")) {
      if (!is.null(git_try(path, c("rev-parse", "--verify", "--quiet", paste0("refs/heads/", b))))) {
        base <- b
        break
      }
    }
  }
  if (is.null(base)) return(NULL)
  texts <- tryCatch(git_tree_texts(path, base, items$file[items$kind == "file"]), error = function(e) NULL)
  src <- if (!is.null(texts)) tryCatch(read_source_text(texts), error = function(e) NULL)
  if (is.null(src)) return(NULL)
  head <- git_try(path, c("rev-parse", "--verify", "--quiet", "HEAD"))
  tip <- git_try(path, c("rev-parse", "--verify", "--quiet", paste0(base, "^{commit}")))
  branch <- git_try(path, c("rev-parse", "--abbrev-ref", "HEAD"))
  same <- identical(head, tip) || identical(branch, base)
  list(base = base, items = src$items, texts = texts, same = same)
}

item_lines <- function(texts, row) {
  lines <- texts[[row$file]]
  if (is.null(lines) || is.na(row$line1)) return(NULL)
  lines[seq.int(row$line1, min(row$line2, length(lines)))]
}

# Current lines of `file` (empty when it does not exist).
current_lines <- function(path, file) {
  full <- file.path(path, file)
  if (file.exists(full)) readLines(full, warn = FALSE, encoding = "UTF-8") else character()
}

code_block <- function(row, lines) {
  c(paste0("--- ", row$file, ":", row$line1, "-", row$line2), lines)
}

# What to show for one item: the code (in full only when there is nothing to
# diff against) or the changed hunks against the base.
walk_show <- function(path, row, items, base, reviews) {
  mine <- function(r) item_lines(stats::setNames(list(current_lines(path, r$file)), r$file), r)
  if (row$status == "check_again") {
    out <- c(code_block(row, mine(row)),
             "This item is unchanged; a function it calls changed since the review:")
    for (id in changed_callees(row, items, reviews)) {
      out <- c(out, "", paste0("Changed callee: ", id))
      cur <- items[items$id == id, , drop = FALSE]
      out <- c(out, if (nrow(cur)) walk_diff(path, cur, base, mine(cur)) else "(removed)")
    }
    return(out)
  }
  walk_diff(path, row, base, mine(row))
}

# Callee ids recorded in the item's latest matching review entry whose hash
# differs now (or that are gone).
changed_callees <- function(row, items, reviews) {
  hit <- which(reviews$item == row$id & !is.na(reviews$hash) & reviews$hash == row$hash)
  if (!length(hit)) return(character())
  d <- reviews$depends[[hit[length(hit)]]]
  now <- stats::setNames(items$hash, items$id)
  names(d)[vapply(names(d), function(k) !(k %in% names(now)) || now[[k]] != d[[k]], logical(1))]
}

# Code of `row` (`new` = its current lines) as a diff against the base: full
# code for new items or without a usable diff, else hunks with 3 lines of context.
walk_diff <- function(path, row, base, new) {
  if (is.null(base)) return(c(code_block(row, new), "(no diff: no `main` or `master` branch to compare with)"))
  if (isTRUE(base$same)) return(c(code_block(row, new), paste0("(no diff: you are on ", base$base, ")")))
  old_row <- base$items[base$items$id == row$id, , drop = FALSE]
  if (!nrow(old_row)) return(c(code_block(row, new), "(new item: not present at the base)"))
  old <- item_lines(base$texts, old_row)
  head <- paste0("--- ", row$file, ":", row$line1, "-", row$line2, "  (diff against ", base$base, ")")
  if (identical(old, new)) return(c(head, "(no change)"))
  c(head, diff_hunks(line_diff(old, new), row$line1))
}

# Hunks of a `line_diff()` with `context` lines around each change, separated
# by "@@ lines a-b @@" (line numbers in the file's current version; `first` is
# the file line of the item's first line).
diff_hunks <- function(diff, first, context = 3L) {
  n <- length(diff)
  changed <- which(substr(diff, 1, 1) %in% c("-", "+"))
  if (!n || !length(changed)) return(character())
  keep <- rep(FALSE, n)
  for (k in changed) keep[max(1L, k - context):min(n, k + context)] <- TRUE
  new_line <- first + cumsum(substr(diff, 1, 1) != "-") - 1L
  out <- character()
  i <- 1L
  while (i <= n) {
    if (!keep[i]) {
      i <- i + 1L
      next
    }
    j <- i
    while (j < n && keep[j + 1L]) j <- j + 1L
    lo <- new_line[i] + (substr(diff[i], 1, 1) == "-")
    hi <- max(new_line[i:j])
    out <- c(out, paste0("@@ lines ", lo, "-", max(lo, hi), " @@"), diff[i:j])
    i <- j + 1L
  }
  out
}

# LCS line diff, lines prefixed "- " (removed), "+ " (added) and "  " (kept).
line_diff <- function(old, new) {
  n <- length(old)
  m <- length(new)
  lcs <- matrix(0L, n + 1L, m + 1L)
  for (i in rev(seq_len(n))) for (j in rev(seq_len(m))) {
    lcs[i, j] <- if (old[i] == new[j]) lcs[i + 1L, j + 1L] + 1L else max(lcs[i + 1L, j], lcs[i, j + 1L])
  }
  out <- character()
  i <- 1L
  j <- 1L
  while (i <= n && j <= m) {
    if (old[i] == new[j]) {
      out <- c(out, paste0("  ", old[i])); i <- i + 1L; j <- j + 1L
    } else if (lcs[i + 1L, j] >= lcs[i, j + 1L]) {
      out <- c(out, paste0("- ", old[i])); i <- i + 1L
    } else {
      out <- c(out, paste0("+ ", new[j])); j <- j + 1L
    }
  }
  if (i <= n) out <- c(out, paste0("- ", old[i:n]))
  if (j <= m) out <- c(out, paste0("+ ", new[j:m]))
  out
}
