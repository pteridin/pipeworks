test_that("the example pipeline is read completely", {
  skip_if_no_targets()
  m <- read_example()
  expect_s3_class(m, "pipeworks_model")
  expect_length(m$targets, 17)
  expect_length(m$functions, 11)
  expect_null(m$families)
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

test_that("every target sits in the block (file) it is written in", {
  skip_if_no_targets()
  m <- read_example()
  blocks <- vapply(m$targets, function(t) t$block %||% NA_character_, "")
  names(blocks) <- vapply(m$targets, `[[`, "", "name")
  expect_equal(unname(blocks[c("raw_file", "raw_data", "clean_data", "regions")]), rep("R/import.R", 4))
  expect_equal(unname(blocks[c("features", "model_fit_base", "model_fit_full", "predictions")]), rep("R/model.R", 4))
  expect_equal(unname(blocks[c("hist_raw", "region_summary", "coef_plot", "report")]), rep("R/report.R", 4))
  # the spanning map: templates from two blocks
  expect_equal(unname(blocks[c("area_data_urban", "area_data_rural")]), rep("R/import.R", 2))
  expect_equal(unname(blocks[c("area_hist_urban", "area_hist_rural")]), rep("R/report.R", 2))
  expect_equal(m$blocks, c("R/import.R", "R/model.R", "R/report.R"))
  # functions keep their roxygen @family as plain data
  expect_equal(by_name(m$functions, "read_survey")$family, "Data import")
})

test_that("tar_map targets know their map, template and variant", {
  skip_if_no_targets()
  m <- read_example()
  expect_equal(by_name(m$targets, "model_fit_full")$map, list(id = "map:model_fit", template = "model_fit", variant = "full"))
  expect_equal(by_name(m$targets, "area_hist_rural")$map, list(id = "map:area_data+area_hist", template = "area_hist", variant = "rural"))
  expect_null(by_name(m$targets, "features")$map)

  maps <- m$maps
  expect_length(maps, 2)
  ids <- vapply(maps, `[[`, "", "id")
  fit <- maps[[which(ids == "map:model_fit")]]
  area <- maps[[which(ids == "map:area_data+area_hist")]]
  expect_equal(fit$templates, "model_fit")
  expect_equal(fit$variants, c("base", "full"))
  expect_equal(fit$param, "spec")
  expect_equal(area$templates, c("area_data", "area_hist"))
  expect_equal(area$variants, c("urban", "rural"))
  expect_equal(area$param, "area")
  expect_setequal(vapply(maps, `[[`, 1L, "color_index"), 1:2)
})

test_that("dynamic branches carry a branch count (NULL before a run)", {
  skip_if_no_targets()
  m <- read_example()
  expect_true("branches" %in% names(by_name(m$targets, "region_summary")))
  expect_null(by_name(m$targets, "region_summary")$branches)
})

test_that("outside git the model has no QA overlay", {
  skip_if_no_targets()
  m <- read_example()
  expect_true("qa_summary" %in% names(m))
  expect_null(m$qa_summary)
  expect_null(by_name(m$targets, "raw_data")$qa)
})

test_that("in a git repository targets and functions carry their QA status", {
  skip_if_no_targets()
  skip_if_not(git_available())
  repo <- local_example_repo()
  m <- read_pipeline(repo, status = FALSE)

  s <- m$qa_summary
  expect_false(is.null(s))
  expect_equal(s$base, "main")
  expect_equal(s$branch, "dev/sample-definition")
  expect_equal(s$open + s$done + s$wrong, s$total)
  expect_equal(s$wrong, 0)
  # 3 open items + the rest of R/report.R (a target was added to the list);
  # target:clean_data is check again, which passes
  expect_equal(s$open, 4)
  expect_equal(s$check_again, 1)

  cc <- by_name(m$targets, "channel_counts")$qa
  expect_equal(cc$item, "target:channel_counts")
  expect_equal(cc$status, "unreviewed")
  expect_null(cc$verdict)
  expect_true(cc$changed_vs_base)

  # all variants of a template share its item
  fit <- by_name(m$targets, "model_fit_base")$qa
  expect_equal(fit$item, "target:model_fit")
  expect_equal(fit$status, "correct")
  expect_equal(fit$reviewer, "S. Senior")

  sr <- by_name(m$functions, "summarise_region")$qa
  expect_equal(sr$status, "questionable")
  expect_equal(sr$verdict, "questionable")
  expect_false(sr$self_reviewed)
  expect_equal(s$done, 36)
  expect_length(sr$history, 1)
  expect_match(sr$history[[1]]$comment, "Group by region")

  expect_equal(by_name(m$functions, "clean_survey")$qa$status, "changed")
  # the diff against base: the item's text now and at `main`
  cs <- by_name(m$functions, "clean_survey")$qa
  expect_match(cs$text, "age >= 18", fixed = TRUE)
  expect_false(grepl("age >= 18", cs$base_text, fixed = TRUE))
  expect_match(cs$base_text, "^clean_survey <- function")
  # new in this branch: no base text
  expect_null(cc$base_text)
  expect_match(cc$text, "channel_counts")
  # unchanged against base: no texts at all
  expect_null(fit$text)
  expect_equal(by_name(m$targets, "clean_data")$qa$status, "check_again")

  maps <- m$maps
  expect_equal(maps[[1]]$qa$item, maps[[1]]$id)
})

test_that("a folder without _targets.R is an error", {
  expect_error(read_pipeline(withr::local_tempdir()), "No _targets.R")
})

test_that("functions and targets carry a base hash of their raw lines", {
  skip_if_no_targets()
  m <- read_example()
  f <- by_name(m$functions, "read_survey")
  lines <- read_utf8(file.path(m$root, f$file))
  expect_equal(f$base, item_base(lines, f$doc_line, f$end_line))
  expect_equal(by_name(m$targets, "model_fit_full")$base, by_name(m$targets, "model_fit_base")$base)
  with_item <- Filter(function(t) !is.null(t$block), m$targets)
  expect_gt(length(with_item), 0)
  expect_true(all(vapply(with_item, function(t) nchar(t$base) == 32L, logical(1))))
})
