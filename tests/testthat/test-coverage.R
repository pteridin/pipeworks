# The gate must not pass while code that the pipeline loads was never an item.

test_that("R/ is read recursively, like tar_source()", {
  dir <- local_project(list(
    "R/a.R" = "f <- function() 1",
    "R/helpers/x.R" = c("evil <- function(x) x * 2", "LIMIT <- 3"),
    "R/helpers/deep/y.r" = "deeper <- function() 0",
    "_targets.R" = "list()"
  ))
  s <- read_source(dir)
  expect_true(all(c("function:evil", "object:R/helpers/x.R:LIMIT", "function:deeper") %in% s$items$id))
  expect_equal(s$items$file[s$items$id == "function:evil"], "R/helpers/x.R")
  expect_true("R/helpers/deep/y.r" %in% s$files)
})

test_that("git history reads R/ recursively, so subfolder items get authors", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- function() 1", "_targets.R" = "list()"))
  commit_as(repo, "R/helpers/x.R", "evil <- function(x) x * 2", author = c("Bob", "bob@wig2.de"))
  expect_true("R/helpers/x.R" %in% names(git_tree_texts(repo, "HEAD")))
  la <- last_authors(repo, read_source(repo)$items)
  expect_equal(la$author_email[la$id == "function:evil"], "bob@wig2.de")
  expect_error(suppressMessages(qa_check(repo)), "function:evil")
})

rest_hash <- function(files, id) {
  it <- read_source_text(files)$items
  expect_true(id %in% it$id, label = paste(id, "is an item"))
  it$hash[it$id == id]
}

test_that("a top-level block with targets gets a rest item covering everything else", {
  base <- c(
    "pipeline_report <- list(",
    "  tar_target(hist_raw, f(raw)),",
    "  tar_target(hist_clean, f(clean))",
    ")"
  )
  files <- function(lines, targets = "list(pipeline_report)") list("R/report.R" = lines, "_targets.R" = targets)
  id <- "object:R/report.R:pipeline_report"
  h0 <- rest_hash(files(base), id)

  # an unrecognised factory in the list changes the rest item, not the targets
  with_factory <- append(base, "  , tarchetypes::tar_files_input(extra, c('a.csv'))", after = 3)
  expect_false(rest_hash(files(with_factory), id) == h0)
  it0 <- read_source_text(files(base))$items
  it1 <- read_source_text(files(with_factory))$items
  expect_equal(it1$hash[it1$id == "target:hist_raw"], it0$hash[it0$id == "target:hist_raw"])
  # so does `name = cmd` in a list and tar_target_raw()
  expect_false(rest_hash(files(append(base, "  , extra = g(x)", after = 3)), id) == h0)
  expect_false(rest_hash(files(append(base, "  , tar_target_raw('x', quote(g()))", after = 3)), id) == h0)

  # deleting a target changes it
  expect_false(rest_hash(files(base[-3]), id) == h0)
  expect_false(rest_hash(files(c(base[1:2], ")")), id) == h0)

  # reformatting and comments do not
  expect_equal(rest_hash(files(c(
    "# Reporting", "pipeline_report <- list(tar_target(hist_raw, f(raw)), # a",
    "  tar_target(hist_clean,", "    f(clean)))"
  )), id), h0)

  # the composition in _targets.R is a rest item too
  comp <- c("library(targets)", "list(", "  pipeline_report,", "  pipeline_model,", "  tar_target(x, 1)", ")")
  cfiles <- function(t) list("R/report.R" = base, "_targets.R" = t)
  h1 <- rest_hash(cfiles(comp), "object:_targets.R:list#1")
  expect_false(rest_hash(cfiles(comp[-4]), "object:_targets.R:list#1") == h1)
  expect_equal(rest_hash(cfiles(c("library(targets)", "list(pipeline_report, pipeline_model, # all",
                                  "  tar_target(x,   1))")), "object:_targets.R:list#1"), h1)
})

test_that("tar_map() calls and their templates are cut out of the rest item", {
  a <- list("_targets.R" = c(
    "list(tarchetypes::tar_map(values = list(v = 1:2), tar_target(m, f(v))))"
  ))
  b <- list("_targets.R" = c(
    "list(tarchetypes::tar_map(values = list(v = 1:3), tar_target(m, g(v))))"
  ))
  expect_equal(rest_hash(a, "object:_targets.R:list#1"), rest_hash(b, "object:_targets.R:list#1"))
})

test_that("an unrecognised factory added to a reviewed list fails the gate", {
  skip_if_not(git_available())
  repo <- local_git_repo(list(
    "R/a.R" = c("f <- function(x) x", "pipeline_a <- list(", "  tar_target(t1, f(1))", ")"),
    "_targets.R" = "list(pipeline_a)"
  ))
  set_git_user(repo, "Bob", "bob@wig2.de")
  suppressMessages(for (id in qa_status(repo)$id) qa_review(id, "correct", path = repo))
  expect_message(qa_check(repo), "passed")
  commit_as(repo, "R/a.R", c(
    "f <- function(x) x", "pipeline_a <- list(", "  tar_target(t1, f(1)),",
    "  tarchetypes::tar_files_input(extra, 'a.csv')", ")"
  ))
  st <- qa_status(repo)
  expect_equal(st$status[st$id == "object:R/a.R:pipeline_a"], "changed")
  expect_error(suppressMessages(qa_check(repo)), "object:R/a.R:pipeline_a")
})

test_that("code loaded from outside R/ and _targets.R fails the gate", {
  base <- list("R/a.R" = "f <- function(x) x", "scripts/h.R" = "helper2 <- function(x) x")
  proj <- function(targets) local_project(c(base, list("_targets.R" = targets)), env = parent.frame())

  p <- proj(c("library(targets)", "source(\"scripts/h.R\")", "list()"))
  st <- qa_status(p)
  ext <- attr(st, "external")
  expect_equal(nrow(ext), 1)
  expect_equal(ext$path, "scripts/h.R")
  expect_equal(ext$file, "_targets.R")
  expect_output(print(st), "pipeworks cannot review code loaded from scripts/h.R")
  expect_error(suppressMessages(qa_check(p)),
               "pipeworks cannot review code loaded from scripts/h.R .*source\\(\\).*_targets.R.*move it into R/")

  expect_error(suppressMessages(qa_check(proj("tar_source(\"scripts\")"))), "loaded from scripts")
  expect_error(suppressMessages(qa_check(proj("targets::tar_source(c(\"R\", \"other\"))"))), "loaded from")
  expect_error(suppressMessages(qa_check(proj("sys.source('scripts/h.R', envir = globalenv())"))),
               "loaded from scripts/h.R .*sys.source")
  in_r <- local_project(list("R/a.R" = c("f <- function(x) x", "source('scripts/h.R')"), "_targets.R" = "list()"))
  expect_error(suppressMessages(qa_check(in_r)), "loaded from scripts/h.R .*R/a.R")

  for (ok in c("tar_source()", "tar_source(\"R\")", "targets::tar_source(files = \"R/\")")) {
    expect_equal(nrow(attr(qa_status(proj(ok)), "external")), 0, label = ok)
  }
})
