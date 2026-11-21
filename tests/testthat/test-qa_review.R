test_that("a verdict is written with author, reviewer and hash", {
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list(tar_target(t1, f(1)))"),
                         author = c("Ann", "ann@wig2.de"))
  set_git_user(repo, "Bob", "bob@wig2.de")
  expect_message(e <- qa_review("f", "correct", path = repo), "function:f: correct")
  expect_equal(c(e$item, e$verdict, e$reviewer_email, e$author_email), c("function:f", "correct", "bob@wig2.de", "ann@wig2.de"))
  expect_length(list.files(file.path(repo, "qa", "reviews")), 1)
})

test_that("ambiguous names, missing comments and uncommitted code are refused", {
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list(tar_target(f, f(1)))"))
  expect_error(qa_review("f", "correct", path = repo), "function:f.*target:f")
  expect_error(qa_review("function:f", "wrong", path = repo), "comment")
  writeLines("f <- function(x) x + 1", file.path(repo, "R/a.R"))
  expect_error(qa_review("function:f", "correct", path = repo), "Commit")
})

test_that("unknown items list close matches; no commits is refused", {
  repo <- local_git_repo(list("R/a.R" = "clean_cs <- function(x) x"))
  expect_error(qa_review("clean_c", "correct", path = repo), "function:clean_cs")
  expect_error(qa_review("zzz", "correct", path = repo), "Unknown item")
  proj <- local_project(list("R/a.R" = "f <- function(x) x"))
  expect_error(qa_review("f", "correct", path = proj), "Commit")
})

test_that("entries round-trip through the ledger with depends", {
  repo <- local_git_repo(list(
    "R/a.R" = c("g <- function(x) x", "f <- function(x) g(x)"),
    "_targets.R" = "list(tar_target(t1, f(1)))"
  ))
  e <- suppressMessages(qa_review("f", "questionable", "check bands", path = repo))
  expect_named(e$depends, "function:g")
  t <- suppressMessages(qa_review("t1", "correct", path = repo))
  expect_named(t$depends, "function:f")
  g <- suppressMessages(qa_review("g", "correct", path = repo))
  expect_equal(length(g$depends), 0)
  r <- read_reviews(repo)
  expect_equal(nrow(r), 3)
  expect_true(all(c("item", "hash", "verdict", "comment", "reviewer", "reviewer_email", "author",
                    "author_email", "date", "commit", "depends") %in% names(r)))
  expect_equal(r$depends[[which(r$item == "function:f")]], list("function:g" = e$depends[[1]]))
  expect_equal(nrow(read_reviews(local_project(list("x" = "y")))), 0)
})

test_that("people map several emails to one person", {
  proj <- local_project(list("qa/people" = c("Name: Ann Example", "Emails: ann@wig2.de, Ann.E@gitlab.local", "",
                                              "Name: Bob", "Emails: bob@wig2.de")))
  p <- read_people(proj)
  expect_equal(person_of(c("ANN@wig2.de", "ann.e@gitlab.local", "x@y.z"), p), c("Ann Example", "Ann Example", "x@y.z"))
  expect_equal(person_of("a@b", read_people(local_project(list("x" = "y")))), "a@b")
})

test_that("write_review never overwrites an existing entry", {
  proj <- local_project(list("x" = "y"))
  entry <- list(item = "function:f", hash = "abcdef1234", verdict = "correct", comment = NA_character_,
                reviewer = "Bob", reviewer_email = "bob@wig2.de", author = "Ann", author_email = "ann@wig2.de",
                date = "2026-11-20T10:00:00Z", commit = "c0ffee", depends = list())
  a <- write_review(proj, entry)
  b <- write_review(proj, entry)
  expect_false(a == b)
  expect_length(list.files(file.path(proj, "qa", "reviews")), 2)
  expect_equal(nrow(read_reviews(proj)), 2)
})

test_that("a missing git identity is refused", {
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x"))
  git_cmd(repo, "config", "--unset", "user.email")
  withr::local_envvar(GIT_CONFIG_GLOBAL = nullfile(), GIT_CONFIG_SYSTEM = nullfile())
  expect_error(qa_review("f", "correct", path = repo), "git config user.email")
})

test_that("entries written in quick succession are returned in write order (millisecond dates)", {
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list(tar_target(t1, f(1)))"))
  set_git_user(repo, "Bob", "bob@wig2.de")
  suppressMessages(qa_review("f", "wrong", "first", path = repo))
  commit_as(repo, "R/a.R", "f <- function(x) x + 1")
  suppressMessages(qa_review("f", "questionable", "second", path = repo))
  commit_as(repo, "R/a.R", "f <- function(x) x + 2")
  suppressMessages(qa_review("f", "correct", path = repo))
  r <- read_reviews(repo)
  expect_equal(r$verdict, c("wrong", "questionable", "correct"))
  expect_true(all(grepl("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$", r$date)))
  expect_true(all(grepl("^\\d{8}T\\d{9}Z-", list.files(file.path(repo, "qa", "reviews")))))
})

test_that("same-date entries sort by numeric suffix and old second-resolution entries still parse", {
  proj <- local_project(list("x" = "y"))
  entry <- list(item = "function:f", hash = "abcdef1234", verdict = "correct", comment = NA_character_,
                reviewer = "Bob", reviewer_email = "bob@wig2.de", author = "Ann", author_email = "ann@wig2.de",
                date = "2026-11-20T10:00:00.500Z", commit = "c0ffee", depends = list())
  for (i in 1:11) write_review(proj, c(entry[names(entry) != "comment"], comment = paste("n", i)))
  old <- entry
  old$date <- "2026-11-20T10:00:00Z"
  old$comment <- "old"
  write_review(proj, old)
  r <- read_reviews(proj)
  expect_equal(r$comment, c("old", paste("n", 1:11)))
})
