verdict_repo <- function(env = parent.frame()) {
  repo <- local_git_repo(list(
    "R/a.R" = "f <- function(x) x",
    "_targets.R" = "list(tar_target(t1, f(1)))",
    "notes.txt" = "a"
  ), author = c("Ann", "ann@wig2.de"), env = env)
  set_git_user(repo, "Bob", "bob@wig2.de")
  repo
}

test_that("a verdict commits only its entry, staged work stays staged", {
  repo <- verdict_repo()
  writeLines("b", file.path(repo, "notes.txt")); git_run(repo, c("add", "notes.txt"))
  r <- record_verdict(repo, "function:f", "correct")
  expect_true(r$committed)
  expect_equal(git_run(repo, c("log", "-1", "--format=%s")), "qa: correct function:f")
  expect_equal(git_run(repo, c("show", "--name-only", "--format=", "HEAD")), sub(paste0(repo, "/"), "", r$file, fixed = TRUE))
  expect_equal(git_run(repo, c("diff", "--cached", "--name-only")), "notes.txt")
})

test_that("two quick verdicts give two commits", {
  repo <- verdict_repo()
  before <- as.integer(git_run(repo, c("rev-list", "--count", "HEAD")))
  record_verdict(repo, "function:f", "correct")
  record_verdict(repo, "target:t1", "correct")
  expect_equal(as.integer(git_run(repo, c("rev-list", "--count", "HEAD"))), before + 2L)
})

test_that("busy repositories are refused before writing", {
  repo <- verdict_repo()
  expect_true(is.na(git_busy(repo)))
  file.create(file.path(repo, ".git", "index.lock"))
  expect_equal(git_busy(repo), "index.lock present")
  expect_error(record_verdict(repo, "function:f", "correct"), "index.lock")
  expect_false(dir.exists(file.path(repo, "qa", "reviews")) && length(list.files(file.path(repo, "qa", "reviews"))) > 0)
  unlink(file.path(repo, ".git", "index.lock"))
  file.create(file.path(repo, ".git", "MERGE_HEAD"))
  expect_equal(git_busy(repo), "merge in progress")
})

test_that("a failing commit keeps the entry and reports it", {
  skip_on_os("windows")
  repo <- verdict_repo()
  hook <- file.path(repo, ".git", "hooks", "pre-commit")
  dir.create(dirname(hook), showWarnings = FALSE)
  writeLines(c("#!/usr/bin/env Rscript", "quit(status = 1)"), hook)
  Sys.chmod(hook, "755")
  r <- record_verdict(repo, "function:f", "correct")
  expect_false(r$committed)
  expect_true(file.exists(r$file))
  expect_match(r$error, "git")
  expect_true(r$file %in% uncommitted_reviews(repo))
  expect_error(suppressMessages(qa_review("target:t1", "correct", path = repo)), "saved to .* but not committed")
  unlink(hook)
  res <- retry_uncommitted(repo)
  expect_true(all(res$committed))
  expect_equal(nrow(res), 2L)
  expect_length(uncommitted_reviews(repo), 0)
})

test_that("qa_review reports the commit and commit = FALSE leaves it to the user", {
  repo <- verdict_repo()
  expect_message(qa_review("function:f", "correct", path = repo), "committed [0-9a-f]{7}")
  suppressMessages(qa_review("target:t1", "correct", path = repo, commit = FALSE))
  expect_length(uncommitted_reviews(repo), 1)
})
