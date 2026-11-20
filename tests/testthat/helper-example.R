example_dir <- function() {
  src <- testthat::test_path("..", "..", "inst", "examples", "survey")
  if (dir.exists(src)) src else system.file("examples", "survey", package = "pipeworks")
}

skip_if_no_targets <- function() {
  testthat::skip_if_not_installed("targets")
  testthat::skip_if_not_installed("tarchetypes")
  testthat::skip_if_not_installed("rmarkdown")
}

by_name <- function(records, name) Filter(function(x) identical(x$name, name), records)[[1]]

# Reading the pipeline starts a separate R process, so read the example once
# from a clean copy (without _targets/) and reuse the result.
example_cache <- new.env()
read_example <- function() {
  if (is.null(example_cache$model)) {
    dest <- file.path(tempfile("pipeworks-test-"), "survey")
    dir.create(dest, recursive = TRUE)
    src <- example_dir()
    files <- list.files(src, recursive = TRUE, all.files = TRUE, no.. = TRUE)
    files <- files[!grepl("^(_targets/|\\.Rproj\\.user/)|^report\\.html$", files)]
    for (f in files) {
      dir.create(file.path(dest, dirname(f)), recursive = TRUE, showWarnings = FALSE)
      file.copy(file.path(src, f), file.path(dest, f))
    }
    example_cache$model <- read_pipeline(dest)
  }
  example_cache$model
}

# Write named character vectors as files below a temp dir (removed when `env`
# finishes) and return the dir.
local_project <- function(files, env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  for (f in names(files)) {
    dir.create(dirname(file.path(dir, f)), recursive = TRUE, showWarnings = FALSE)
    writeLines(files[[f]], file.path(dir, f))
  }
  dir
}

git_cmd <- function(repo, ...) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(repo), ...), stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) stop("git failed: ", paste(out, collapse = "\n"))
  out
}

set_git_user <- function(repo, name, email) {
  git_cmd(repo, "config", "user.name", shQuote(name))
  git_cmd(repo, "config", "user.email", shQuote(email))
  invisible(repo)
}

# `git init` on branch main (without `-b`, which needs git >= 2.28).
git_init_main <- function(repo) {
  git_cmd(repo, "init", "-q")
  git_cmd(repo, "symbolic-ref", "HEAD", "refs/heads/main")
}

# A temp git repo (plain git, repo-local identity, no signing) with `files`
# committed as "initial". Returns its path.
local_git_repo <- function(files, author = c("Ann", "ann@wig2.de"), env = parent.frame()) {
  repo <- local_project(files, env = env)
  git_init_main(repo)
  set_git_user(repo, author[1], author[2])
  git_cmd(repo, "config", "commit.gpgsign", "false")
  git_cmd(repo, "add", "-A")
  git_cmd(repo, "commit", "-q", "-m", "initial")
  repo
}

# Write `lines` to `file` and commit as `author`; returns the SHA invisibly.
commit_as <- function(repo, file, lines, author = c("Ann", "ann@wig2.de"), message = "change") {
  full <- file.path(repo, file)
  dir.create(dirname(full), recursive = TRUE, showWarnings = FALSE)
  writeLines(lines, full)
  git_cmd(repo, "add", "--", shQuote(file))
  git_cmd(
    repo,
    "-c", shQuote(paste0("user.name=", author[1])),
    "-c", shQuote(paste0("user.email=", author[2])),
    "-c", "commit.gpgsign=false",
    "commit", "-q", "-m", shQuote(message),
    shQuote(paste0("--author=", author[1], " <", author[2], ">"))
  )
  invisible(git_cmd(repo, "rev-parse", "HEAD")[1])
}

# A small committed repo (author Ann) with three functions in two blocks and
# two targets. Bob reviewed every item `correct` except `function:g`
# (`questionable`, with a comment); the review entries are committed. Returns
# the path; the repo-local git identity is Ann again afterwards.
reviewed_repo <- function(env = parent.frame()) {
  repo <- local_git_repo(list(
    "R/a.R" = c(
      "#' Constant one", "#'", "#' @return One.", "f <- function() 1",
      "",
      "#' Add one to the input", "g <- function(x) x + f()"
    ),
    "R/b.R" = c("#' Double the input", "h <- function(x) g(x) * 2"),
    "_targets.R" = c("library(targets)", "list(", "  tar_target(t1, g(1)),", "  tar_target(t2, h(t1))", ")")
  ), author = c("Ann", "ann@wig2.de"), env = env)
  set_git_user(repo, "Bob", "bob@wig2.de")
  st <- qa_status(repo)
  suppressMessages(for (id in st$id) {
    if (id == "function:g") qa_review(id, "questionable", "Edge case x = NA not handled", path = repo)
    else qa_review(id, "correct", path = repo)
  })
  git_cmd(repo, "add", "-A")
  git_cmd(repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", shQuote("reviews"))
  set_git_user(repo, "Ann", "ann@wig2.de")
  repo
}
