test_that("functions, targets, maps and objects are found", {
  dir <- local_project(list(
    "R/cohort.R" = c(
      "#' Clean cohort", "clean_cs <- function(raw) {", "  raw # keep", "}",
      "AGE_MIN <- 18",
      "pipeline_cohort <- list(", "  tar_target(cs, clean_cs(raw), format = 'qs')", ")"
    ),
    "_targets.R" = c(
      "library(targets)", "tar_source()",
      "mapped <- tarchetypes::tar_map(values = list(this = c('a','b')), tar_target(fit, f(cs, this)))",
      "list(pipeline_cohort, mapped)"
    )
  ))
  s <- read_source(dir)
  expect_setequal(s$items$id, c(
    "function:clean_cs", "object:R/cohort.R:AGE_MIN", "target:cs", "map:fit", "target:fit",
    "object:_targets.R:library#1", "object:_targets.R:tar_source#1", "object:_targets.R:list#1"
  ))
  expect_equal(s$items$fn[s$items$id == "target:cs"], "clean_cs")
  expect_equal(s$items$map[s$items$id == "target:fit"], "map:fit")
  expect_equal(s$items$title[s$items$id == "function:clean_cs"], "Clean cohort")
  expect_setequal(s$files, c("R/cohort.R", "_targets.R"))
  expect_true(all(grepl("^[0-9a-f]{32}$", s$items$hash)))
})

test_that("comments, roxygen and formatting do not change a hash; code does", {
  base <- c("f <- function(x) {", "  x + 1", "}")
  h <- function(lines) read_source_text(list("R/a.R" = lines))$items$hash
  expect_equal(h(base), h(c("#' doc", "f <- function(x) {  x+1 # c", "}")))
  expect_false(h(base) == h(c("f <- function(x) {", "  x + 2", "}")))
})

test_that("a map spanning two files collects templates via symbols", {
  dir <- local_project(list(
    "R/a.R" = c("tmpl_a <- list(tar_target(cs_this, g(this)))"),
    "R/b.R" = c("tmpl_b <- list(tar_target(out_this, h(cs_this)))"),
    "_targets.R" = c("tarchetypes::tar_map(values = list(this = c('a','b')), tmpl_a, tmpl_b)")
  ))
  it <- read_source(dir)$items
  expect_equal(it$map[it$id %in% c("target:cs_this", "target:out_this")], c("map:cs_this+out_this", "map:cs_this+out_this"))
})

test_that("duplicate function definitions and parse errors fail clearly", {
  dup <- local_project(list("R/a.R" = "f <- function() 1", "R/b.R" = "f <- function() 2", "_targets.R" = "list()"))
  expect_error(read_source(dup), "f.*R/a.R.*R/b.R")
  bad <- local_project(list("R/a.R" = "f <- function( {", "_targets.R" = "list()"))
  expect_error(read_source(bad), "R/a.R")
})

test_that("namespaced calls, descriptions, calls between functions and bare targets work", {
  s <- read_source_text(list(
    "R/a.R" = c("g <- function() 1", "f <- function(x) g() + x", "k <- function() 2"),
    "_targets.R" = c(
      "list(targets::tar_target(a, f(1), description = 'First one'), tar_target(b, 2))"
    )
  ))
  it <- s$items
  expect_equal(it$calls[[which(it$id == "function:f")]], "g")
  expect_equal(it$calls[[which(it$id == "function:k")]], character())
  expect_equal(it$title[it$id == "target:a"], "First one")
  expect_equal(it$fn[it$id == "target:a"], "f")
  expect_true(is.na(it$fn[it$id == "target:b"]))
  expect_true(is.na(it$map[it$id == "target:a"]))
  expect_false("object:_targets.R:list#1" %in% it$id)
})

test_that("tar_render hashes the source file when its text is available", {
  src <- list("_targets.R" = "tarchetypes::tar_render(report, 'report.Rmd')")
  expect_false("file:report.Rmd" %in% read_source_text(src)$items$id)
  with_rmd <- read_source_text(c(src, list("report.Rmd" = c("# Hi", "text"))))$items
  expect_true("file:report.Rmd" %in% with_rmd$id)
  expect_equal(with_rmd$kind[with_rmd$id == "file:report.Rmd"], "file")

  dir <- local_project(c(src, list("report.Rmd" = c("# Hi", "text"))))
  it <- read_source(dir)$items
  expect_equal(it$hash[it$id == "file:report.Rmd"], unname(tools::md5sum(file.path(dir, "report.Rmd"))))
})

test_that("empty projects give an empty item table", {
  s <- read_source_text(list("_targets.R" = character()))
  expect_equal(nrow(s$items), 0)
  expect_true(all(c("id", "calls", "title") %in% names(s$items)))
})

test_that("unassigned calls with the same head are numbered per file", {
  s <- read_source_text(list(
    "R/a.R" = c("library(a)", "library(b)"),
    "_targets.R" = c("library(c)", "list()")
  ))
  expect_setequal(s$items$id, c(
    "object:R/a.R:library#1", "object:R/a.R:library#2",
    "object:_targets.R:library#1", "object:_targets.R:list#1"
  ))
})

test_that("unresolvable and duplicate tar_map() calls fail clearly", {
  none <- list("_targets.R" = c("x <- 1", "tar_map(values = list(a = 1))"))
  expect_error(read_source_text(none), "_targets.R:2.*no templates")
  same <- list("_targets.R" = c(
    "tar_map(values = list(a = 1), tar_target(t, 1))",
    "tar_map(values = list(a = 1), tar_target(t, 1))"
  ))
  expect_error(read_source_text(same), "_targets.R:2.*_targets.R:1")
})
