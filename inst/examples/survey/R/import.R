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
      is_test = "l"
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
