#' Copy the example survey project
#'
#' Copies the small targets project that ships with pipeworks, so you can try
#' the editor without touching your own pipeline.
#'
#' With `git = TRUE` the copy becomes a git repository with a ready-made QA
#' round: `main` holds the analyst's pipeline, which the senior has already
#' reviewed (one verdict is `questionable`, with a comment); the branch
#' `dev/sample-definition` adds fresh changes that still await review. Try
#' `qa_status(path, base = "main")` and `qa_check(path)`, then review the open
#' items with [qa_review()]. The repository-local git identity is the senior's;
#' your global git configuration is not touched.
#'
#' @param dest Folder to copy the project into. It must not exist yet.
#' @param git If `TRUE`, make the copy a git repository with the review
#'   scenario described above. Needs `git`.
#' @return The path of the copied project, invisibly.
#' @export
example_project <- function(dest = file.path(tempdir(), "survey"), git = FALSE) {
  if (git && !git_available()) {
    stop("`example_project(git = TRUE)` needs `git`, which was not found on the PATH.", call. = FALSE)
  }
  src <- system.file("examples", "survey", package = "pipeworks", mustWork = TRUE)
  if (dir.exists(dest)) stop(dest, " already exists.", call. = FALSE)
  dir.create(dest, recursive = TRUE)
  files <- list.files(src, recursive = TRUE, all.files = TRUE, no.. = TRUE)
  files <- files[!grepl("^(_targets/|\\.Rproj\\.user/)|^report\\.html$", files)]
  for (f in files) {
    dir.create(file.path(dest, dirname(f)), recursive = TRUE, showWarnings = FALSE)
    file.copy(file.path(src, f), file.path(dest, f))
  }
  path <- normalizePath(dest)
  if (git) example_git_scenario(path)
  invisible(path)
}

example_people <- list(
  analyst = c(name = "A. Analyst", email = "analyst@example.org"),
  senior = c(name = "S. Senior", email = "senior@example.org")
)

# Set up the review round in the fresh copy `path` (see `example_project()`).
example_git_scenario <- function(path) {
  analyst <- example_people$analyst
  senior <- example_people$senior
  set_user <- function(who) {
    git_run(path, c("config", "user.name", who[["name"]]))
    git_run(path, c("config", "user.email", who[["email"]]))
  }
  commit <- function(who, message) {
    git_run(path, c("add", "-A"))
    git_run(path, c(
      "-c", paste0("user.name=", who[["name"]]), "-c", paste0("user.email=", who[["email"]]),
      "-c", "commit.gpgsign=false", "commit", "-q", "-m", message,
      paste0("--author=", who[["name"]], " <", who[["email"]], ">")
    ))
  }
  edit <- function(file, fun) {
    full <- file.path(path, file)
    writeLines(fun(readLines(full, warn = FALSE)), full)
  }

  # `git init -b` needs git >= 2.28; this works with older versions too
  git_run(path, c("init", "-q"))
  git_run(path, c("symbolic-ref", "HEAD", "refs/heads/main"))
  git_run(path, c("config", "commit.gpgsign", "false"))
  set_user(analyst)
  commit(analyst, "Survey pipeline")

  # The senior reviews every item of main.
  set_user(senior)
  comment <- paste(
    "summarise_region() has no @family documentation, unlike the other reporting functions,",
    "and the grouping is done by hand-filtering one region per branch.",
    "Group by region once and summarise instead."
  )
  suppressMessages(for (id in read_source(path)$items$id) {
    if (id == "function:summarise_region") qa_review(id, "questionable", comment, path = path)
    else qa_review(id, "correct", path = path)
  })
  commit(senior, "QA review of main")

  # The analyst's fresh changes on a dev branch.
  git_run(path, c("checkout", "-q", "-b", "dev/sample-definition"))
  edit("R/import.R", function(l) {
    at <- grep("dplyr::filter(!is_test) |>", l, fixed = TRUE)
    append(l, "    dplyr::filter(is.na(age) | age >= 18) |>", after = at)
  })
  edit("R/report.R", function(l) {
    at <- grep("^pipeline_report <- list\\(", l)
    l <- append(l, "  tar_target(channel_counts, count_by_channel(clean_data)),", after = at)
    fn <- c(
      "#' Count responses per channel",
      "#'",
      "#' @param data Clean responses with a `channel` column.",
      "#' @return A tibble with one row per channel and its number of responses.",
      "#' @family Reporting",
      "count_by_channel <- function(data) {",
      "  dplyr::count(data, channel)",
      "}",
      ""
    )
    append(l, fn, after = at - 1)
  })
  set_user(analyst)
  commit(analyst, "Sample definition: adults only, responses per channel")
  set_user(senior)
  invisible(path)
}
