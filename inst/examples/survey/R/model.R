#' Engineer model features
#'
#' Rescales the numeric answers to the unit interval and keeps only the
#' columns the model uses.
#'
#' @return A model-ready tibble.
#' @family Modelling
build_features <- function(clean_data) {
  clean_data |>
    dplyr::transmute(
      respondent_id,
      score,
      region,
      channel,
      age = rescale01(age),
      tenure_years = rescale01(tenure_years)
    )
}

#' Fit the satisfaction model
#'
#' Linear model of the satisfaction score on region, channel, age and tenure.
#'
#' @param features Model-ready tibble from [build_features()].
#' @return A fitted `lm` object.
#' @family Modelling
fit_score_model <- function(features) {
  stats::lm(score ~ region + channel + age + tenure_years, data = features)
}

#' Predict scores for every respondent
#'
#' @param model_fit The fitted model from [fit_score_model()].
#' @param features Model-ready tibble from [build_features()].
#' @family Modelling
predict_scores <- function(model_fit, features) {
  features |>
    dplyr::mutate(predicted = stats::predict(model_fit, newdata = features))
}
