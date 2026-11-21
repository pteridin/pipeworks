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

test_that("embedded JSON escapes every less-than sign", {
  m <- fake_model()
  m$files$text <- "# <!-- <script>"
  json <- model_json(m)
  expect_false(grepl("<", json, fixed = TRUE))
  expect_equal(jsonlite::fromJSON(json)$files$text, "# <!-- <script>")
})

test_that("example_project() copies the project without build output", {
  dest <- file.path(withr::local_tempdir(), "survey")
  example_project(dest)
  expect_true(file.exists(file.path(dest, "_targets.R")))
  expect_true(file.exists(file.path(dest, "data", "survey_2026.csv")))
  expect_false(dir.exists(file.path(dest, "_targets")))
  expect_error(example_project(dest), "already exists")
})

test_that("the editor template is a fragment that calls the API by relative URLs", {
  template <- paste(readLines(system.file("app", "index.html", package = "pipeworks")), collapse = "\n")
  expect_false(grepl("<(html|head|body)[ >]", template))
  # an absolute /api/ path would break behind the RStudio Server proxy
  expect_false(grepl("[\"'`(]/api/", template))
  expect_match(template, "fetch('api/' + path", fixed = TRUE)
  expect_match(template, "X-Pipeworks-Token", fixed = TRUE)
  expect_match(template, "history.replaceState(null, '', location.pathname)", fixed = TRUE)
})

test_that("hidden elements stay hidden outside the artifact viewer", {
  template <- paste(readLines(system.file("app", "index.html", package = "pipeworks")), collapse = "\n")
  expect_match(template, "[hidden][hidden] { display: none !important; }", fixed = TRUE)
})
