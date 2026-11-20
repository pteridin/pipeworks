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
#' Linear model of the satisfaction score. The `"base"` specification uses
#' region and channel, the `"full"` one adds age and tenure.
#'
#' @param features Model-ready tibble from [build_features()].
#' @param spec Model specification, `"base"` or `"full"`.
#' @return A fitted `lm` object.
#' @family Modelling
fit_score_model <- function(features, spec) {
  formula <- switch(
    spec,
    base = score ~ region + channel,
    full = score ~ region + channel + age + tenure_years
  )
  stats::lm(formula, data = features)
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

pipeline_model <- list(
  tar_target(features, build_features(clean_data)),
  tarchetypes::tar_map(
    values = list(spec = c("base", "full")),
    tar_target(model_fit, fit_score_model(features, spec))
  ),
  tar_target(predictions, predict_scores(model_fit_full, features))
)
