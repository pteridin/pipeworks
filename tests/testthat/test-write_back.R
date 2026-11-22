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
