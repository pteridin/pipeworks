test_that("last author is who changed the hash, not who reformatted", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = c("f <- function(x) x + 1"), "_targets.R" = "list()"),
                         author = c("Ann", "ann@wig2.de"))
  commit_as(repo, "R/a.R", c("f <- function(x) x + 2"), author = c("Bob", "bob@wig2.de"))
  commit_as(repo, "R/a.R", c("# tidy", "f <- function(x)   x + 2"), author = c("Cem", "cem@wig2.de"))
  la <- last_authors(repo, read_source(repo)$items)
  expect_equal(la$author_email[la$id == "function:f"], "bob@wig2.de")
  expect_equal(la$author_name[la$id == "function:f"], "Bob")
  expect_match(la$commit[la$id == "function:f"], "^[0-9a-f]{40}$")
})

test_that("an item that appeared later is attributed to the commit adding it", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list()"))
  commit_as(repo, "R/a.R", c("f <- function(x) x", "g <- function() 1"), author = c("Bob", "bob@wig2.de"))
  la <- last_authors(repo, read_source(repo)$items)
  expect_equal(la$author_email[la$id == "function:g"], "bob@wig2.de")
  expect_equal(la$author_email[la$id == "function:f"], "ann@wig2.de")
})

test_that("a broken old version counts as absent instead of failing", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) {", "_targets.R" = "list()"))
  commit_as(repo, "R/a.R", "f <- function(x) x", author = c("Bob", "bob@wig2.de"))
  la <- last_authors(repo, read_source(repo)$items)
  expect_equal(la$author_email[la$id == "function:f"], "bob@wig2.de")
})

test_that("uncommitted changes leave the author unknown", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list()"))
  writeLines("f <- function(x) x + 1", file.path(repo, "R/a.R"))
  la <- last_authors(repo, read_source(repo)$items)
  expect_true(is.na(la$author_email[la$id == "function:f"]))
})

test_that("no commits and no git are handled", {
  dir <- local_project(list("R/a.R" = "f <- function() 1", "_targets.R" = "list()"))
  expect_true(is.na(git_head(dir)))
  la <- last_authors(dir, read_source(dir)$items)
  expect_equal(la$id, read_source(dir)$items$id)
  expect_true(all(is.na(la$author_email)))
  expect_false(git_file_clean(dir, "R/a.R"))
  skip_if_not(git_available())
  git_cmd(dir, "init", "-q", "-b", "main")
  expect_true(is.na(git_head(dir)))
  expect_true(all(is.na(last_authors(dir, read_source(dir)$items)$author_email)))
})

test_that("git_user, git_head and git_file_clean", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list()"),
                         author = c("Ann", "ann@wig2.de"))
  expect_equal(git_user(repo), list(name = "Ann", email = "ann@wig2.de"))
  expect_match(git_head(repo), "^[0-9a-f]{40}$")
  expect_true(git_file_clean(repo, "R/a.R"))
  writeLines("f <- function(x) 2", file.path(repo, "R/a.R"))
  expect_false(git_file_clean(repo, "R/a.R"))
  git_cmd(repo, "add", "R/a.R")
  expect_false(git_file_clean(repo, "R/a.R"))
  writeLines("h <- 1", file.path(repo, "R/new.R"))
  expect_false(git_file_clean(repo, "R/new.R"))
  expect_error(git_run(repo, c("show", "nonexistent")), "failed")
})

test_that("commit_as records the given author", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- 1"))
  sha <- commit_as(repo, "R/a.R", "f <- 2", author = c("Bob", "bob@wig2.de"))
  expect_equal(git_run(repo, c("log", "-1", "--format=%ae,%ce", sha)), "bob@wig2.de,bob@wig2.de")
})
