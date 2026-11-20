#' Histogram of satisfaction scores
#'
#' Used by two targets: once on the raw and once on the cleaned data.
#'
#' @param data A data frame with a numeric `score` column.
#' @param title Plot title.
#' @return A ggplot object.
#' @family Reporting
score_histogram <- function(data, title) {
  ggplot2::ggplot(data, ggplot2::aes(score)) +
    ggplot2::geom_histogram(binwidth = 1, boundary = -0.5) +
    ggplot2::scale_x_continuous(breaks = 0:10) +
    ggplot2::labs(title = title, x = "Score (0-10)", y = "Responses")
}

#' Summary statistics for one region
#'
#' Called once per region through dynamic branching.
#'
#' @param data Clean responses.
#' @param region A single region code.
#' @return A one-row tibble with the region, the number of responses and the
#'   mean score.
summarise_region <- function(data, region) {
  data |>
    dplyr::filter(.data$region == .env$region) |>
    dplyr::summarise(
      region = .env$region,
      n = dplyr::n(),
      mean_score = mean(score)
    )
}

#' Plot the model coefficients
#'
#' @param model_fit A fitted `lm` object.
#' @return A ggplot object with one point and confidence interval per term.
#' @family Reporting
plot_coefficients <- function(model_fit) {
  ci <- stats::confint(model_fit)
  coefs <- data.frame(
    term = rownames(ci),
    estimate = stats::coef(model_fit),
    low = ci[, 1],
    high = ci[, 2]
  )
  coefs <- coefs[coefs$term != "(Intercept)", ]
  ggplot2::ggplot(coefs, ggplot2::aes(estimate, term)) +
    ggplot2::geom_vline(xintercept = 0, linetype = 2) +
    ggplot2::geom_pointrange(ggplot2::aes(xmin = low, xmax = high)) +
    ggplot2::labs(x = "Effect on score", y = NULL)
}

#' Histogram of satisfaction scores for one area
#'
#' Template function of the per-area `tar_map()` in `_targets.R`.
#'
#' @param data Responses of one area, with a numeric `score` column.
#' @param area Area name, used as the plot title.
#' @return A ggplot object.
#' @family Reporting
area_histogram <- function(data, area) {
  score_histogram(data, title = area)
}

# Templates for the per-area map in _targets.R (together with tmpl_region_import).
tmpl_region_report <- list(
  tar_target(area_hist, area_histogram(area_data, area))
)

pipeline_report <- list(
  tar_target(hist_raw, score_histogram(raw_data, title = "Raw submissions")),
  tar_target(hist_clean, score_histogram(clean_data, title = "Clean responses")),
  tar_target(region_summary, summarise_region(clean_data, regions), pattern = map(regions)),
  tar_target(coef_plot, plot_coefficients(model_fit_full)),
  tarchetypes::tar_render(report, "report.Rmd")
)
