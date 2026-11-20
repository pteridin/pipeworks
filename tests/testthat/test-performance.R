# The gate, the report and the editor never walk the git history; the history
# walk reads each file version once.

test_that("qa_check(), report_data() and read_pipeline() do not read authors from git", {
  skip_if_not(git_available())
  repo <- reviewed_repo()
  commit_as(repo, "R/b.R", c("#' Double the input", "h <- function(x) g(x) * 3"))  # h is changed
  ex <- if (requireNamespace("tarchetypes", quietly = TRUE)) example_project(file.path(withr::local_tempdir(), "s"), git = TRUE)
  local_mocked_bindings(last_authors = function(...) stop("the git history was read"))
  expect_error(suppressMessages(qa_check(repo)), "1 changed")
  expect_false(report_data(repo)$passed)
  st <- qa_status(repo, authors = FALSE)
  expect_true(is.na(st$last_author[st$id == "function:h"]))
  expect_equal(st$last_author[st$id == "function:f"], "Ann")  # from the review entry
  expect_error(qa_status(repo), "the git history was read")
  skip_if_no_targets()
  expect_false(is.null(read_pipeline(ex, status = FALSE)$qa_summary))
})

test_that("each file version is read and parsed once across the history", {
  skip_if_not(git_available())
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "R/b.R" = "g <- function() 1", "_targets.R" = "list()"))
  for (i in 1:5) commit_as(repo, "R/b.R", paste0("g <- function() ", i + 1))
  commit_as(repo, "README.md", "docs only")  # same code as its parent
  parses <- 0L
  real <- parse_source_file
  local_mocked_bindings(parse_source_file = function(...) { parses <<- parses + 1L; real(...) })
  la <- last_authors(repo, read_source(repo)$items)
  parses_history <- parses - 3L  # read_source() itself parsed the 3 files
  # versions: a.R 1, b.R 6, _targets.R 1
  expect_lte(parses_history, 8L)
  expect_equal(la$author_email[la$id == "function:f"], "ann@wig2.de")
})
