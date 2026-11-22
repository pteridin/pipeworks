# The live server behind `pipeworks()`: an httpuv server inside the R session
# (the console stays free), one per project, with a small JSON API for
# verdicts, retries and "open in RStudio", and a watcher that refreshes the
# model when project files change. The browser writes files only through
# `record_verdict()` (reviews) and `apply_changes()` (code).

# Running servers by normalised project path.
pw_servers <- new.env(parent = emptyenv())

# State of one project's server (an environment, shared by the handler, the
# watcher and `pipeworks()`). `model = NULL` reads the pipeline now.
# `open_file(file, line)` opens a source file (stubbed in tests); it may
# return `list(ok = FALSE, error = )` when it cannot.
pw_state <- function(path, model = NULL, mode = "auto", port = NA_integer_, token = pw_token(),
                     open_file = open_in_editor) {
  path <- normalizePath(path, mustWork = TRUE)
  state <- new.env(parent = emptyenv())
  state$path <- path
  state$model <- if (is.null(model)) read_pipeline(path) else model
  state$model_error <- NULL
  state$qa_error <- NULL
  state$watch_error <- NULL
  state$mode <- resolve_mode(path, mode)
  state$port <- as.integer(port)
  state$token <- token
  state$open_file <- open_file
  state$version <- 1L
  state$bg <- NULL
  state$writes <- new.env(parent = emptyenv())
  state$write_seq <- 0L
  state$server <- NULL
  state$alive <- TRUE
  state$hosts <- character()
  state$origins <- character()
  if (!is.na(state$port)) pw_allow_local(state)
  state$items <- pw_items(path)
  state$model <- pw_mark_self(state$model, path, state$items)
  state$git_dirs <- pw_git_dirs(path)
  state$fingerprint <- pw_fingerprint(state)
  state
}

# The mode the page opens in. `auto`: Review when an open item (not passing
# `qa_check()`) was last changed by someone other than the current git user,
# else Build.
resolve_mode <- function(path, mode = c("auto", "review", "build")) {
  mode <- match.arg(mode)
  if (mode != "auto") return(mode)
  tryCatch(auto_mode(path), error = function(e) {
    message("Cannot tell whether to review or build (", conditionMessage(e), "); opening in Build mode.")
    "build"
  })
}

auto_mode <- function(path) {
  if (!git_available() || is.na(git_head(path))) return("build")
  st <- qa_status(path, authors = FALSE)
  open <- st[!qa_passing(st), , drop = FALSE]
  if (!nrow(open)) return("build")
  authors <- last_authors(path, open)
  me <- git_user(path)$email
  people <- read_people(path)
  known <- !is.na(authors$author_email)
  others <- known & (is.na(me) | person_of(authors$author_email, people) != person_of(me, people))
  if (any(others)) "review" else "build"
}

# Source items, or the error of reading them (a file that does not parse).
pw_read_items <- function(path) tryCatch(read_source(path)$items, error = function(e) e)

pw_items <- function(path) {
  items <- pw_read_items(path)
  if (inherits(items, "error")) NULL else items
}

# ---- Starting and stopping -------------------------------------------------

pw_start <- function(path, mode) {
  state <- pw_state(path, mode = mode)
  state$real_path <- normalizePath(path, mustWork = TRUE)
  server <- NULL
  for (i in 1:20) {
    state$port <- as.integer(httpuv::randomPort(host = "127.0.0.1"))
    state$hosts <- state$origins <- character()
    pw_allow_local(state)
    server <- tryCatch(httpuv::startServer("127.0.0.1", state$port, pw_app(state)), error = function(e) NULL)
    if (!is.null(server)) break
  }
  if (is.null(server)) stop("Cannot start the pipeworks server: no free port found.", call. = FALSE)
  state$server <- server
  state$public_url <- pw_rstudio_server_url(pw_url(state))
  if (!is.null(state$public_url)) pw_allow(state, pw_origin_of(state$public_url))
  pw_watch(state)
  state
}

# All running servers, stopped (also when the package is unloaded).
pw_stop_all <- function() {
  for (key in ls(pw_servers, all.names = TRUE)) pipeworks_stop(key)
  invisible()
}

.onUnload <- function(libpath) pw_stop_all()

pw_running <- function(state) {
  isTRUE(state$alive) && !is.null(state$server) && isTRUE(tryCatch(state$server$isRunning(), error = function(e) FALSE))
}

pw_shutdown <- function(state) {
  state$alive <- FALSE
  pw_kill_bg(state)
  if (!is.null(state$server)) try(state$server$stop(), silent = TRUE)
  invisible()
}

pw_url <- function(state) sprintf("http://127.0.0.1:%d/?token=%s", state$port, state$token)

# The address to show the user: the RStudio Server one when there is one.
pw_public_url <- function(state) state$public_url %||% pw_url(state)

# ---- Watcher ---------------------------------------------------------------

pw_watch <- function(state) {
  later::later(function() {
    if (!pw_running(state)) return()
    pw_watch_step(state)
    pw_watch(state)
  }, 2)
}

# A tick that cannot throw: an error goes to `live$watch_error` (and bumps
# the version so the page shows it); the next good tick clears it.
pw_watch_step <- function(state) {
  ok <- tryCatch({
    pw_tick(state)
    TRUE
  }, error = function(e) {
    state$watch_error <- paste("Refreshing failed:", conditionMessage(e))
    state$version <- state$version + 1L
    FALSE
  })
  if (ok && !is.null(state$watch_error)) {
    state$watch_error <- NULL
    state$version <- state$version + 1L
  }
  invisible(ok)
}

# One watcher step: collect a finished background rebuild, then compare the
# file fingerprint. Returns the kind of file change: "none", "qa" (review
# entries or git refs; status recomputed in-session) or "code" (also starts a
# background rebuild of the structure).
pw_tick <- function(state) {
  pw_poll_bg(state)
  old <- state$fingerprint
  new <- pw_fingerprint(state)
  state$fingerprint <- new
  changed <- function(group) !identical(old[[group]], new[[group]])
  kind <- if (changed("code")) "code" else if (changed("qa") || changed("git")) "qa" else "none"
  if (kind != "none") pw_refresh_qa(state)
  if (kind == "code") pw_start_bg(state)
  kind
}

# Git dir and common dir (worktrees keep refs in the latter), absolute.
pw_git_dirs <- function(path) {
  dirs <- git_try(path, c("rev-parse", "--git-dir", "--git-common-dir"))
  if (length(dirs) < 2) return(NULL)
  abs <- ifelse(grepl("^(/|[A-Za-z]:)", dirs), dirs, file.path(path, dirs))
  list(git = abs[1], common = abs[2])
}

# Files whose change triggers a refresh, by group (absolute paths).
pw_watch_files <- function(state) {
  path <- state$path
  below <- function(dir) {
    f <- list.files(file.path(path, dir), recursive = TRUE, all.files = TRUE)
    if (length(f)) file.path(path, dir, f) else character()
  }
  items <- state$items
  factory <- if (is.null(items)) character() else unique(items$file[items$kind == "file"])
  code <- c(below("R"), file.path(path, c("_targets.R", factory)))
  git <- character()
  if (!is.null(state$git_dirs)) {
    head <- file.path(state$git_dirs$git, "HEAD")
    ref <- tryCatch(readLines(head, n = 1L, warn = FALSE), error = function(e) "")
    ref <- if (length(ref) && startsWith(ref, "ref: ")) substring(ref, 6L) else character()
    git <- c(head, file.path(state$git_dirs$common, "packed-refs"),
             if (length(ref)) file.path(c(state$git_dirs$git, state$git_dirs$common), ref))
  }
  list(code = code, qa = below("qa"), git = unique(git))
}

# mtime and size of every watched file that exists, by group.
pw_fingerprint <- function(state) {
  lapply(pw_watch_files(state), function(files) {
    files <- files[file.exists(files)]
    info <- file.info(files, extra_cols = FALSE)
    stats::setNames(paste(format(as.numeric(info$mtime), digits = 15), info$size), files)
  })
}

# Run `expr`, collecting its warnings instead of letting them reach the
# console: list(value, warnings).
pw_quietly <- function(expr) {
  warnings <- character()
  value <- withCallingHandlers(expr, warning = function(w) {
    warnings <<- c(warnings, conditionMessage(w))
    invokeRestart("muffleWarning")
  })
  list(value = value, warnings = warnings)
}

# Review status again, in-session; the structure stays. When the source does
# not parse, or the status cannot be read (an error, or a result without
# `qa_summary` where there was one), the last items and status stay and
# `live$qa_error` says why; the next good refresh clears it. Warnings alone
# are no failure. `version` moves only when the status or `qa_error` changed.
pw_refresh_qa <- function(state) {
  before <- list(state$model, state$qa_error)
  on.exit(if (!identical(before, list(state$model, state$qa_error))) state$version <- state$version + 1L, add = TRUE)
  items <- pw_read_items(state$path)
  if (inherits(items, "error")) {
    state$qa_error <- conditionMessage(items)
    return(invisible(state))
  }
  state$items <- items
  res <- tryCatch(pw_quietly(attach_qa(state$model, state$path, items)), error = function(e) e)
  if (inherits(res, "error")) {
    state$qa_error <- conditionMessage(res)
  } else if (is.null(res$value$qa_summary) && !is.null(state$model$qa_summary)) {
    state$qa_error <- paste(c(res$warnings, "The review status could not be read.")[1], collapse = "")
  } else {
    state$model <- pw_mark_self(res$value, state$path, items)
    state$qa_error <- NULL
  }
  invisible(state)
}

# Rebuild the structure in a background process: only the part that runs
# `_targets.R` (`targets_info()`, which needs nothing but targets) runs there;
# the model is assembled in-session when it is done. One at a time: a newer
# change restarts it.
pw_start_bg <- function(state) {
  pw_kill_bg(state)
  state$bg <- callr::r_bg(
    targets_info,
    args = list(path = state$path, status = TRUE, callr_function = NULL),
    stdout = NULL, stderr = NULL
  )
  invisible(state)
}

pw_kill_bg <- function(state) {
  if (!is.null(state$bg) && state$bg$is_alive()) state$bg$kill()
  state$bg <- NULL
  invisible(state)
}

# Take the result of a finished background rebuild: a new model, or the error
# while the last good model stays. The source must parse for the new model to
# carry its review layer; if it does not (changed since the job started), the
# last model stays too.
pw_poll_bg <- function(state) {
  bg <- state$bg
  if (is.null(bg) || bg$is_alive()) return(FALSE)
  state$bg <- NULL
  on.exit(state$version <- state$version + 1L, add = TRUE)
  info <- tryCatch(bg$get_result(), error = function(e) e)
  if (inherits(info, "error")) {
    state$model_error <- pw_error_message(info)
    pw_refresh_bases(state)
    return(TRUE)
  }
  items <- pw_read_items(state$path)
  if (inherits(items, "error")) {
    state$qa_error <- conditionMessage(items)
    return(TRUE)
  }
  res <- tryCatch(pw_quietly(assemble_model(state$path, info)), error = function(e) e)
  if (inherits(res, "error")) {
    state$model_error <- pw_error_message(res)
    pw_refresh_bases(state)
    return(TRUE)
  }
  state$model <- pw_mark_self(res$value, state$path, items)
  state$items <- items
  state$model_error <- NULL
  state$qa_error <- NULL
  TRUE
}

# The structure could not be rebuilt and the last model stays: its bases are
# recomputed from the files (static), so an edit written since does not make
# every further edit of that item stale. Never throws.
pw_refresh_bases <- function(state) {
  items <- pw_read_items(state$path)
  if (inherits(items, "error") || is.null(state$model)) return(invisible(state))
  model <- tryCatch(attach_bases(state$model, state$path, items), error = function(e) NULL)
  if (!is.null(model)) state$model <- model
  invisible(state)
}

# The innermost message of a (callr-wrapped) error.
pw_error_message <- function(e) {
  while (inherits(e$parent, "condition")) e <- e$parent
  trimws(conditionMessage(e))
}

# ---- Live block ------------------------------------------------------------

# Review items the current git user last changed (git history, people mapped
# through `qa/people` as in `qa_review()`): a verdict from them would be a
# self-review. Items with uncommitted changes have no author and are left out.
# One `last_authors()` pass per refresh, never one git call per item.
pw_self_items <- function(path, items) {
  if (is.null(items) || !nrow(items) || !git_available() || is.na(git_head(path))) return(character())
  me <- git_user(path)$email
  if (is.na(me)) return(character())
  authors <- tryCatch(last_authors(path, items), error = function(e) NULL)
  if (is.null(authors)) return(character())
  people <- read_people(path)
  known <- !is.na(authors$author_email)
  authors$id[known & person_of(authors$author_email, people) == person_of(me, people)]
}

# Every review record of the model gets `self_review_if_you_record` (the page
# warns before such a verdict).
pw_mark_self <- function(model, path, items) {
  if (is.null(model)) return(model)
  self <- tryCatch(pw_self_items(path, items), error = function(e) character())
  mark <- function(q) {
    if (is.null(q)) return(NULL)
    q$self_review_if_you_record <- q$item %in% self
    q
  }
  for (i in seq_along(model$targets)) {
    model$targets[[i]]["qa"] <- list(mark(model$targets[[i]]$qa))
    model$targets[[i]]["qa_file"] <- list(mark(model$targets[[i]]$qa_file))
  }
  for (i in seq_along(model$functions)) model$functions[[i]]["qa"] <- list(mark(model$functions[[i]]$qa))
  for (i in seq_along(model$maps)) model$maps[[i]]["qa"] <- list(mark(model$maps[[i]]$qa))
  model
}


# Whether `record_verdict()` would refuse for repo-level reasons right now.
pw_can_record <- function(state) {
  path <- state$path
  no <- function(reason, blockers = character()) list(ok = FALSE, reason = reason, blockers = blockers)
  if (!git_available()) return(no("git was not found on the PATH."))
  busy <- git_busy(path)
  if (!is.na(busy)) return(no(busy_message(busy, "Cannot record a verdict"), busy))
  if (is.na(git_head(path))) return(no("Commit your code first: this project has no commits yet."))
  dirty <- uncommitted_code(path, state$items)
  if (length(dirty)) return(no("Commit your changes first.", dirty))
  who <- git_user(path)
  if (is.na(who$email) || is.na(who$name)) return(no("Your git identity is not set (user.name, user.email)."))
  list(ok = TRUE, reason = NULL, blockers = character())
}

pw_live <- function(state) {
  rec <- pw_can_record(state)
  unc <- uncommitted_reviews(state$path)
  list(
    version = state$version,
    building = !is.null(state$bg),
    mode = state$mode,
    base = state$model$qa_summary$base,
    can_record = rec$ok,
    blockers = I(rec$blockers),
    blocked_reason = rec$reason,
    uncommitted = I(if (length(unc)) review_rel(state$path, unc) else character()),
    qa_error = state$qa_error,
    watch_error = state$watch_error
  )
}

pw_payload <- function(state) {
  x <- unclass(state$model)
  x$live <- pw_live(state)
  x["model_error"] <- list(state$model_error)
  x
}
