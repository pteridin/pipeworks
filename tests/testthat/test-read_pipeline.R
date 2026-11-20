test_that("the example pipeline is read completely", {
  skip_if_no_targets()
  m <- read_example()
  expect_s3_class(m, "pipeworks_model")
  expect_length(m$targets, 17)
  expect_length(m$functions, 11)
  expect_equal(m$families, c("Data import", "Modelling", "Reporting"))
  modes <- table(vapply(m$targets, `[[`, "", "mode"))
  expect_equal(as.vector(modes[c("function", "expression", "factory")]), c(14, 2, 1))
  expect_setequal(vapply(m$targets, `[[`, "", "name"), c(
    "raw_file", "raw_data", "clean_data", "regions", "features",
    "model_fit_base", "model_fit_full", "predictions",
    "hist_raw", "hist_clean", "region_summary", "coef_plot", "report",
    "area_data_urban", "area_data_rural", "area_hist_urban", "area_hist_rural"
  ))
})

test_that("a project that was never built is 'new'", {
  skip_if_no_targets()
  m <- read_example()
  expect_true(all(vapply(m$targets, `[[`, "", "status") == "new"))
})

test_that("dependencies include those of target factories", {
  skip_if_no_targets()
  m <- read_example()
  report <- by_name(m$targets, "report")
  expect_equal(report$mode, "factory")
  expect_equal(report$source, "report.Rmd")
  expect_setequal(report$deps, c(
    "coef_plot", "hist_clean", "hist_raw", "predictions", "region_summary",
    "area_hist_urban", "area_hist_rural"
  ))
})

test_that("a shared function lists every target that uses it", {
  skip_if_no_targets()
  m <- read_example()
  expect_setequal(by_name(m$functions, "score_histogram")$used_by, c("hist_raw", "hist_clean"))
  expect_length(by_name(m$functions, "rescale01")$used_by, 0)
})

test_that("tar_map variants are separate targets with substituted arguments", {
  skip_if_no_targets()
  m <- read_example()
  expect_equal(by_name(m$targets, "model_fit_base")$command, "fit_score_model(features, \"base\")")
  expect_equal(by_name(m$targets, "model_fit_full")$command, "fit_score_model(features, \"full\")")
  expect_equal(by_name(m$targets, "predictions")$deps, c("features", "model_fit_full"))
  expect_equal(by_name(m$targets, "area_data_rural")$command, "select_area(clean_data, \"rural\")")
  expect_equal(by_name(m$targets, "area_hist_urban")$deps, "area_data_urban")
})

test_that("patterns, formats and descriptions come from the manifest", {
  skip_if_no_targets()
  m <- read_example()
  expect_equal(by_name(m$targets, "region_summary")$pattern, "map(regions)")
  expect_equal(by_name(m$targets, "raw_file")$format, "file")
  expect_equal(by_name(m$targets, "raw_file")$description, "Raw survey export, tracked as a file.")
})

test_that("source files are included for the code view", {
  skip_if_no_targets()
  m <- read_example()
  expect_equal(
    vapply(m$files, `[[`, "", "path"),
    c("_targets.R", "R/import.R", "R/model.R", "R/report.R", "R/utils.R", "report.Rmd")
  )
})

test_that("a folder without _targets.R is an error", {
  expect_error(read_pipeline(withr::local_tempdir()), "No _targets.R")
})
