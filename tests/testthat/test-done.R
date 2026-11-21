# One definition of "done" (passes qa_check()) everywhere, and a truthful PDF.

test_that("report counts follow qa_check(): self-reviewed and unknown authorship are open", {
  repo <- reviewed_repo()
  st <- qa_status(repo)
  # Ann (the author) reviews g again as questionable: no longer passing
  suppressMessages(qa_review("function:g", "questionable", "still unsure", path = repo))
  d <- report_data(repo)
  expect_equal(d$counts$questionable, 0)
  expect_equal(d$counts$wrong_open, 1)
  expect_equal(d$open[[1]]$verdict, "self_reviewed")
  expect_equal(d$counts$correct + d$counts$questionable + d$counts$wrong_open, d$counts$items)

  # an entry without author email: authorship unknown, open, not "correct"
  items <- read_source(repo)$items
  write_review(repo, list(
    item = "function:f", hash = items$hash[items$id == "function:f"], verdict = "correct",
    comment = NA_character_, reviewer = "Bob", reviewer_email = "bob@wig2.de", author = "Ann",
    author_email = NA_character_, date = "2099-01-01T00:00:00.000Z", commit = git_head(repo), depends = list()
  ))
  d <- report_data(repo)
  expect_false(d$passed)
  expect_true("authorship_unknown" %in% vapply(d$open, `[[`, "", "verdict"))
})

test_that("check_again passes and is counted as correct in the report", {
  repo <- reviewed_repo()
  commit_as(repo, "R/a.R", c("#' Constant one", "#'", "#' @return One.", "f <- function() 1",
                             "", "#' Add one to the input", "g <- function(x) x + f() + 0"))
  set_git_user(repo, "Bob", "bob@wig2.de")
  suppressMessages(qa_review("function:g", "questionable", "still x = NA", path = repo))
  st <- qa_status(repo)
  expect_true(any(st$status == "check_again"))
  expect_message(expect_message(qa_check(repo), "check again: function:h, target:t1"), "passed")
  d <- report_data(repo)
  expect_true(d$passed)
  expect_equal(d$counts$wrong_open, 0)
  expect_output(print(st), "Check again \\(passes\\):")
  expect_output(print(st), "Questionable \\(passes, with doubt\\):")
  expect_false(any(grepl("Not passing", capture.output(print(st)))))
})

test_that("the report states its scope and why code from outside makes it a draft", {
  repo <- reviewed_repo()
  d <- report_data(repo)
  expect_equal(d$scope, "Scope: all R code in R/ and _targets.R. Data files are not reviewed.")
  expect_true(d$analysts_complete)
  commit_as(repo, "_targets.R", c("library(targets)", "source('scripts/h.R')", "list(", "  tar_target(t1, g(1)),",
                                  "  tar_target(t2, h(t1))", ")"))
  d <- report_data(repo)
  expect_false(d$passed)
  expect_equal(d$draft_reason, "external")
  expect_equal(unlist(d$external), "scripts/h.R")
  tpl <- readLines(system.file("report", "qa-report.qmd", package = "pipeworks"))
  expect_true(any(grepl(paste0(
    "Every function, target and top-level code block in this code version was reviewed by a second analyst ",
    "other than the person who last changed it. Each verdict refers to the exact code identified by its hash; ",
    "code that changed after a review was reviewed again."
  ), tpl, fixed = TRUE)))
  expect_false(any(grepl("who did not write it", tpl, fixed = TRUE)))
})

test_that("report sources are named in the scope", {
  st <- data.frame(file = c("R/a.R", "report.Rmd"), kind = c("function", "file"))
  expect_equal(report_scope(st), paste(
    "Scope: all R code in R/ and _targets.R and the report sources (report.Rmd).",
    "Data files are not reviewed."
  ))
})

test_that("the editor counts done like qa_check() and lists items without a box", {
  skip_if_no_targets()
  skip_if_not(git_available())
  repo <- example_project(file.path(withr::local_tempdir(), "s"), git = TRUE)
  m <- read_pipeline(repo, status = FALSE)
  s <- m$qa_summary
  st <- qa_status(repo)
  expect_equal(s$done, sum(qa_passing(st)))
  outside <- vapply(s$outside, `[[`, "", "item")
  expect_true("object:R/report.R:pipeline_report" %in% outside)
  expect_true("function:rescale01" %in% outside)  # a helper no target runs
  expect_false("file:report.Rmd" %in% outside)
  expect_false("target:hist_raw" %in% outside)
  expect_false(Filter(function(o) o$item == "object:R/report.R:pipeline_report", s$outside)[[1]]$passing)
  rep <- by_name(m$targets, "report")
  expect_equal(rep$qa_file$item, "file:report.Rmd")
  # every item is either behind a box or listed outside
  boxed <- unique(c(unlist(lapply(m$targets, function(t) c(t$qa$item, t$qa_file$item))),
                    unlist(lapply(m$functions, function(f) if (length(f$used_by)) f$qa$item)),
                    vapply(m$maps, `[[`, "", "id")))
  expect_setequal(union(boxed, outside), st$id)
})
