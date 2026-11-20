#' Read the raw survey export
#'
#' Parses the CSV with explicit column types, so a change in the export
#' format fails loudly instead of silently producing wrong types.
#'
#' @param path Path to the survey CSV.
#' @return A tibble with one row per submission.
#' @family Data import
read_survey <- function(path) {
  readr::read_csv(
    path,
    col_types = readr::cols(
      respondent_id = "c",
      submitted_at = readr::col_datetime(),
      region = "c",
      channel = "c",
      age = "i",
      tenure_years = "d",
      score = "d",
      is_test = "l",
      area = "c"
    )
  )
}

#' Clean and deduplicate responses
#'
#' Drops test submissions, keeps the first submission per respondent and
#' merges the legacy `NE` region code into `N`.
#'
#' @param raw_data Raw submissions as returned by [read_survey()].
#' @return A tibble of valid, unique responses with `region` as a factor.
#' @family Data import
clean_survey <- function(raw_data) {
  raw_data |>
    dplyr::filter(!is_test) |>
    dplyr::arrange(submitted_at) |>
    dplyr::distinct(respondent_id, .keep_all = TRUE) |>
    dplyr::mutate(
      region = dplyr::recode(region, NE = "N"),
      region = factor(region, levels = c("N", "E", "S", "W")),
      channel = factor(channel, levels = c("web", "phone", "store"))
    )
}

#' Select the responses of one area
#'
#' Template function of the per-area `tar_map()` in `_targets.R`.
#'
#' @param data Clean responses with an `area` column.
#' @param area Either `"urban"` or `"rural"`.
#' @return The rows of `data` that belong to `area`.
#' @family Data import
select_area <- function(data, area) {
  dplyr::filter(data, .data$area == .env$area)
}

# Templates for the per-area map in _targets.R (together with tmpl_region_report).
tmpl_region_import <- list(
  tar_target(area_data, select_area(clean_data, area))
)

pipeline_import <- list(
  tar_target(
    raw_file,
    "data/survey_2026.csv",
    format = "file",
    description = "Raw survey export, tracked as a file."
  ),
  tar_target(raw_data, read_survey(raw_file)),
  tar_target(clean_data, clean_survey(raw_data)),
  tar_target(
    regions,
    levels(droplevels(clean_data$region)),
    description = "Regions present after cleaning."
  )
)
