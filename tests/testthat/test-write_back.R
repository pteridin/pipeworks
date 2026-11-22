test_that("set_doc on read_survey changes only its title line", {
  x <- wb_example(); before <- wb_lines(x$files, "R/import.R")
  out <- chg_set_doc(x$files, list(kind = "set_doc", fn = "read_survey", field = "title", value = "Read the export"))
  after <- wb_lines(out, "R/import.R")
  expect_equal(after[1], "#' Read the export"); expect_equal(after[-1], before[-1])
  # copy semantics: the input is untouched
  expect_equal(wb_lines(x$files, "R/import.R"), before)
})

test_that("set_doc creates a block for an undocumented function and rejects unknown ones", {
  dir <- local_project(list("R/a.R" = c("f <- function(x) x", "", "g <- 1")))
  files <- wb_files(dir)
  out <- chg_set_doc(files, list(fn = "f", field = "title", value = "Identity"))
  expect_equal(wb_lines(out, "R/a.R"), c("#' Identity", "f <- function(x) x", "", "g <- 1"))
  expect_error(chg_set_doc(files, list(fn = "nope", field = "title", value = "x")), class = "pipeworks_bad_change")
})

test_that("set_doc edits a param and keeps other tags", {
  x <- wb_example()
  out <- chg_set_doc(x$files, list(fn = "select_area", field = "param", param = "area", value = "The area."))
  l <- wb_lines(out, "R/import.R")
  expect_true("#' @param area The area." %in% l)
  expect_true("#' @param data Clean responses with an `area` column." %in% l)
})

test_that("set_formals adds a formal and keeps the others' text", {
  x <- wb_example()
  out <- chg_set_formals(x$files, list(fn = "score_histogram",
    formals = list(list(name = "data", default = NULL), list(name = "title", default = NULL), list(name = "bins", default = "NULL"))))
  expect_true(any(wb_lines(out, "R/report.R") == "score_histogram <- function(data, title, bins = NULL) {"))
})

test_that("set_formals removes, changes defaults and keeps untouched formatting", {
  dir <- local_project(list("R/a.R" = c("f <- function(a,", "                b = 1,", "                c) {", "  a", "}")))
  files <- wb_files(dir)
  out <- chg_set_formals(files, list(fn = "f", formals = list(list(name = "a"), list(name = "b", default = "2"), list(name = "c"))))
  expect_equal(wb_lines(out, "R/a.R")[1:3], c("f <- function(a,", "                b = 2,", "                c) {"))
  out <- chg_set_formals(files, list(fn = "f", formals = list(list(name = "b", default = "1"), list(name = "c"))))
  expect_equal(wb_lines(out, "R/a.R")[1:3], c("f <- function(", "                b = 1,", "                c) {"))
  out <- chg_set_formals(files, list(fn = "f", formals = list(list(name = "a"))))
  expect_equal(wb_lines(out, "R/a.R")[1:2], c("f <- function(a", "                ) {"))
  out <- chg_set_formals(files, list(fn = "f", formals = list(list(name = "a"), list(name = "b", default = "1"), list(name = "d"))))
  expect_equal(wb_lines(out, "R/a.R")[1:3], c("f <- function(a,", "                b = 1,", "                d"))
})

test_that("set_body re-indents and keeps the signature", {
  x <- wb_example()
  out <- chg_set_body(x$files, list(fn = "select_area", body = "x <- 1\ndata"))
  l <- wb_lines(out, "R/import.R"); i <- which(l == "select_area <- function(data, area) {")
  expect_equal(l[i + 1:3], c("  x <- 1", "  data", "}"))
})

test_that("set_body refuses a function without braced body", {
  dir <- local_project(list("R/a.R" = "f <- function(x) x + 1"))
  expect_error(chg_set_body(wb_files(dir), list(fn = "f", body = "x")), "f() has no braced body; change it in RStudio.", fixed = TRUE,
    class = "pipeworks_bad_change")
})

test_that("set_call plugs an argument into raw_data's command, keeping the arg name differing from the target", {
  x <- wb_example()
  out <- chg_set_call(x$files, list(target = "raw_data", args = list(
    list(name = "path", value = "raw_file", named = FALSE), list(name = "regions", value = "regions", named = TRUE))))
  expect_true(any(grepl("tar_target(raw_data, read_survey(raw_file, regions = regions))", wb_lines(out, "R/import.R"), fixed = TRUE)))
})

test_that("set_call removes and replaces arguments by (name, value)", {
  x <- wb_example()
  out <- chg_set_call(x$files, list(target = "hist_raw", args = list(
    list(name = "data", value = "clean_data", named = FALSE), list(name = "title", value = '"Raw submissions"', named = TRUE))))
  expect_true(any(grepl('tar_target(hist_raw, score_histogram(clean_data, title = "Raw submissions"))', wb_lines(out, "R/report.R"), fixed = TRUE)))
  out <- chg_set_call(x$files, list(target = "hist_raw", args = list(list(name = "data", value = "raw_data", named = FALSE))))
  expect_true(any(grepl("tar_target(hist_raw, score_histogram(raw_data))", wb_lines(out, "R/report.R"), fixed = TRUE)))
})

test_that("set_target_arg replaces, appends and removes format/pattern/description", {
  x <- wb_example()
  out <- chg_set_target_arg(x$files, list(target = "raw_file", arg = "format", value = NULL))
  expect_false(any(grepl('format = "file"', wb_lines(out, "R/import.R"))))
  expect_true(any(grepl('description = "Raw survey export, tracked as a file."', wb_lines(out, "R/import.R"), fixed = TRUE)))
  out <- chg_set_target_arg(x$files, list(target = "clean_data", arg = "format", value = "qs"))
  expect_true(any(grepl('tar_target(clean_data, clean_survey(raw_data), format = "qs")', wb_lines(out, "R/import.R"), fixed = TRUE)))
  out <- chg_set_target_arg(x$files, list(target = "raw_file", arg = "format", value = "qs"))
  expect_true(any(grepl('format = "qs",', wb_lines(out, "R/import.R"), fixed = TRUE)))
})

test_that("set_target_arg appends on its own line to a multi-line call and quotes strings", {
  x <- wb_example()
  out <- chg_set_target_arg(x$files, list(target = "regions", arg = "pattern", value = "map(raw_file)"))
  l <- wb_lines(out, "R/import.R"); i <- grep("^    levels\\(droplevels", l)
  expect_equal(l[i:(i + 3)], c("    levels(droplevels(clean_data$region)),",
    '    description = "Regions present after cleaning.",', "    pattern = map(raw_file)", "  )"))
  out <- chg_set_target_arg(x$files, list(target = "clean_data", arg = "description", value = 'Say "hi" \\ now'))
  expect_true(any(grepl('description = "Say \\"hi\\" \\\\ now"', wb_lines(out, "R/import.R"), fixed = TRUE)))
})

test_that("a CRLF file keeps its line endings through a change", {
  dir <- local_project(list())
  writeBin(charToRaw("f <- function(a) {\r\n  a\r\n}\r\n"), file.path(dir, "x.R"))
  dir.create(file.path(dir, "R")); file.rename(file.path(dir, "x.R"), file.path(dir, "R", "x.R"))
  out <- chg_set_formals(wb_files(dir), list(fn = "f", formals = list(list(name = "a"), list(name = "b"))))
  txt <- wb_files_get(out, "R/x.R")
  expect_equal(txt$eol, "\r\n"); expect_true(txt$final_nl)
  expect_equal(txt$lines[1], "f <- function(a, b) {")
})

wb_formals_fixture <- function(env = parent.frame()) {
  dir <- local_project(list("R/a.R" = c(
    "f <- function(a, # first", "               # between", "               b, # second",
    "               c # third", ") {", "  a", "}")), env)
  wb_files(dir)
}
wb_comments <- function(l) sort(regmatches(l, regexpr("#.*$", l)))

test_that("removing a formal never deletes other comments", {
  files <- wb_formals_fixture()
  keep <- function(drop, comments) {
    want <- Filter(function(n) n != drop, c("a", "b", "c"))
    out <- chg_set_formals(files, list(fn = "f", formals = lapply(want, function(n) list(name = n))))
    l <- wb_lines(out, "R/a.R")
    expect_equal(wb_comments(l), sort(comments))
    expect_false(any(grepl(paste0("^\\s*", drop, "\\b[ ,]"), l)))
    l
  }
  keep("a", c("# first", "# between", "# second", "# third"))
  keep("b", c("# first", "# between", "# third"))
  l <- keep("c", c("# first", "# between", "# second"))
  expect_true(any(grepl("^\\s*b # second$", l)))
  # the result still parses
  expect_no_error(parse(text = l))
})

test_that("removing call arguments keeps comments and inline layout", {
  dir <- local_project(list("R/a.R" = c(
    "x <- list(", "  tar_target(", "    t,", "    f(a, # one", "      # own line", "      b, # two",
    "      c), # three", "    format = \"qs\"", "  )", ")")))
  files <- wb_files(dir)
  out <- chg_set_call(files, list(target = "t", args = list(
    list(name = "", value = "a", named = FALSE), list(name = "", value = "b", named = FALSE))))
  l <- wb_lines(out, "R/a.R")
  expect_equal(wb_comments(l), c("# one", "# own line", "# three", "# two"))
  expect_no_error(parse(text = l))
  out <- chg_set_call(files, list(target = "t", args = list(list(name = "", value = "b", named = FALSE),
    list(name = "", value = "c", named = FALSE))))
  l <- wb_lines(out, "R/a.R")
  expect_equal(wb_comments(l), c("# one", "# own line", "# three", "# two"))
  expect_false(any(grepl("^\\s*a\\b", l)))
  out <- chg_set_target_arg(files, list(target = "t", arg = "format", value = NULL))
  expect_equal(wb_comments(wb_lines(out, "R/a.R")), c("# one", "# own line", "# three", "# two"))
  dir2 <- local_project(list("R/a.R" = "f(a, b, c)\nx <- list(tar_target(t, g(p, q)))"))
  out <- chg_set_call(wb_files(dir2), list(target = "t", args = list(list(name = "", value = "p", named = FALSE))))
  expect_equal(wb_lines(out, "R/a.R")[2], "x <- list(tar_target(t, g(p)))")
})

test_that("set_body keeps the inner lines of a multi-line string verbatim", {
  dir <- local_project(list("R/a.R" = c("f <- function(x) {", "  x", "}")))
  out <- chg_set_body(wb_files(dir), list(fn = "f", body = "s <- \"a\n  b\nc\"\nx"))
  expect_equal(wb_lines(out, "R/a.R"), c("f <- function(x) {", "  s <- \"a", "  b", "c\"", "  x", "}"))
  expect_error(chg_set_body(wb_files(dir), list(fn = "f", body = "x <- (")), "does not parse", class = "pipeworks_bad_change")
})

test_that("a file that does not parse is reported instead of 'not found'", {
  dir <- local_project(list("R/a.R" = "f <- function(x) {", "R/b.R" = "g <- 1"))
  expect_error(chg_set_doc(wb_files(dir), list(fn = "g", field = "title", value = "x")), "Cannot parse|g\\(\\)", class = "pipeworks_bad_change")
  expect_error(chg_set_doc(wb_files(dir), list(fn = "zzz", field = "title", value = "x")), "Cannot parse", class = "pipeworks_bad_change")
})

# --- renames, removal, new targets -------------------------------------------

all_lines <- function(files) unlist(lapply(wb_rels(files), function(r) wb_lines(files, r)))

new_fn <- function(name, body = "", formals = list(), params = list()) {
  list(name = name, title = "Title", description = "", returns = "A value.", family = "",
    params = params, formals = formals, body = body)
}

test_that("rename_function renames the definition and calls, not pkg::calls", {
  x <- wb_example()
  out <- chg_rename_function(x$files, list(fn = "rescale01", to = "rescale_unit"))
  expect_true(any(grepl("^rescale_unit <- function", wb_lines(out, "R/utils.R"))))
  expect_equal(sum(grepl("rescale_unit(", wb_lines(out, "R/model.R"), fixed = TRUE)), 2L)
  expect_false(any(grepl("rescale01", all_lines(out))))
  expect_equal(attr(out, "notes"),
    "Renamed 2 call(s) of rescale01(); calls by string or in reports are not followed.")
})

test_that("rename_function leaves pkg::fn, strings and other symbols alone", {
  dir <- local_project(list(
    "R/a.R" = c("f <- function(x) x", "g <- function() {", "  f(1) + pkg::f(2) + pkg:::f(3)", "  lapply(1, f)", "  \"f\"", "}"),
    "_targets.R" = c("library(targets)", "tar_source()", "list(tar_target(t, f(2)))")))
  out <- chg_rename_function(wb_files(dir), list(fn = "f", to = "h"))
  expect_equal(wb_lines(out, "R/a.R"),
    c("h <- function(x) x", "g <- function() {", "  h(1) + pkg::f(2) + pkg:::f(3)", "  lapply(1, f)", "  \"f\"", "}"))
  expect_equal(wb_lines(out, "_targets.R")[3], "list(tar_target(t, h(2)))")
})

test_that("rename_function refuses taken names and duplicate definitions", {
  x <- wb_example()
  expect_error(chg_rename_function(x$files, list(fn = "rescale01", to = "clean_data")), "clean_data",
    class = "pipeworks_bad_change")
  expect_error(chg_rename_function(x$files, list(fn = "rescale01", to = "read_survey")), "read_survey",
    class = "pipeworks_bad_change")
  expect_error(chg_rename_function(x$files, list(fn = "nope", to = "x")), class = "pipeworks_bad_change")
  dir <- local_project(list("R/a.R" = "f <- function() 1", "R/b.R" = "f <- function() 2"))
  expect_error(chg_rename_function(wb_files(dir), list(fn = "f", to = "g")), "twice|2 times",
    class = "pipeworks_bad_change")
  expect_error(chg_set_doc(wb_files(dir), list(fn = "f", field = "title", value = "x")), "twice|2 times",
    class = "pipeworks_bad_change")
})

test_that("rename_target updates references and refuses map templates referenced by variant", {
  x <- wb_example()
  out <- chg_rename_target(x$files, list(target = "clean_data", to = "tidy_data"))
  model <- wb_lines(out, "R/model.R")
  expect_true(any(grepl("build_features(tidy_data)", model, fixed = TRUE)))
  # the formal of build_features() is not a target reference
  expect_true("build_features <- function(clean_data) {" %in% model)
  imp <- wb_lines(out, "R/import.R")
  expect_true("  tar_target(tidy_data, clean_survey(raw_data))," %in% imp)
  expect_true("    levels(droplevels(tidy_data$region))," %in% imp)
  expect_true("  tar_target(area_data, select_area(tidy_data, area))" %in% imp)
  expect_equal(sum(grepl("tidy_data", wb_lines(out, "R/report.R"))), 2L)
  expect_error(chg_rename_target(x$files, list(target = "model_fit", to = "fit")), "model_fit_full",
    class = "pipeworks_bad_change")
})

test_that("rename_target refuses a target read by the report", {
  x <- wb_example()
  expect_error(chg_rename_target(x$files, list(target = "predictions", to = "preds")), "report",
    class = "pipeworks_bad_change")
  # map template whose variants the report reads (tar_read(area_hist_urban))
  expect_error(chg_rename_target(x$files, list(target = "area_hist", to = "hist_area")), "report",
    class = "pipeworks_bad_change")
})

test_that("rename_target renames a template inside a map spanning two files", {
  x <- wb_example()
  out <- chg_rename_target(x$files, list(target = "area_data", to = "area_rows"))
  expect_true("  tar_target(area_rows, select_area(clean_data, area))" %in% wb_lines(out, "R/import.R"))
  expect_true("  tar_target(area_hist, area_histogram(area_rows, area))" %in% wb_lines(out, "R/report.R"))
})

test_that("rename_target refuses a taken name, a bad name and duplicates", {
  x <- wb_example()
  expect_error(chg_rename_target(x$files, list(target = "clean_data", to = "raw_data")), "raw_data",
    class = "pipeworks_bad_change")
  expect_error(chg_rename_target(x$files, list(target = "clean_data", to = "not a name")),
    class = "pipeworks_bad_change")
  dir <- local_project(list("R/a.R" = c("pipeline_a <- list(tar_target(x, 1))", "pipeline_b <- list(tar_target(x, 2))")))
  expect_error(chg_rename_target(wb_files(dir), list(target = "x", to = "y")), "twice|2 times",
    class = "pipeworks_bad_change")
})

test_that("remove_target cuts the call and its comma", {
  x <- wb_example()
  out <- chg_remove_target(x$files, list(target = "regions"))
  p <- wb_parse(wb_lines(out, "R/import.R"), "R/import.R")
  expect_null(wb_target(p, "regions")); expect_equal(nrow(wb_block_list(p, "pipeline_import")$args), 3L)
  l <- wb_lines(out, "R/import.R")
  expect_equal(tail(l, 2), c("  tar_target(clean_data, clean_survey(raw_data))", ")"))
  out <- chg_remove_target(x$files, list(target = "raw_data"))
  l <- wb_lines(out, "R/import.R")
  expect_false(any(grepl("raw_data, read_survey", l, fixed = TRUE)))
  expect_equal(nrow(wb_block_list(wb_parse(l, "R/import.R"), "pipeline_import")$args), 3L)
  expect_equal(length(l), length(wb_lines(x$files, "R/import.R")) - 1L)
})

test_that("remove_target refuses the only template of a tar_map()", {
  x <- wb_example()
  expect_error(chg_remove_target(x$files, list(target = "model_fit")), "only", class = "pipeworks_bad_change")
  # area_data is one of two templates of the map in _targets.R
  out <- chg_remove_target(x$files, list(target = "area_data"))
  expect_null(wb_target(wb_parse(wb_lines(out, "R/import.R"), "R/import.R"), "area_data"))
})

test_that("add_target keeps a trailing comment on the last element's line", {
  path <- local_project(list("_targets.R" = c("library(targets)", "tar_source()", "list(pipeline_a)"),
    "R/a.R" = c("f <- function() 1", "", "pipeline_a <- list(", "  tar_target(x, f()) # note", ")")))
  out <- chg_add_target(wb_files(path), list(target = "y", block = "R/a.R",
    fn = list(name = "g", title = "G", description = "", returns = "One.", family = "", params = list(), formals = list(), body = "1"),
    args = list(), format = NULL, pattern = NULL))
  l <- wb_lines(out, "R/a.R"); i <- which(l == "  tar_target(x, f()), # note")
  expect_equal(l[i + 1:2], c("  tar_target(y, g())", ")"))
  # function above the holder, with blank lines around it
  h <- which(l == "pipeline_a <- list(")
  expect_equal(l[h - 1L], "")
  expect_equal(l[h - 2L], "}")
  expect_true("g <- function() {" %in% l)
  expect_equal(l[which(l == "#' G") - 1L], "")
  expect_equal(wb_lines(out, "_targets.R"), wb_lines(wb_files(path), "_targets.R"))
})

test_that("add_target into a new file creates block and composition entry", {
  x <- wb_example()
  out <- chg_add_target(x$files, list(target = "report_table", block = "R/tables.R",
    fn = list(name = "make_table", title = "Make the table", description = "", returns = "A tibble.", family = "",
              params = list(predictions = "Predictions."), formals = list(list(name = "predictions", default = NULL)), body = ""),
    args = list(list(name = "predictions", value = "predictions", named = FALSE)), format = NULL, pattern = NULL))
  l <- wb_lines(out, "R/tables.R")
  expect_true(any(l == '  stop("Not implemented: make_table()")'))
  expect_true(any(grepl("tar_target(report_table, make_table(predictions))", l, fixed = TRUE)))
  expect_true(any(grepl("pipeline_tables", wb_lines(out, "_targets.R"))))
  expect_identical(out[["R/tables.R"]]$eol, "\n")
  expect_true(out[["R/tables.R"]]$final_nl)
  expect_false(file.exists(file.path(x$path, "R/tables.R")))
  comp <- wb_composition(wb_parse(wb_lines(out, "_targets.R"), "_targets.R"))
  expect_equal(tail(comp$args$text, 1), "pipeline_tables")
  expect_no_error(parse(text = l))
})

test_that("add_target into R/utils.R (no block list) creates pipeline_utils", {
  x <- wb_example()
  out <- chg_add_target(x$files, list(target = "unit", block = "R/utils.R",
    fn = new_fn("unit_value"), args = list(), format = NULL, pattern = NULL))
  l <- wb_lines(out, "R/utils.R")
  expect_true("pipeline_utils <- list(" %in% l)
  expect_equal(tail(l, 3), c("pipeline_utils <- list(", "  tar_target(unit, unit_value())", ")"))
  expect_equal(l[seq_along(wb_lines(x$files, "R/utils.R"))], wb_lines(x$files, "R/utils.R"))
  comp <- wb_composition(wb_parse(wb_lines(out, "_targets.R"), "_targets.R"))
  expect_true("pipeline_utils" %in% comp$args$text)
  expect_no_error(parse(text = wb_lines(out, "_targets.R")))
})

test_that("add_target reuses an existing function and appends to an existing block", {
  x <- wb_example()
  out <- chg_add_target(x$files, list(target = "hist_model", block = "R/model.R",
    fn = new_fn("score_histogram"), args = list(list(name = "", value = "features", named = FALSE),
      list(name = "title", value = "\"Features\"", named = TRUE)), format = NULL, pattern = NULL))
  l <- wb_lines(out, "R/model.R")
  expect_equal(tail(l, 3), c("  tar_target(predictions, predict_scores(model_fit_full, features)),",
    "  tar_target(hist_model, score_histogram(features, title = \"Features\"))", ")"))
  expect_equal(sum(grepl("score_histogram <- function", all_lines(out))), 1L)
  expect_equal(wb_lines(out, "_targets.R"), wb_lines(x$files, "_targets.R"))
})

test_that("add_target into an empty block list and without a composition", {
  dir <- local_project(list("_targets.R" = c("library(targets)", "tar_source()", "list(pipeline_a)"),
    "R/a.R" = c("pipeline_a <- list()")))
  out <- chg_add_target(wb_files(dir), list(target = "y", block = "R/a.R", fn = new_fn("g", body = "1"),
    args = list(), format = NULL, pattern = NULL))
  expect_equal(tail(wb_lines(out, "R/a.R"), 3), c("pipeline_a <- list(", "  tar_target(y, g())", ")"))
  dir <- local_project(list("_targets.R" = c("library(targets)", "tar_source()", "tar_target(z, 1)"),
    "R/a.R" = "f <- 1"))
  expect_error(chg_add_target(wb_files(dir), list(target = "y", block = "R/b.R", fn = new_fn("g"),
    args = list(), format = NULL, pattern = NULL)),
    "Cannot find the list of blocks in _targets.R; add pipeline_b there by hand.", fixed = TRUE,
    class = "pipeworks_bad_change")
  x <- wb_example()
  expect_error(chg_add_target(x$files, list(target = "clean_data", block = "R/model.R", fn = new_fn("g"),
    args = list(), format = NULL, pattern = NULL)), "clean_data", class = "pipeworks_bad_change")
})

# --- Task 6: transaction and undo ---------------------------------------------

set_title <- function(x, fn = "read_survey", value = "X", base = wb_base_of(x$path, paste0("function:", fn))) {
  list(kind = "set_doc", item = paste0("function:", fn), base = base, fn = fn, field = "title", value = value)
}

test_that("a stale base refuses the whole request and writes nothing", {
  x <- wb_example(); md5 <- tools::md5sum(file.path(x$path, "R/import.R"))
  err <- tryCatch(apply_changes(x$path, list(set_title(x, base = "0"))), pipeworks_stale = function(e) e)
  expect_s3_class(err, "pipeworks_stale")
  expect_equal(err$item, "function:read_survey"); expect_equal(err$file, "R/import.R")
  expect_match(conditionMessage(err), "function:read_survey in R/import.R changed since the page loaded it. The view is refreshed; try again.", fixed = TRUE)
  expect_equal(tools::md5sum(file.path(x$path, "R/import.R")), md5)
})

test_that("a missing item is stale", {
  x <- wb_example()
  ch <- list(kind = "remove_target", item = "target:nope", base = "0", target = "nope")
  expect_error(apply_changes(x$path, list(ch)), class = "pipeworks_stale")
})

test_that("invalid requests are refused before anything is touched", {
  x <- wb_example()
  expect_error(apply_changes(x$path, list()), class = "pipeworks_bad_change")
  expect_error(apply_changes(x$path, list(list(kind = "explode"))), class = "pipeworks_bad_change")
  ch <- set_title(x); ch$fn <- NULL
  expect_error(apply_changes(x$path, list(ch)), class = "pipeworks_bad_change")
  ch <- set_title(x); ch$base <- 1
  expect_error(apply_changes(x$path, list(ch)), class = "pipeworks_bad_change")
})

test_that("an edit of another function in the same file does not block the write", {
  x <- wb_example(); base <- wb_base_of(x$path, "function:read_survey")
  f <- file.path(x$path, "R/import.R")
  l <- read_utf8(f); l[l == "  dplyr::filter(data, .data$area == .env$area)"] <- "  dplyr::filter(data, area == .env$area)"
  writeLines(l, f)
  res <- apply_changes(x$path, list(set_title(x, base = base)))
  expect_equal(res$files, "R/import.R"); expect_equal(res$notes, character())
  expect_equal(read_utf8(f)[1], "#' X")
})

test_that("the base is checked only the first time an item is touched", {
  x <- wb_example(); b <- wb_base_of(x$path, "function:read_survey")
  c1 <- set_title(x, base = b); c2 <- set_title(x, value = "Y", base = "0")
  res <- apply_changes(x$path, list(c1, c2))
  expect_equal(read_utf8(file.path(x$path, "R/import.R"))[1], "#' Y")
})

test_that("a rename does not make later items stale against the original", {
  x <- wb_example()
  res <- apply_changes(x$path, list(list(kind = "rename_function", item = "function:rescale01",
    base = wb_base_of(x$path, "function:rescale01"), fn = "rescale01", to = "rescale_unit")))
  expect_true("R/utils.R" %in% res$files)
})

test_that("CRLF survives apply and undo", {
  x <- wb_example(); f <- file.path(x$path, "R/report.R")
  orig <- charToRaw(paste0(paste(read_utf8(f), collapse = "\r\n"), "\r\n")); writeBin(orig, f)
  res <- apply_changes(x$path, list(set_title(x, "score_histogram", "Histogram")))
  txt <- rawToChar(readBin(f, "raw", 1e6))
  expect_false(grepl("[^\r]\n", txt)); expect_match(txt, "^#' Histogram\r\n")
  undo_changes(x$path, res$undo); expect_equal(readBin(f, "raw", 1e6), orig)
})

test_that("a failing second file restores the first", {
  x <- wb_example(); base_write <- write_text
  rels <- c("R/utils.R", "R/model.R")
  before <- lapply(rels, function(r) read_utf8(file.path(x$path, r)))
  local_mocked_bindings(write_text = function(file, txt) if (grepl("model", file)) stop("disk full") else base_write(file, txt))
  expect_error(apply_changes(x$path, list(list(kind = "rename_function", item = "function:rescale01",
    base = wb_base_of(x$path, "function:rescale01"), fn = "rescale01", to = "rescale_unit"))), "disk full")
  expect_equal(lapply(rels, function(r) read_utf8(file.path(x$path, r))), before)
})

test_that("a change that would break a file writes nothing", {
  x <- wb_example(); f <- file.path(x$path, "R/import.R"); md5 <- tools::md5sum(f)
  ch <- list(kind = "set_body", item = "function:read_survey", base = wb_base_of(x$path, "function:read_survey"),
    fn = "read_survey", body = "if (")
  expect_error(apply_changes(x$path, list(ch)))
  expect_equal(tools::md5sum(f), md5)
})

test_that("undo restores the text and refuses after an intervening edit", {
  x <- wb_example(); f <- file.path(x$path, "R/import.R"); orig <- read_utf8(f)
  res <- apply_changes(x$path, list(set_title(x)))
  expect_equal(undo_changes(x$path, res$undo), "R/import.R")
  expect_equal(read_utf8(f), orig)
  res <- apply_changes(x$path, list(set_title(x)))
  l <- read_utf8(f); l[1] <- "#' By hand"; writeLines(l, f)
  err <- tryCatch(undo_changes(x$path, res$undo), pipeworks_stale = function(e) e)
  expect_s3_class(err, "pipeworks_stale")
  expect_match(conditionMessage(err), "R/import.R changed since that edit; undo it in RStudio.", fixed = TRUE)
  expect_equal(read_utf8(f), l)
})

test_that("undo keeps edits elsewhere in the file and deletes created files", {
  x <- wb_example(); f <- file.path(x$path, "R/import.R")
  res <- apply_changes(x$path, list(set_title(x)))
  l <- read_utf8(f); writeLines(c(l, "# tail"), f)
  undo_changes(x$path, res$undo)
  expect_equal(read_utf8(f)[length(read_utf8(f))], "# tail")
  expect_false(identical(read_utf8(f)[1], "#' X"))
  undo <- list("R/new.R" = list(before = character(), after = c("a <- 1"), existed = FALSE))
  writeLines("a <- 1", file.path(x$path, "R/new.R"))
  undo_changes(x$path, undo)
  expect_false(file.exists(file.path(x$path, "R/new.R")))
  writeLines(c("a <- 1", "b"), file.path(x$path, "R/new.R"))
  expect_error(undo_changes(x$path, undo), class = "pipeworks_stale")
})

test_that("undo of a pure deletion finds its place by context", {
  dir <- local_project(list("R/a.R" = c("a <- 1", "c <- 3")))
  undo <- list("R/a.R" = list(before = c("a <- 1", "b <- 2", "c <- 3"), after = c("a <- 1", "c <- 3"), existed = TRUE))
  undo_changes(dir, undo)
  expect_equal(read_utf8(file.path(dir, "R/a.R")), c("a <- 1", "b <- 2", "c <- 3"))
})

test_that("the model base equals the stale-check base, also with a blank line below the roxygen", {
  skip_if_no_targets()
  dir <- local_project(list(
    "_targets.R" = c("library(targets)", "tar_source()", "list(pipeline_a)"),
    "R/a.R" = c("#' Title", "#'", "#' @param x Input.", "", "f <- function(x) x", "",
      "pipeline_a <- list(", "  tar_target(t, f(1), pattern = map(x), description = \"d\"),", "  tar_target(x, c(1, 2))", ")")
  ))
  m <- read_pipeline(dir, status = FALSE)
  fb <- by_name(m$functions, "f")$base
  expect_equal(fb, wb_base_of(dir, "function:f"))
  expect_equal(by_name(m$targets, "t")$base, wb_base_of(dir, "target:t"))
  res <- apply_changes(dir, list(list(kind = "set_doc", item = "function:f", base = fb, fn = "f", field = "title", value = "New")))
  expect_equal(res$files, "R/a.R")
})

test_that("a rename_target request round-trips through read_pipeline()", {
  skip_if_no_targets()
  path <- local_example_repo()
  m <- read_pipeline(path, status = FALSE)
  res <- apply_changes(path, list(list(kind = "rename_target", item = "target:clean_data",
    base = by_name(m$targets, "clean_data")$base, target = "clean_data", to = "tidy_data")))
  expect_true(length(res$files) >= 1L)
  m2 <- read_pipeline(path, status = FALSE)
  nm <- vapply(m2$targets, function(t) t$name, ""); expect_true("tidy_data" %in% nm); expect_false("clean_data" %in% nm)
})

# --- final review fixes --------------------------------------------------------

add_req <- function(block, target = "y", fn = new_fn("g", body = "1"), args = list(), pattern = NULL) {
  list(kind = "add_target", target = target, block = block, fn = fn, args = args, format = NULL, pattern = pattern)
}

small_project <- function(env = parent.frame()) {
  local_project(list("_targets.R" = c("library(targets)", "tar_source()", "list(pipeline_a)"),
    "R/a.R" = c("f <- function() 1", "", "pipeline_a <- list(", "  tar_target(x, f())", ")")), env = env)
}

test_that("add_target refuses blocks outside R/ and odd paths", {
  path <- small_project()
  targets_before <- read_utf8(file.path(path, "_targets.R"))
  for (b in c("R/../outside.R", "R/../_targets.R", "R/./a.R", "R//b.R", "R\\b.R", "R/sub/../b.R", "R/", "R/.R", "/R/b.R")) {
    expect_error(apply_changes(path, list(add_req(b))), class = "pipeworks_bad_change", info = b)
  }
  expect_false(file.exists(file.path(path, "outside.R")))
  expect_equal(read_utf8(file.path(path, "_targets.R")), targets_before)
  # a symlinked directory below R/ that points outside the project
  outside <- withr::local_tempdir()
  skip_if_not(file.symlink(outside, file.path(path, "R", "ext")), "no symlinks")
  expect_error(apply_changes(path, list(add_req("R/ext/b.R"))), "below R/", class = "pipeworks_bad_change")
  expect_equal(list.files(outside), character())
  # a plain subdirectory is fine (tar_source() reads R/ recursively)
  res <- apply_changes(path, list(add_req("R/sub/b.R")))
  expect_true("R/sub/b.R" %in% res$files)
})

test_that("add_target refuses a file that exists under another spelling", {
  path <- small_project()
  skip_if_not(file.exists(file.path(path, "R", "A.R")), "case-sensitive file system")
  before <- read_utf8(file.path(path, "R/a.R"))
  expect_error(apply_changes(path, list(add_req("R/A.R"))), "R/A.R exists under another spelling (R/a.R); use that name.",
    fixed = TRUE, class = "pipeworks_bad_change")
  expect_equal(read_utf8(file.path(path, "R/a.R")), before)
})

test_that("undo refuses when its text sits elsewhere and the original was edited", {
  dir <- local_project(list("R/a.R" = c("#' F", "#' @param x Old.", "f <- function(x) x", "",
    "#' G", "#' @param x Input.", "g <- function(x) x")))
  file <- file.path(dir, "R/a.R")
  res <- apply_changes(dir, list(list(kind = "set_doc", item = "function:f", base = wb_base_of(dir, "function:f"),
    fn = "f", field = "param", param = "x", value = "Input.")))
  expect_equal(read_utf8(file)[2], "#' @param x Input.")
  l <- read_utf8(file); l[2] <- "#' @param x By hand."; writeLines(l, file)
  expect_error(undo_changes(dir, res$undo), class = "pipeworks_stale")
  expect_equal(read_utf8(file), l)
})

test_that("undo refuses a copy at another position even with the same context", {
  dir <- local_project(list("R/a.R" = c("#' T", "#' @param x Old.", "#' @export", "",
    "#' T", "#' @param x Input.", "#' @export")))
  file <- file.path(dir, "R/a.R")
  undo <- list("R/a.R" = list(before = read_utf8(file),
    after = replace(read_utf8(file), 2, "#' @param x Input."), existed = TRUE, start = 2L))
  # the user edited the original; the other copy has the same lines around it
  l <- replace(read_utf8(file), 2, "#' @param x By hand."); writeLines(l, file)
  expect_error(undo_changes(dir, undo), class = "pipeworks_stale")
  expect_equal(read_utf8(file), l)
})

test_that("undo follows lines added above the edit", {
  x <- wb_example(); f <- file.path(x$path, "R/import.R"); orig <- read_utf8(f)
  res <- apply_changes(x$path, list(set_title(x, "select_area")))
  expect_identical(res$undo[["R/import.R"]]$start, which(read_utf8(f) == "#' X"))
  writeLines(c("# one", "# two", read_utf8(f)), f)
  undo_changes(x$path, res$undo)
  expect_equal(read_utf8(f), c("# one", "# two", orig))
})

test_that("a failed rollback is named in the error", {
  x <- wb_example(); base_write <- write_text
  # R/model.R is written first, R/utils.R fails, restoring R/model.R fails too
  n_model <- 0L
  local_mocked_bindings(write_text = function(file, txt) {
    if (grepl("utils", file)) stop("disk full")
    if (grepl("model", file)) {
      n_model <<- n_model + 1L
      if (n_model > 1L) stop("read-only")
    }
    base_write(file, txt)
  })
  expect_error(apply_changes(x$path, list(list(kind = "rename_function", item = "function:rescale01",
    base = wb_base_of(x$path, "function:rescale01"), fn = "rescale01", to = "rescale_unit"))),
    "disk full; could not restore R/model.R, check it in RStudio", fixed = TRUE)
  expect_equal(n_model, 2L)
})

test_that("a missing item is stale without naming a file", {
  x <- wb_example()
  err <- tryCatch(apply_changes(x$path, list(list(kind = "remove_target", item = "target:nope", base = "0", target = "nope"))),
    pipeworks_stale = function(e) e)
  expect_false(grepl("NA", conditionMessage(err)))
  expect_match(conditionMessage(err), "target:nope", fixed = TRUE)
})

test_that("code that does not parse is refused as a bad change", {
  x <- wb_example()
  tb <- function(t) wb_base_of(x$path, paste0("target:", t))
  pat <- list(kind = "set_target_arg", item = "target:raw_data", base = tb("raw_data"), target = "raw_data",
    arg = "pattern", value = "map(x")
  expect_error(apply_changes(x$path, list(pat)), "pattern `map(x` does not parse", fixed = TRUE, class = "pipeworks_bad_change")
  call <- list(kind = "set_call", item = "target:raw_data", base = tb("raw_data"), target = "raw_data",
    args = list(list(name = "file", value = "c(1,", named = TRUE)))
  expect_error(apply_changes(x$path, list(call)), "`c(1,` does not parse", fixed = TRUE, class = "pipeworks_bad_change")
  two <- call; two$args[[1]]$value <- "1; 2"
  expect_error(apply_changes(x$path, list(two)), "does not parse", class = "pipeworks_bad_change")
  add <- add_req("R/model.R", args = list(list(name = "", value = "features)", named = FALSE)))
  expect_error(apply_changes(x$path, list(add)), "`features)` does not parse", fixed = TRUE, class = "pipeworks_bad_change")
  add <- add_req("R/model.R", pattern = "map(")
  expect_error(apply_changes(x$path, list(add)), "pattern `map(` does not parse", fixed = TRUE, class = "pipeworks_bad_change")
})

test_that("rename_function counts uses it leaves alone", {
  dir <- local_project(list("R/a.R" = c("fn <- function(x) x", "g <- function(x) fn(x)", "h <- function(x) lapply(x, fn)")))
  out <- chg_rename_function(wb_files(dir), list(fn = "fn", to = "fn2"))
  expect_equal(attr(out, "notes"),
    "Renamed 1 call(s) of fn(); 1 other use(s) (e.g. passed as a value), calls by string and in reports are not followed.")
  dir <- local_project(list("R/a.R" = c("fn <- function(x) x", "g <- function(x) fn(x)")))
  out <- chg_rename_function(wb_files(dir), list(fn = "fn", to = "fn2"))
  expect_equal(attr(out, "notes"), "Renamed 1 call(s) of fn(); calls by string or in reports are not followed.")
})

test_that("a case variant of a directory is refused, not written over the file", {
  path <- local_project(list("_targets.R" = c("library(targets)", "tar_source()", "list(pipeline_a, pipeline_b)"),
    "R/a.R" = c("f <- function() 1", "", "pipeline_a <- list(", "  tar_target(x, f())", ")"),
    "R/sub/b.R" = c("h <- function() 2", "", "pipeline_b <- list(", "  tar_target(z, h())", ")")))
  skip_if_not(file.exists(file.path(path, "R", "SUB", "b.R")), "case-sensitive file system")
  before <- read_utf8(file.path(path, "R/sub/b.R")); tbefore <- read_utf8(file.path(path, "_targets.R"))
  for (b in c("R/Sub/b.R", "R/SUB/b.R", "R/sub/B.R")) {
    expect_error(apply_changes(path, list(add_req(b))), sprintf("%s exists under another spelling (R/sub/b.R)", b),
      fixed = TRUE, class = "pipeworks_bad_change")
  }
  expect_equal(read_utf8(file.path(path, "R/sub/b.R")), before)
  expect_equal(read_utf8(file.path(path, "_targets.R")), tbefore)
  # the general guard in apply_changes, for a path a change produced
  files <- wb_files(path)
  expect_error(wb_check_spelling(files, "R/Sub/b.R"), "exists under another spelling", class = "pipeworks_bad_change")
})

test_that("undo never writes over an identical copy when lines were added below it", {
  dir <- local_project(list("R/a.R" = c("#' T", "#' @param x Old.", "#' @export", "",
    "#' T", "#' @param x Input.", "#' @export")))
  file <- file.path(dir, "R/a.R")
  b <- read_utf8(file)
  undo <- list("R/a.R" = list(before = b, after = replace(b, 2, "#' @param x Input."), existed = TRUE, start = 2L))
  l <- c(replace(b, 2, "#' @param x By hand."), paste("# tail", 1:5)); writeLines(l, file)
  expect_error(undo_changes(dir, undo), class = "pipeworks_stale")
  expect_equal(read_utf8(file), l)
})

test_that("undo refuses when the file changed above and below the edit", {
  dir <- local_project(list("R/a.R" = c("a <- 1", "b <- 2", "c <- 3")))
  file <- file.path(dir, "R/a.R")
  undo <- list("R/a.R" = list(before = c("a <- 1", "b <- 0", "c <- 3"), after = c("a <- 1", "b <- 2", "c <- 3"),
    existed = TRUE, start = 2L))
  # lines changed both above and below: the place cannot be told from the
  # common prefix and suffix, so it is refused rather than guessed
  for (now in list(c("# new", "a <- 1", "b <- 2", "c <- 3", "# more"), c("a <- 9", "b <- 2", "c <- 9"))) {
    writeLines(now, file)
    expect_error(undo_changes(dir, undo), "R/a.R changed around that edit; undo it in RStudio.", fixed = TRUE,
      class = "pipeworks_stale")
    expect_equal(read_utf8(file), now)
  }
})
