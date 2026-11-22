blk <- c("#' Old title", "#'", "#' Some text.", "#'", "#' @param x An x.",
         "#' @return A y.", "#' @examples", "#' f(1)", "#'", "#' f(2)", "#' @export", "#' @importFrom stats lm")
test_that("set title keeps every other line verbatim", {
  out <- rox_set(blk, "title", "New title")
  expect_equal(out[1], "#' New title"); expect_equal(out[-1], blk[-1])
})
test_that("set param replaces only its section; missing tags go before unknown tags", {
  out <- rox_set(blk, "param", "A longer x.", param = "x", formals = "x")
  expect_equal(out[5], "#' @param x A longer x."); expect_equal(out[-5], blk[-5])
  out2 <- rox_set(blk, "family", "Modelling")
  expect_equal(out2[7], "#' @family Modelling"); expect_equal(out2[8:13], blk[7:12])
})
test_that("param removal and a missing block", {
  expect_false(any(grepl("@param x", rox_set(blk, "param", NULL, param = "x"))))
  expect_equal(rox_set(character(), "returns", "A z.")[c(1, length(rox_set(character(), "returns", "A z.")))],
               c("#' TODO: one-line title", "#' @return A z."))
})
test_that("target_text uses one line when it fits", {
  expect_equal(target_text("a", "f", list(list(name = "x", value = "b", named = FALSE))), "tar_target(a, f(b))")
})

test_that("description is replaced, inserted and removed with separators intact", {
  out <- rox_set(blk, "description", "New text.")
  expect_equal(out[3], "#' New text."); expect_equal(out[-3], blk[-3])
  b2 <- c("#' T", "#'", "#' @return R")
  expect_equal(rox_set(b2, "description", "D"), c("#' T", "#'", "#' D", "#'", "#' @return R"))
  expect_equal(rox_set("#' T", "description", "D"), c("#' T", "#'", "#' D"))
  expect_equal(rox_set(blk, "description", NULL)[1:3], c("#' Old title", "#'", "#' @param x An x."))
})
test_that("new params are inserted in formals order, before @return", {
  b <- c("#' T", "#'", "#' @param a A.", "#' @param c C.", "#' @return R")
  out <- rox_set(b, "param", "B.", param = "b", formals = c("a", "b", "c"))
  expect_equal(out[4], "#' @param b B.")
  out <- rox_set(c("#' T", "#'", "#' @return R"), "param", "A.", param = "a", formals = "a")
  expect_equal(out, c("#' T", "#'", "#' @param a A.", "#' @return R"))
})
test_that("tags without a body get a separator; @title/@description tags count", {
  expect_equal(rox_set("#' T", "returns", "R"), c("#' T", "#'", "#' @return R"))
  b <- c("#' @title Old", "#' @description Desc", "#' @export")
  expect_equal(rox_set(b, "title", "New"), c("#' @title New", "#' @description Desc", "#' @export"))
  expect_equal(rox_set(b, "description", "Other"), c("#' @title Old", "#' @description Other", "#' @export"))
})
test_that("long values wrap at 76 with indented continuation", {
  v <- paste(rep("word", 30), collapse = " ")
  out <- rox_set("#' T", "returns", v)
  expect_true(all(nchar(sub("^#' *", "", out)) <= 76))
  expect_true(all(startsWith(out[-(1:3)], "#'   ")))
})
test_that("function_text and multi-line target_text", {
  fn <- list(name = "f", title = "Title", description = "", returns = "R", family = "Fam",
    params = list(x = "An x."), formals = list(list(name = "x", default = NULL), list(name = "n", default = "1")),
    body = "x + n\ny")
  expect_equal(function_text(fn), c("#' Title", "#'", "#' @param x An x.",
    "#' @param n TODO: describe this argument.", "#' @return R", "#' @family Fam",
    "f <- function(x, n = 1) {", "  x + n", "  y", "}"))
  args <- list(list(name = "data", value = "a_long_target_name_one", named = TRUE),
               list(name = "", value = "another_long_target_name_two", named = FALSE))
  expect_equal(target_text("clean_data", "clean", args, "qs", "map(x)"),
    c("tar_target(", "  clean_data,", "  clean(data = a_long_target_name_one, another_long_target_name_two),",
      "  format = \"qs\",", "  pattern = map(x)", ")"))
})
