# The live server: handler-level tests with fake request environments, plus
# one real HTTP round trip.

# The structural model of the git example, read once (it starts a callr
# process); its root does not matter for handler tests.
server_model <- function() {
  if (is.null(example_cache$server_model)) {
    example_cache$server_model <- read_pipeline(local_example_repo(), status = FALSE)
  }
  example_cache$server_model
}

local_state <- function(path, opened = NULL, env = parent.frame()) {
  state <- pw_state(path, model = server_model(), mode = "review", port = 4321L,
                    open_file = function(file, line) if (!is.null(opened)) opened(file, line))
  withr::defer(pw_kill_bg(state), envir = env)
  state
}

fake_req <- function(state, method = "GET", path = "/", query = "", token = state$token,
                     host = paste0("127.0.0.1:", state$port), origin = NULL, body = NULL) {
  req <- new.env()
  req$REQUEST_METHOD <- method
  req$PATH_INFO <- path
  req$QUERY_STRING <- query
  req$HTTP_HOST <- host
  if (!is.null(token)) req$HTTP_X_PIPEWORKS_TOKEN <- token
  if (!is.null(origin)) req$HTTP_ORIGIN <- origin
  bytes <- if (is.null(body)) raw() else charToRaw(as.character(jsonlite::toJSON(body, auto_unbox = TRUE)))
  req$rook.input <- list(read = function(l = -1L) bytes, rewind = function() invisible())
  req
}

call_app <- function(state, ...) {
  res <- pw_app(state)$call(fake_req(state, ...))
  type <- res$headers[["Content-Type"]]
  if (grepl("json", type)) res$json <- jsonlite::fromJSON(res$body, simplifyVector = FALSE)
  res
}

test_that("requests without the token, from a foreign host or origin are refused", {
  repo <- local_example_repo()
  state <- local_state(repo)
  expect_equal(call_app(state, path = "/api/version", token = NULL)$status, 403L)
  expect_equal(call_app(state, path = "/api/version", token = "wrong")$status, 403L)
  expect_equal(call_app(state, path = "/api/version", host = "evil.example:4321")$status, 403L)
  expect_equal(call_app(state, path = "/api/version", host = "127.0.0.1:9999")$status, 403L)
  expect_equal(call_app(state, method = "POST", path = "/api/retry", origin = "http://evil.example")$status, 403L)
  expect_equal(call_app(state, path = "/", token = NULL)$status, 403L)
  ok <- call_app(state, path = "/api/version", host = "localhost:4321")
  expect_equal(ok$status, 200L)
  expect_equal(ok$json$version, state$version)
  expect_equal(call_app(state, path = "/api/nothing")$status, 404L)
  expect_equal(call_app(state, method = "GET", path = "/api/verdict")$status, 405L)
})

test_that("the page embeds the model with the live block", {
  repo <- local_example_repo()
  state <- local_state(repo)
  res <- call_app(state, path = "/", token = NULL, query = paste0("token=", state$token))
  expect_equal(res$status, 200L)
  expect_match(res$headers[["Content-Type"]], "text/html")
  expect_match(res$body, '"live":{', fixed = TRUE)
  expect_match(res$body, '"mode":"review"', fixed = TRUE)
  m <- call_app(state, path = "/api/model")$json
  expect_equal(m$live$version, state$version)
  expect_true(m$live$can_record)
  expect_equal(m$live$base, "main")
  expect_null(m$model_error)
  expect_true(length(m$targets) > 0)
})

test_that("a verdict from the page is recorded and committed", {
  repo <- local_example_repo()
  state <- local_state(repo)
  head <- git_head(repo)
  v0 <- state$version
  res <- call_app(state, method = "POST", path = "/api/verdict", origin = "http://127.0.0.1:4321",
                  body = list(item = "function:count_by_channel", verdict = "correct"))
  expect_equal(res$status, 200L)
  expect_true(res$json$ok)
  expect_true(res$json$committed)
  expect_false(identical(git_head(repo), head))
  expect_equal(res$json$commit, git_head(repo))
  expect_equal(git_run(repo, c("log", "-1", "--format=%s")), "qa: correct function:count_by_channel")
  expect_equal(res$json$entry$reviewer, "S. Senior")
  expect_gt(state$version, v0)
  qa <- Filter(function(f) f$name == "count_by_channel", call_app(state, path = "/api/model")$json$functions)[[1]]$qa
  expect_equal(qa$status, "correct")

  bad <- call_app(state, method = "POST", path = "/api/verdict",
                  body = list(item = "function:count_by_channel", verdict = "wrong"))
  expect_equal(bad$status, 409L)
  expect_match(bad$json$error, "comment is required")
})

test_that("uncommitted code blocks verdicts and says which files", {
  repo <- local_example_repo()
  state <- local_state(repo)
  cat("# work in progress\n", file = file.path(repo, "R", "import.R"), append = TRUE)
  live <- call_app(state, path = "/api/model")$json$live
  expect_false(live$can_record)
  expect_true("R/import.R" %in% unlist(live$blockers))
  res <- call_app(state, method = "POST", path = "/api/verdict",
                  body = list(item = "function:count_by_channel", verdict = "correct"))
  expect_equal(res$status, 409L)
  expect_match(res$json$error, "R/import.R")
})

test_that("a change below qa/ refreshes the status in-session", {
  repo <- local_example_repo()
  state <- local_state(repo)
  v0 <- state$version
  expect_equal(pw_tick(state), "none")
  writeLines(c("Name: Senior", "Emails: senior@example.org"), file.path(repo, "qa", "people"))
  expect_equal(pw_tick(state), "qa")
  expect_equal(state$version, v0 + 1L)
  expect_null(state$bg)
})

test_that("a broken _targets.R keeps the last good model and reports the error", {
  skip_if_no_targets()
  repo <- local_example_repo()
  state <- local_state(repo)
  before <- state$model
  file <- file.path(repo, "_targets.R")
  good <- readLines(file)
  writeLines(c('stop("broken on purpose")', good), file)
  expect_equal(pw_tick(state), "code")
  expect_false(is.null(state$bg))
  state$bg$wait(60000)
  v1 <- state$version
  pw_tick(state)
  expect_match(state$model_error, "broken on purpose")
  expect_identical(state$model$targets, before$targets)
  expect_gt(state$version, v1)
  expect_match(call_app(state, path = "/api/model")$json$model_error, "broken on purpose")

  writeLines(good, file)
  cat("\n#' Twice\nx2 <- function(x) x * 2\n", file = file.path(repo, "R", "report.R"), append = TRUE)
  expect_equal(pw_tick(state), "code")
  state$bg$wait(60000)
  pw_tick(state)
  expect_null(state$model_error)
  expect_true("x2" %in% vapply(state$model$functions, `[[`, character(1), "name"))
})

test_that("auto mode decides by role", {
  repo <- local_example_repo()
  expect_equal(resolve_mode(repo, "auto"), "review")
  expect_equal(resolve_mode(repo, "build"), "build")
  set_git_user(repo, "A. Analyst", "analyst@example.org")
  expect_equal(resolve_mode(repo, "auto"), "build")
})

test_that("open sends the item's file and line to the editor", {
  repo <- local_example_repo()
  got <- NULL
  state <- local_state(repo, opened = function(file, line) got <<- list(file = file, line = line))
  res <- call_app(state, method = "POST", path = "/api/open", body = list(item = "function:count_by_channel"))
  expect_equal(res$status, 200L)
  expect_true(res$json$ok)
  expect_equal(normalizePath(got$file), normalizePath(file.path(repo, "R", "report.R")))
  expect_true(got$line > 1)
  expect_equal(call_app(state, method = "POST", path = "/api/open", body = list(item = "function:nope"))$status, 404L)
})

test_that("retry commits entries left uncommitted", {
  repo <- local_example_repo()
  state <- local_state(repo)
  r <- record_verdict(repo, "function:count_by_channel", "correct", commit = FALSE)
  res <- call_app(state, method = "POST", path = "/api/retry")
  expect_equal(res$status, 200L)
  expect_length(res$json$results, 1)
  expect_true(res$json$results[[1]]$committed)
  expect_length(uncommitted_reviews(repo), 0)
})

test_that("pipeworks() reuses the server of a project and pipeworks_stop() stops it", {
  repo <- local_example_repo()
  shown <- character()
  local_mocked_bindings(
    read_pipeline = function(path, ...) server_model(),
    show_url = function(url, viewer) shown <<- c(shown, url)
  )
  withr::defer(pipeworks_stop(repo))
  url <- pipeworks(repo, viewer = FALSE)
  expect_match(url, "^http://127\\.0\\.0\\.1:[0-9]+/\\?token=[0-9a-f]+$")
  expect_equal(pipeworks(repo, viewer = FALSE, mode = "build"), url)
  expect_equal(shown, c(url, url))
  expect_true(pipeworks_stop(repo))
  expect_false(pipeworks_stop(repo))
})

test_that("the server answers real HTTP requests", {
  skip_if_not_installed("curl")
  repo <- local_example_repo()
  local_mocked_bindings(read_pipeline = function(path, ...) server_model(), show_url = function(url, viewer) NULL)
  withr::defer(pipeworks_stop(repo))
  url <- pipeworks(repo, viewer = FALSE, mode = "review")
  base <- sub("/\\?token=.*$", "", url)
  token <- sub("^.*token=", "", url)
  fetch <- function(path, headers = character()) {
    h <- curl::new_handle()
    if (length(headers)) curl::handle_setheaders(h, .list = as.list(headers))
    res <- NULL
    curl::curl_fetch_multi(paste0(base, path), done = function(r) res <<- r, fail = function(m) stop(m), handle = h)
    deadline <- Sys.time() + 10
    while (is.null(res) && Sys.time() < deadline) {
      curl::multi_run(timeout = 0.05)
      httpuv::service(50)
    }
    res
  }
  ok <- fetch("/api/version", c("X-Pipeworks-Token" = token))
  expect_equal(ok$status_code, 200L)
  expect_type(jsonlite::fromJSON(rawToChar(ok$content))$version, "integer")
  expect_equal(fetch("/api/version")$status_code, 403L)
})
