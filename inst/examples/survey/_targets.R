library(targets)
library(tarchetypes)

tar_option_set(packages = c("dplyr", "ggplot2", "readr"))
tar_source()

list(
  pipeline_import,
  pipeline_model,
  pipeline_report,
  tarchetypes::tar_map(
    values = list(area = c("urban", "rural")),
    tmpl_region_import,
    tmpl_region_report
  )
)
