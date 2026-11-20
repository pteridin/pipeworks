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

# A temp git repo (plain git, repo-local identity, no signing) with `files`
# committed as "initial". Returns its path.
local_git_repo <- function(files, author = c("Ann", "ann@wig2.de"), env = parent.frame()) {
  repo <- local_project(files, env = env)
  git_cmd(repo, "init", "-q", "-b", "main")
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
