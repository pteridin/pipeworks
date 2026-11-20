test_that("example with git gives a realistic review round", {
  skip_if_not(git_available())
  repo <- example_project(file.path(withr::local_tempdir(), "s"), git = TRUE)
  expect_equal(git_run(repo, c("rev-parse", "--abbrev-ref", "HEAD")), "dev/sample-definition")
  expect_equal(git_user(repo)$email, "senior@example.org")

  st <- qa_status(repo, base = "main")
  open <- st$id[st$status %in% c("unreviewed", "changed")]
  expect_setequal(open, c("function:clean_survey", "function:count_by_channel", "target:channel_counts"))
  # pipeline lists are not items (their targets are), and target:clean_data only
  # gets a non-blocking note because its callee changed
  expect_equal(st$id[st$status == "check_again"], "target:clean_data")
  expect_error(suppressMessages(qa_check(repo)), "QA check failed")

  # main is fully reviewed
  git_run(repo, c("checkout", "-q", "main"))
  expect_no_error(suppressMessages(capture.output(qa_check(repo), type = "message")))
  # the questionable verdict carries a comment
  r <- read_reviews(repo)
  q <- r[r$verdict == "questionable", ]
  expect_equal(q$item, "function:summarise_region")
  expect_true(nzchar(q$comment))
  expect_setequal(unique(r$reviewer_email), "senior@example.org")
  expect_equal(unique(r$author_email), "analyst@example.org")
  git_run(repo, c("checkout", "-q", "dev/sample-definition"))

  # the senior reviews the open items: the check passes
  suppressMessages(for (id in open) qa_review(id, "correct", path = repo))
  git_run(repo, c("add", "-A"))
  git_run(repo, c("-c", "commit.gpgsign=false", "commit", "-q", "-m", "reviews"))
  expect_no_error(suppressMessages(capture.output(qa_check(repo), type = "message")))
})

test_that("example_project(git = TRUE) never touches the global git config", {
  skip_if_not(git_available())
  repo <- example_project(file.path(withr::local_tempdir(), "s"), git = TRUE)
  expect_equal(git_run(repo, c("config", "--local", "user.email")), "senior@example.org")
  expect_equal(git_run(repo, c("config", "--local", "commit.gpgsign")), "false")
})
