# Four-eyes rule: a reviewer must not be the last author, and when that cannot
# be told the gate fails (closed, not open).

test_that("emails are compared case-insensitively, also without qa/people", {
  none <- read_people(local_project(list("x" = "y")))
  expect_equal(person_of("Analyst@Example.org", none), "analyst@example.org")
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list()"),
                         author = c("A. Analyst", "Analyst@Example.org"))
  set_git_user(repo, "A. Analyst", "analyst@example.org")
  suppressMessages(for (id in qa_status(repo)$id) qa_review(id, "correct", path = repo))
  st <- qa_status(repo)
  expect_true(all(st$self_reviewed))
  expect_error(suppressMessages(qa_check(repo)), "self-reviewed")
})

test_that("qa_review refuses while any code file is uncommitted", {
  skip_if_not(git_available())
  repo <- local_git_repo(list(
    "R/a.R" = "f <- function(x) g(x)", "R/b.R" = "g <- function(x) x", "_targets.R" = "list()"
  ))
  set_git_user(repo, "Bob", "bob@wig2.de")
  # uncommitted callee: the verdict on f would store the unreviewed g in `depends`
  writeLines("g <- function(x) x + 1", file.path(repo, "R/b.R"))
  expect_error(qa_review("f", "correct", path = repo), "Commit .*R/b.R")
  git_cmd(repo, "checkout", "--", "R/b.R")
  # an untracked file below R/ is loaded by tar_source() too
  writeLines("h <- function() 1", file.path(repo, "R/new.R"))
  expect_error(qa_review("f", "correct", path = repo), "Commit .*R/new.R")
  unlink(file.path(repo, "R/new.R"))
  expect_message(qa_review("f", "correct", path = repo), "function:f")
})

test_that("qa_review refuses when the last author cannot be determined", {
  skip_if_not(git_available())
  # the map's template sits in a file git ignores: at HEAD the map cannot be
  # resolved, so nobody can be named as its author
  repo <- local_git_repo(list(
    ".gitignore" = "R/secret.R",
    "_targets.R" = "list(tarchetypes::tar_map(values = list(v = 1:2), tmpl))"
  ))
  dir.create(file.path(repo, "R"))
  writeLines("tmpl <- list(tar_target(x, v + 1))", file.path(repo, "R/secret.R"))
  set_git_user(repo, "Bob", "bob@wig2.de")
  expect_error(qa_review("map:x", "correct", path = repo), "Cannot tell who last changed map:x")
  expect_error(qa_review("target:x", "correct", path = repo), "Commit|Cannot tell")
  expect_length(list.files(file.path(repo, "qa", "reviews")), 0)
})

test_that("entries without author or reviewer email do not pass", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list()"))
  items <- read_source(repo)$items
  entry <- function(id, author_email, reviewer_email) list(
    item = id, hash = items$hash[items$id == id], verdict = "correct", comment = NA_character_,
    reviewer = "Bob", reviewer_email = reviewer_email, author = "Ann", author_email = author_email,
    date = "2026-11-20T10:00:00.000Z", commit = git_head(repo), depends = list()
  )
  write_review(repo, entry("function:f", NA_character_, "bob@wig2.de"))
  write_review(repo, entry("object:_targets.R:list#1", "ann@wig2.de", NA_character_))
  st <- qa_status(repo)
  expect_true(all(is.na(st$self_reviewed)))
  expect_error(suppressMessages(qa_check(repo)), "2 authorship unknown")
  expect_error(suppressMessages(qa_check(repo)), "correct, authorship unknown: function:f")
  expect_output(print(st), "authorship unknown")
})
