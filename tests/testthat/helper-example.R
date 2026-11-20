example_dir <- function() {
  src <- testthat::test_path("..", "..", "inst", "examples", "survey")
  if (dir.exists(src)) src else system.file("examples", "survey", package = "pipeworks")
}

skip_if_no_targets <- function() {
  testthat::skip_if_not_installed("targets")
  testthat::skip_if_not_installed("tarchetypes")
  testthat::skip_if_not_installed("rmarkdown")
}

by_name <- function(records, name) Filter(function(x) identical(x$name, name), records)[[1]]

# Reading the pipeline starts a separate R process, so read the example once
# from a clean copy (without _targets/) and reuse the result.
example_cache <- new.env()
read_example <- function() {
  if (is.null(example_cache$model)) {
    dest <- file.path(tempfile("pipeworks-test-"), "survey")
    dir.create(dest, recursive = TRUE)
    src <- example_dir()
    files <- list.files(src, recursive = TRUE, all.files = TRUE, no.. = TRUE)
    files <- files[!grepl("^(_targets/|\\.Rproj\\.user/)|^report\\.html$", files)]
    for (f in files) {
      dir.create(file.path(dest, dirname(f)), recursive = TRUE, showWarnings = FALSE)
      file.copy(file.path(src, f), file.path(dest, f))
    }
    example_cache$model <- read_pipeline(dest)
  }
  example_cache$model
}
