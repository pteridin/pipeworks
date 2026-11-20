test_that("every top-level function is found with its source location", {
  fns <- read_functions(example_dir())
  expect_setequal(names(fns), c(
    "read_survey", "clean_survey", "build_features", "fit_score_model", "predict_scores",
    "score_histogram", "summarise_region", "plot_coefficients", "rescale01", "select_area", "area_histogram"
  ))
  f <- fns$read_survey
  expect_equal(f$file, "R/import.R")
  expect_equal(f$doc_line, 1)
  expect_equal(f$line, 9)
  expect_equal(f$end_line, 24)
})

test_that("roxygen fields are read", {
  f <- read_functions(example_dir())$clean_survey
  expect_equal(f$title, "Clean and deduplicate responses")
  expect_match(f$description, "Drops test submissions")
  expect_equal(f$params, list(raw_data = "Raw submissions as returned by [read_survey()]."))
  expect_match(f$returns, "^A tibble")
  expect_equal(f$family, "Data import")
})

test_that("missing documentation is reported as missing, not invented", {
  fns <- read_functions(example_dir())
  expect_length(fns$build_features$params, 0)
  expect_true(is.na(fns$predict_scores$returns))
  expect_true(is.na(fns$summarise_region$family))
  expect_equal(fns$rescale01$keywords, "internal")
})

test_that("formals keep their defaults and the body is dedented", {
  fns <- read_functions(example_dir())
  expect_equal(fns$score_histogram$formals, list(
    list(name = "data", default = NA_character_),
    list(name = "title", default = NA_character_)
  ))
  expect_equal(fns$fit_score_model$formals[[2]]$name, "spec")
  expect_match(fns$fit_score_model$body, "spec")
})

test_that("calls between project functions are linked", {
  fns <- read_functions(example_dir())
  expect_equal(fns$build_features$calls, "rescale01")
  expect_equal(fns$rescale01$called_by, "build_features")
})

test_that("a project without R/ has no functions", {
  dir <- withr::local_tempdir()
  expect_equal(read_functions(dir), list())
})
