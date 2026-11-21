# The live server behind `pipeworks()`: an httpuv server inside the R session
# (the console stays free), one per project, with a small JSON API for
# verdicts, retries and "open in RStudio", and a watcher that refreshes the
# model when project files change. The browser never writes files: every
# write goes through `record_verdict()`.

# Running servers by normalised project path.
pw_servers <- new.env(parent = emptyenv())

# State of one project's server (an environment, shared by the handler, the
# watcher and `pipeworks()`). `model = NULL` reads the pipeline now.
# `open_file(file, line)` opens a source file (stubbed in tests).
pw_state <- function(path, model = NULL, mode = "auto", port = NA_integer_, token = pw_token(),
                     open_file = open_in_editor) {
  path <- normalizePath(path, mustWork = TRUE)
  state <- new.env(parent = emptyenv())
  state$path <- path
  state$model <- if (is.null(model)) read_pipeline(path) else model
  state$model_error <- NULL
  state$qa_error <- NULL
  state$mode <- resolve_mode(path, mode)
  state$port <- as.integer(port)
  state$token <- token
  state$open_file <- open_file
  state$version <- 1L
  state$bg <- NULL
  state$server <- NULL
  state$alive <- TRUE
  state$items <- pw_items(path)
  state$git_dirs <- pw_git_dirs(path)
  state$fingerprint <- pw_fingerprint(state)
  state
}

# 32 hex digits from the OS where possible; never touches the user's RNG stream.
pw_token <- function() {
  bytes <- if (file.exists("/dev/urandom")) {
    tryCatch({
      con <- file("/dev/urandom", "rb", raw = TRUE)
      on.exit(close(con))
      readBin(con, "raw", 16L)
    }, error = function(e) raw())
  } else raw()
  if (length(bytes) < 16L) {
    bytes <- withr::with_preserve_seed({
      set.seed(NULL)
      as.raw(sample.int(256L, 16L, replace = TRUE) - 1L)
    })
  }
  paste(format(as.hexmode(as.integer(bytes)), width = 2), collapse = "")
}

# The mode the page opens in. `auto`: Review when an open item (not passing
# `qa_check()`) was last changed by someone other than the current git user,
# else Build.
resolve_mode <- function(path, mode = c("auto", "review", "build")) {
  mode <- match.arg(mode)
  if (mode != "auto") return(mode)
  if (!git_available() || is.na(git_head(path))) return("build")
  st <- tryCatch(qa_status(path, authors = FALSE), error = function(e) NULL)
  if (is.null(st)) return("build")
  open <- st[!qa_passing(st), , drop = FALSE]
  if (!nrow(open)) return("build")
  authors <- last_authors(path, open)
  me <- git_user(path)$email
  people <- read_people(path)
  known <- !is.na(authors$author_email)
  others <- known & (is.na(me) | person_of(authors$author_email, people) != person_of(me, people))
  if (any(others)) "review" else "build"
}

pw_items <- function(path) tryCatch(read_source(path)$items, error = function(e) NULL)

# ---- Starting and stopping -------------------------------------------------

pw_start <- function(path, mode) {
  state <- pw_state(path, mode = mode)
  server <- NULL
  for (i in 1:20) {
    state$port <- as.integer(httpuv::randomPort(host = "127.0.0.1"))
    server <- tryCatch(httpuv::startServer("127.0.0.1", state$port, pw_app(state)), error = function(e) NULL)
    if (!is.null(server)) break
  }
  if (is.null(server)) stop("Cannot start the pipeworks server: no free port found.", call. = FALSE)
  state$server <- server
  pw_watch(state)
  state
}

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

# Viewer pane in RStudio, else the browser.
show_url <- function(url, viewer) {
  if (isTRUE(viewer) && requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    rstudioapi::viewer(url)
  } else {
    utils::browseURL(url)
  }
}

open_in_editor <- function(file, line) {
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    rstudioapi::navigateToFile(file, line = line)
  } else {
    utils::file.edit(file)
  }
}

# ---- Watcher ---------------------------------------------------------------

pw_watch <- function(state) {
  later::later(function() {
    if (!isTRUE(state$alive)) return()
    tryCatch(pw_tick(state), error = function(e) {
      state$model_error <- paste("Refreshing failed:", conditionMessage(e))
    })
    pw_watch(state)
  }, 2)
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

# Review status again, in-session; the structure stays. A failure keeps the
# last status and reports it in `live$qa_error`.
pw_refresh_qa <- function(state) {
  state$items <- pw_items(state$path)
  model <- tryCatch(attach_qa(state$model, state$path, state$items),
                    error = function(e) e, warning = function(w) w)
  if (inherits(model, "condition")) {
    state$qa_error <- conditionMessage(model)
  } else {
    state$model <- model
    state$qa_error <- NULL
  }
  state$version <- state$version + 1L
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
# while the last good model stays.
pw_poll_bg <- function(state) {
  bg <- state$bg
  if (is.null(bg) || bg$is_alive()) return(FALSE)
  state$bg <- NULL
  info <- tryCatch(bg$get_result(), error = function(e) e)
  model <- if (inherits(info, "error")) info else {
    tryCatch(suppressWarnings(assemble_model(state$path, info)), error = function(e) e)
  }
  if (inherits(model, "error")) {
    state$model_error <- pw_error_message(model)
  } else {
    state$model <- model
    state$model_error <- NULL
    state$qa_error <- NULL
    state$items <- pw_items(state$path)
  }
  state$version <- state$version + 1L
  TRUE
}

# The innermost message of a (callr-wrapped) error.
pw_error_message <- function(e) {
  while (inherits(e$parent, "condition")) e <- e$parent
  trimws(conditionMessage(e))
}

# ---- Live block ------------------------------------------------------------

# Whether `record_verdict()` would refuse for repo-level reasons right now.
pw_can_record <- function(state) {
  path <- state$path
  no <- function(reason, blockers = character()) list(ok = FALSE, reason = reason, blockers = blockers)
  if (!git_available()) return(no("git was not found on the PATH."))
  busy <- git_busy(path)
  if (!is.na(busy)) return(no(paste0("Cannot record a verdict: ", busy, "."), busy))
  if (is.na(git_head(path))) return(no("Commit your code first: this project has no commits yet."))
  dirty <- uncommitted_code(path, state$items)
  if (length(dirty)) return(no("Commit your changes first.", dirty))
  who <- git_user(path)
  if (is.na(who$email) || is.na(who$name)) return(no("Your git identity is not set (user.name, user.email)."))
  list(ok = TRUE, reason = NULL, blockers = character())
}

pw_live <- function(state) {
  rec <- pw_can_record(state)
  list(
    version = state$version,
    mode = state$mode,
    base = state$model$qa_summary$base,
    can_record = rec$ok,
    blockers = I(rec$blockers),
    blocked_reason = rec$reason,
    qa_error = state$qa_error
  )
}

pw_payload <- function(state) {
  x <- unclass(state$model)
  x$live <- pw_live(state)
  x["model_error"] <- list(state$model_error)
  x
}
