fns <- read_functions(example_dir())
tars <- c("raw_file", "raw_data", "clean_data", "regions", "features", "model_fit")

test_that("arguments are matched to formals even when names differ", {
  call <- target_call("read_survey(raw_file)", fns, tars)
  expect_equal(call$mode, "function")
  expect_equal(call$fn, "read_survey")
  expect_equal(call$args, list(
    list(name = "path", value = "raw_file", kind = "target", named = FALSE, targets = "raw_file")
  ))
})

test_that("constants are not dependencies", {
  call <- target_call('score_histogram(raw_data, title = "Raw")', fns, tars)
  expect_equal(vapply(call$args, `[[`, "", "kind"), c("target", "constant"))
  expect_equal(call$args[[2]]$value, '"Raw"')
  expect_true(call$args[[2]]$named)
  expect_length(call$args[[2]]$targets, 0)
})

test_that("expression arguments list the targets they use", {
  call <- target_call("summarise_region(clean_data[1:10, ], regions)", fns, tars)
  expect_equal(call$args[[1]]$kind, "expression")
  expect_equal(call$args[[1]]$targets, "clean_data")
})

test_that("commands that do not call a project function are expressions", {
  expect_equal(target_call('"data/survey.csv"', fns, tars)$mode, "expression")
  expect_equal(target_call("levels(clean_data$region)", fns, tars)$mode, "expression")
  expect_equal(target_call("this is not R", fns, tars)$mode, "expression")
})

test_that("tarchetypes factories are recognised with their source file", {
  cmd <- 'tarchetypes::tar_render_run(path = "report.Rmd", args = list(input = "report.Rmd"), deps = list(a, b))'
  call <- target_call(cmd, fns, tars)
  expect_equal(call$mode, "factory")
  expect_equal(call$factory, "tar_render")
  expect_equal(call$source, "report.Rmd")
})
