test_that("a function instead of a path gives a readable error", {
  expect_error(qa_status(q), "a function .*typo")
  expect_error(qa_check(c), "a function")
  expect_error(read_source(q), "a function")
  expect_error(qa_review("f", "correct", path = q), "a function")
})

test_that("other non-paths and missing folders are named", {
  expect_error(qa_status(c("a", "b")), "class character with length 2")
  expect_error(qa_status(NA_character_), "one string")
  expect_error(qa_status(file.path(tempdir(), "does-not-exist")), "not an existing folder")
})
