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
  expect_true("+     dplyr::filter(is.na(age) | age >= 18) |>" %in% out)
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

show_out <- function(repo, ...) capture.output(qa_walk(repo, ..., input = scripted(rep("s", 10))$input))

test_that("a changed item shows hunks, not its full body twice", {
  repo <- walk_repo()
  out <- show_out(repo, include = "open")
  i <- which(out == "[1/4] function:clean_survey  (changed, last changed by A. Analyst)")
  expect_length(i, 1)
  block <- out[i:(which(grepl("^\\[2/4\\]", out))[1] - 1L)]
  expect_true("--- R/import.R:34-45  (diff against main)" %in% block)
  expect_true(any(grepl("^@@ lines [0-9]+-[0-9]+ @@$", block)))
  expect_true("+     dplyr::filter(is.na(age) | age >= 18) |>" %in% block)
  expect_true("  clean_survey <- function(raw_data) {" %in% block)
  expect_false("clean_survey <- function(raw_data) {" %in% block)
  # the last body line is beyond the 3 context lines
  expect_false(any(grepl("channel = factor", block)))
})

test_that("a new item shows its full code and says it is new", {
  repo <- walk_repo()
  out <- show_out(repo, include = "open")
  i <- which(grepl("^\\[[0-9]/4\\] function:count_by_channel", out))
  expect_equal(out[i + 1], "--- R/report.R:76-78")
  expect_equal(out[i + 2:4], c("count_by_channel <- function(data) {", "  dplyr::count(data, channel)", "}"))
  expect_equal(out[i + 5], "(new item: not present at the base)")
})

test_that("target items show their code, a check_again item names the changed callee", {
  repo <- walk_repo()
  out <- show_out(repo, include = "check_again")
  expect_true("[1/1] target:clean_data  (check_again, last changed by A. Analyst)" %in% out)
  i <- which(out == "--- R/import.R:72-72")
  expect_length(i, 1)
  expect_match(out[i + 1], "^ *tar_target\\(clean_data")
  expect_true("This item is unchanged; a function it calls changed since the review:" %in% out)
  expect_true("Changed callee: function:clean_survey" %in% out)
  expect_true("+     dplyr::filter(is.na(age) | age >= 18) |>" %in% out)
  expect_false("(no change)" %in% out)
})

test_that("include = 'check_again' alone walks only that item", {
  repo <- walk_repo()
  s <- scripted("c")
  out <- capture.output(res <- qa_walk(repo, include = "check_again", input = s$input))
  expect_equal(res$item, "target:clean_data")
  expect_equal(s$calls(), 1)
})

test_that("without main or master there is no diff and the code is shown in full", {
  repo <- walk_repo()
  git_run(repo, c("branch", "-m", "main", "trunk"))
  out <- show_out(repo, include = "open")
  expect_true("(no diff: no `main` or `master` branch to compare with)" %in% out)
  expect_true("clean_survey <- function(raw_data) {" %in% out)
  expect_false(any(grepl("^@@", out)))
})

test_that("reviewing on the base branch itself says so", {
  repo <- walk_repo()
  out <- show_out(repo, base = "dev/sample-definition", include = "open")
  expect_true("(no diff: you are on dev/sample-definition)" %in% out)
  expect_false("(no change)" %in% out)
})

test_that("a failed commit stops the walk", {
  skip_on_os("windows")
  repo <- walk_repo()
  hook <- file.path(repo, ".git", "hooks", "pre-commit")
  dir.create(dirname(hook), showWarnings = FALSE)
  writeLines(c("#!/usr/bin/env Rscript", "quit(status = 1)"), hook)
  Sys.chmod(hook, "755")
  s <- scripted(rep("c", 5))
  out <- capture.output(res <- qa_walk(repo, include = "open", input = s$input))
  expect_equal(nrow(res), 1)
  expect_false(res$committed)
  expect_equal(s$calls(), 1)
  expect_true("Stopping the walk." %in% out)
  expect_true(any(grepl("^Saved correct for .* but could not commit it", out)))
})

test_that("diff_hunks separates distant changes", {
  old <- as.character(1:30)
  new <- old
  new[2] <- "two"
  new[28] <- "twenty-eight"
  h <- diff_hunks(line_diff(old, new), 100L)
  expect_equal(sum(grepl("^@@", h)), 2)
  expect_equal(h[1], "@@ lines 100-104 @@")
  expect_true("+ twenty-eight" %in% h)
  expect_false("  15" %in% h)
})
