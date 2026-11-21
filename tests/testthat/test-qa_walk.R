# Answers in order; once exhausted it quits, so a short script never loops.
scripted <- function(answers) {
  i <- 0L
  prompts <- character()
  f <- function(prompt) {
    prompts <<- c(prompts, prompt)
    i <<- i + 1L
    if (i > length(answers)) "x" else answers[[i]]
  }
  list(input = f, calls = function() length(prompts), prompts = function() prompts)
}

walk_repo <- function(env = parent.frame()) {
  skip_if_not(git_available())
  example_project(file.path(withr::local_tempdir(.local_envir = env), "s"), git = TRUE)
}

test_that("a walk records one commit per verdict and leaves the rest open", {
  repo <- walk_repo()
  st <- qa_status(repo)
  open <- st$id[!qa_passing(st)]
  expect_length(open, 4)
  before <- as.integer(git_run(repo, c("rev-list", "--count", "HEAD")))
  s <- scripted(c("c", "q", "needs a unit test", "c"))
  out <- capture.output(res <- qa_walk(repo, include = "open", input = s$input))
  expect_equal(nrow(res), 3)
  expect_equal(res$verdict, c("correct", "questionable", "correct"))
  expect_true(all(res$committed))
  expect_setequal(res$item, open[open %in% res$item])
  expect_equal(as.integer(git_run(repo, c("rev-list", "--count", "HEAD"))), before + 3L)
  expect_equal(git_run(repo, c("log", "-1", "--format=%s")), paste("qa: correct", res$item[3]))
  expect_true(any(grepl("Comment:", s$prompts())))
  expect_true(any(grepl("^\\+ ", out)) || any(grepl("^- ", out)))
  # exactly the fourth open item remains
  rest <- setdiff(open, res$item)
  expect_length(rest, 1)
  expect_error(suppressMessages(qa_check(repo)), "unreviewed|changed")
  st2 <- qa_status(repo)
  expect_equal(st2$id[!qa_passing(st2)], rest)
})

test_that("walking everything leaves the check passing", {
  repo <- walk_repo()
  s <- scripted(rep("c", 6))
  out <- capture.output(res <- qa_walk(repo, input = s$input))
  expect_equal(nrow(res), 5)  # four open items and the check_again hint
  expect_no_error(suppressMessages(capture.output(qa_check(repo), type = "message")))
})

test_that("x quits early, s skips, empty comments are re-asked", {
  repo <- walk_repo()
  s <- scripted(c("s", "w", "", "  ", "broken", "x"))
  out <- capture.output(res <- qa_walk(repo, include = "open", input = s$input))
  expect_equal(res$verdict, "wrong")
  expect_equal(s$calls(), 6)
  expect_equal(sum(grepl("A comment is required", out)), 2)
  expect_equal(sum(!qa_passing(qa_status(repo))), 4)
})

test_that("invalid answers are re-asked", {
  repo <- walk_repo()
  s <- scripted(c("huh", "x"))
  out <- capture.output(res <- qa_walk(repo, include = "open", input = s$input))
  expect_equal(nrow(res), 0)
  expect_true(any(grepl("Please answer one of", out)))
})

test_that("the self-review warning shows only for the last author's own code", {
  repo <- walk_repo()
  warning_line <- "You last changed this; your verdict will be flagged as self-review."
  out <- capture.output(qa_walk(repo, include = "open", input = scripted("x")$input))
  expect_false(warning_line %in% out)
  set_git_user(repo, "A. Analyst", "analyst@example.org")
  out <- capture.output(qa_walk(repo, include = "open", input = scripted("x")$input))
  expect_true(warning_line %in% out)
})

test_that("non-interactive sessions need input", {
  expect_error(qa_walk(withr::local_tempdir()), "qa_walk\\(\\) needs an interactive session")
})

test_that("a dirty tree is refused before any prompt", {
  repo <- walk_repo()
  cat("# edit\n", file = file.path(repo, "R", "report.R"), append = TRUE)
  s <- scripted("c")
  expect_error(qa_walk(repo, input = s$input), "Commit .*report.R first")
  expect_equal(s$calls(), 0)
})

test_that("a busy repository is refused before any prompt", {
  repo <- walk_repo()
  file.create(file.path(repo, ".git", "index.lock"))
  s <- scripted("c")
  expect_error(qa_walk(repo, input = s$input), "index.lock")
  expect_equal(s$calls(), 0)
})

test_that("nothing to review says so", {
  repo <- walk_repo()
  git_run(repo, c("checkout", "-q", "main"))
  s <- scripted("c")
  expect_output(res <- qa_walk(repo, include = "open", input = s$input), "Nothing to review")
  expect_equal(nrow(res), 0)
  expect_equal(s$calls(), 0)
})

test_that("line_diff marks removed and added lines", {
  expect_equal(line_diff(c("a", "b", "c"), c("a", "x", "c")), c("  a", "- b", "+ x", "  c"))
})
