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
  git_init_main(dir)
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

test_that("a merge commit is not credited for side-branch changes", {
  skip_if_not(git_available())
  repo <- local_git_repo(list(
    "R/a.R" = "f <- function(x) x + 1", "R/b.R" = "g <- function() 1", "_targets.R" = "list()"
  ))
  git_cmd(repo, "checkout", "-q", "-b", "side")
  commit_as(repo, "R/a.R", "f <- function(x) x + 2", author = c("Bob", "bob@wig2.de"))
  git_cmd(repo, "checkout", "-q", "main")
  commit_as(repo, "R/b.R", "g <- function() 2", author = c("Ann", "ann@wig2.de"))
  git_cmd(repo, "-c", "user.name=Cem", "-c", "user.email=cem@wig2.de", "-c", "commit.gpgsign=false",
          "merge", "-q", "--no-ff", "-m", "merge", "side")
  la <- last_authors(repo, read_source(repo)$items)
  expect_equal(la$author_email[la$id == "function:f"], "bob@wig2.de")
  expect_equal(la$author_email[la$id == "function:g"], "ann@wig2.de")

  # fast-forward case
  git_cmd(repo, "checkout", "-q", "-b", "side2")
  commit_as(repo, "R/a.R", "f <- function(x) x + 3", author = c("Dan", "dan@wig2.de"))
  git_cmd(repo, "checkout", "-q", "main")
  git_cmd(repo, "merge", "-q", "--ff-only", "side2")
  la <- last_authors(repo, read_source(repo)$items)
  expect_equal(la$author_email[la$id == "function:f"], "dan@wig2.de")
})

test_that("map and file items get authors from the full code tree", {
  skip_if_not(git_available())
  skip_if_no_targets()
  files <- list.files(example_dir(), recursive = TRUE, all.files = TRUE, no.. = TRUE)
  files <- files[!grepl("^(_targets/|\\.Rproj\\.user/)|^report\\.html$", files)]
  repo <- withr::local_tempdir()
  for (f in files) {
    dir.create(file.path(repo, dirname(f)), recursive = TRUE, showWarnings = FALSE)
    file.copy(file.path(example_dir(), f), file.path(repo, f))
  }
  git_init_main(repo)
  set_git_user(repo, "Ann", "ann@wig2.de")
  git_cmd(repo, "config", "commit.gpgsign", "false")
  git_cmd(repo, "add", "-A")
  git_cmd(repo, "commit", "-q", "-m", "initial")
  items <- read_source(repo)$items
  expect_true(any(items$kind == "map"))
  expect_true(any(items$kind == "file"))
  la <- last_authors(repo, items)
  sel <- items$kind %in% c("map", "file")
  expect_false(anyNA(la$author_email[sel]))
})

test_that("a project below the repo root works", {
  skip_if_not(git_available())
  repo <- local_git_repo(list(
    "README.md" = "x", "proj/R/a.R" = "f <- function(x) x", "proj/_targets.R" = "list()"
  ))
  commit_as(repo, "proj/R/a.R", "f <- function(x) x + 1", author = c("Bob", "bob@wig2.de"))
  proj <- file.path(repo, "proj")
  la <- last_authors(proj, read_source(proj)$items)
  expect_equal(la$author_email[la$id == "function:f"], "bob@wig2.de")
  expect_true(git_file_clean(proj, "R/a.R"))
})
