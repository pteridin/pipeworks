test_that("wb_function finds doc block, formals and body of read_survey", {
  p <- wb_parse(read_utf8(file.path(example_dir(), "R/import.R")), "R/import.R")
  f <- wb_function(p, "read_survey")
  expect_equal(c(f$doc1, f$line1), c(1L, 9L))
  expect_equal(f$formals$name, "path")
  expect_true(f$body_braced)
  expect_null(wb_function(p, "nope"))
})

test_that("wb_function spans cover `name = default` and the parens", {
  lines <- c("#' T", "f <- function(a, b = c(1, 2),", "                c) a + b")
  f <- wb_function(wb_parse(lines, "R/f.R"), "f")
  expect_equal(f$formals$name, c("a", "b", "c"))
  expect_equal(c(f$formals$line1[2], f$formals$col1[2], f$formals$line2[2], f$formals$col2[2]), c(2L, 18L, 2L, 28L))
  expect_equal(unname(f$close_paren), c(3L, 18L))
  expect_false(f$body_braced)
})

test_that("wb_target finds calls in lists, in tar_map() and in template holders", {
  p <- wb_parse(read_utf8(file.path(example_dir(), "R/model.R")), "R/model.R")
  expect_equal(wb_target(p, "model_fit")$fn, "tar_target")
  expect_equal(wb_target(p, "predictions")$args$text[2], "predict_scores(model_fit_full, features)")
  pi <- wb_parse(read_utf8(file.path(example_dir(), "R/import.R")), "R/import.R")
  expect_equal(wb_target(pi, "raw_file")$args$name, c("", "", "format", "description"))
  expect_false(is.null(wb_target(pi, "area_data")))
  expect_null(wb_target(pi, "nope"))
})

test_that("wb_target handles namespaced calls and exposes the command", {
  lines <- c("x <- list(", "  targets::tar_target(a, f(b), format = \"qs\"),", "  tar_target(command = g(a), name = z)", ")")
  p <- wb_parse(lines, "R/x.R")
  a <- wb_target(p, "a")
  expect_equal(a$fn, "tar_target")
  expect_equal(p$pd$text[p$pd$id == a$cmd_id & p$pd$terminal], character())
  expect_equal(a$args$text, c("a", "f(b)", "\"qs\""))
  z <- wb_target(p, "z")
  expect_equal(z$args$name, c("command", "name"))
  expect_equal(unname(z$close_paren), c(3L, 38L))
  expect_equal(wb_block_list(p, "x")$args$text[1], "targets::tar_target(a, f(b), format = \"qs\")")
  expect_null(wb_block_list(p, "y"))
})

test_that("wb_composition finds the list of blocks in _targets.R", {
  p <- wb_parse(read_utf8(file.path(example_dir(), "_targets.R")), "_targets.R")
  expect_equal(nrow(wb_composition(p)$args), 4L)
  expect_null(wb_composition(wb_parse("list(1, 2)", "_targets.R")))
})

test_that("wb_parse reports unparsable files and item_base hashes raw lines", {
  expect_error(wb_parse("f <- (", "R/bad.R"), "Cannot parse R/bad.R")
  expect_equal(item_base(c("a", "b", "c"), 2L, 3L), md5_lines(c("b", "c")))
})
