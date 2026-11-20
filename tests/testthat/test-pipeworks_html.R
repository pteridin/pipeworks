fake_model <- function() {
  structure(list(project = "x", targets = list(), functions = list(), edges = list(),
    blocks = character(), maps = list(), qa_summary = NULL, files = list(list(path = "R/a.R", text = "# </script> inside a comment"))),
    class = "pipeworks_model")
}

test_that("the model is embedded in the editor", {
  file <- pipeworks_html(fake_model(), file.path(withr::local_tempdir(), "sub", "index.html"))
  html <- paste(readLines(file), collapse = "\n")
  expect_match(html, '<script id="pipeworks-data" type="application/json">{"project":"x"', fixed = TRUE)
  expect_false(grepl('type="application/json">null</script>', html, fixed = TRUE))
})

test_that("embedded JSON cannot close the script tag", {
  json <- model_json(fake_model())
  expect_false(grepl("</script>", json, fixed = TRUE))
  expect_equal(jsonlite::fromJSON(json)$files$text, "# </script> inside a comment")
})

test_that("example_project() copies the project without build output", {
  dest <- file.path(withr::local_tempdir(), "survey")
  example_project(dest)
  expect_true(file.exists(file.path(dest, "_targets.R")))
  expect_true(file.exists(file.path(dest, "data", "survey_2026.csv")))
  expect_false(dir.exists(file.path(dest, "_targets")))
  expect_error(example_project(dest), "already exists")
})
