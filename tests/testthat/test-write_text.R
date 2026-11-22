test_that("read_text/write_text keep CRLF and a missing final newline", {
  dir <- withr::local_tempdir(); f <- file.path(dir, "a.R")
  writeBin(charToRaw("x <- 1\r\ny <- 2"), f)
  t <- read_text(f)
  expect_equal(t$lines, c("x <- 1", "y <- 2")); expect_equal(t$eol, "\r\n"); expect_false(t$final_nl)
  t$lines[2] <- "y <- 3"; write_text(f, t)
  expect_equal(readBin(f, "raw", 100), charToRaw("x <- 1\r\ny <- 3"))
})
test_that("write_text creates parent directories for new files", {
  dir <- withr::local_tempdir(); f <- file.path(dir, "new", "a.R")
  write_text(f, list(lines = c("a", "b"), eol = "\n", final_nl = TRUE))
  expect_equal(readBin(f, "raw", 100), charToRaw("a\nb\n"))
  expect_equal(read_text(f)$final_nl, TRUE)
})
test_that("pd_char maps parse columns after tabs and multibyte characters", {
  line <- "\tx <- \"ä\"; y"
  pd <- utils::getParseData(parse(text = line, keep.source = TRUE))
  y <- pd[pd$token == "SYMBOL" & pd$text == "y", ]
  expect_equal(substr(line, pd_char(line, y$col1), pd_char(line, y$col2)), "y")
})
test_that("splice_lines replaces, inserts and refuses overlaps", {
  l <- c("f(a, b)", "g()")
  e <- data.frame(line1 = c(1, 2), col1 = c(6, 3), line2 = c(1, 2), col2 = c(6, 2), text = c("c", "z"))
  expect_equal(splice_lines(l, e), c("f(a, c)", "g(z)"))
  expect_equal(splice_lines(l, data.frame(line1 = 1, col1 = 8, line2 = 1, col2 = 7, text = "\n# x")), c("f(a, b)", "# x", "g()"))
  expect_error(splice_lines(l, data.frame(line1 = c(1, 1), col1 = c(1, 3), line2 = c(1, 1), col2 = c(4, 5), text = "")), "Overlapping")
})
test_that("md5_lines hashes lines joined by newline", {
  expect_equal(md5_lines(c("a", "b")), md5_text("a\nb"))
})
