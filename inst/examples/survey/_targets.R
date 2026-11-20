library(targets)
library(tarchetypes)

tar_option_set(packages = c("dplyr", "ggplot2", "readr"))
tar_source()

list(
  # Data import ----
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
  ),

  # Modelling ----
  tar_target(features, build_features(clean_data)),
  tar_target(model_fit, fit_score_model(features)),
  tar_target(predictions, predict_scores(model_fit, features)),

  # Reporting ----
  tar_target(hist_raw, score_histogram(raw_data, title = "Raw submissions")),
  tar_target(hist_clean, score_histogram(clean_data, title = "Clean responses")),
  tar_target(region_summary, summarise_region(clean_data, regions), pattern = map(regions)),
  tar_target(coef_plot, plot_coefficients(model_fit)),
  tar_render(report, "report.Rmd")
)
