# survey: example targets project

A small but realistic `{targets}` pipeline used as the test case for pipeworks.
It reads a fake customer survey, cleans it, fits two linear models and renders
an R Markdown report.

The project follows the block convention: each file in `R/` holds the
functions of one block and ends with `pipeline_<file> <- list(...)` with that
block's targets. `_targets.R` only composes them:
`list(pipeline_import, pipeline_model, pipeline_report, <map>)`.

```r
# from this folder
targets::tar_make()
targets::tar_visnetwork()
```

Needs: targets, tarchetypes, dplyr, readr, ggplot2, rmarkdown.
Regenerate the data with `Rscript data-raw/make_survey.R`.

## Pipeline

| Target           | Command                                        | `@family`   | File       |
|------------------|------------------------------------------------|-------------|------------|
| `raw_file`       | `"data/survey_2026.csv"` (format `file`)       | none        | expression |
| `raw_data`       | `read_survey(raw_file)`                        | Data import | R/import.R |
| `clean_data`     | `clean_survey(raw_data)`                       | Data import | R/import.R |
| `regions`        | `levels(droplevels(clean_data$region))`        | none        | expression |
| `features`       | `build_features(clean_data)`                   | Modelling   | R/model.R  |
| `model_fit_base`, `model_fit_full` | `fit_score_model(features, spec)` (`tar_map` over `spec`) | Modelling | R/model.R |
| `predictions`    | `predict_scores(model_fit_full, features)`     | Modelling   | R/model.R  |
| `hist_raw`       | `score_histogram(raw_data, title = ...)`       | Reporting   | R/report.R |
| `hist_clean`     | `score_histogram(clean_data, title = ...)`     | Reporting   | R/report.R |
| `region_summary` | `summarise_region(clean_data, regions)`, `map(regions)` | none | R/report.R |
| `coef_plot`      | `plot_coefficients(model_fit_full)`            | Reporting   | R/report.R |
| `area_data_urban`, `area_data_rural` | `select_area(clean_data, area)` (spanning `tar_map` over `area`) | Data import | R/import.R, `_targets.R` |
| `area_hist_urban`, `area_hist_rural` | `area_histogram(area_data, area)` (same map) | Reporting | R/report.R, `_targets.R` |
| `report`         | `tar_render(report, "report.Rmd")`             | none        | report.Rmd |

Blocks: `R/import.R` -> `pipeline_import`, `R/model.R` -> `pipeline_model`,
`R/report.R` -> `pipeline_report`. `R/utils.R` has only the helper.

## Edge cases pipeworks has to handle

These are deliberate. Do not "fix" them, because they are what the tests check.

1. **Argument names differ from target names.** `read_survey(path)` is called
   with `raw_file`; `score_histogram(data, title)` is called with `clean_data`.
   The roxygen `@param` documents the argument (`path`), not the target.
2. **One function, several targets.** `score_histogram()` builds both
   `hist_raw` and `hist_clean`. Editing its roxygen changes both.
3. **Constant arguments.** `title = "Raw submissions"` is part of the command
   but not a dependency.
4. **Expression targets without a function.** `raw_file` and `regions` have no
   roxygen block. Both use `tar_target(description = )` instead.
5. **File target.** `raw_file` uses `format = "file"`.
6. **Dynamic branching.** `region_summary` uses `pattern = map(regions)`.
7. **Target factory.** `tar_render()` creates `report`. Its dependencies come
   from `tar_read()` calls inside `report.Rmd`, not from a function call.
8. **Helper that is not a target.** `rescale01()` in `R/utils.R` is only called
   inside `build_features()`. It still shows up in `tar_network()` as a
   function node, so pipeworks has to decide whether to show it.
9. **Missing documentation**, to exercise the roxygen checks:
   - `build_features()` has no `@param clean_data`.
   - `predict_scores()` has no `@return`.
   - `summarise_region()` has no `@family`.
10. **Messy data.** The CSV has 12 duplicate submissions, 6 test submissions
    and a legacy region code (`NE`), so `raw_data` (258 rows) and
    `clean_data` (240 rows) differ.
11. **Map inside one block.** `R/model.R` contains
    `tar_map(values = list(spec = c("base", "full")), tar_target(model_fit, ...))`
    as part of `pipeline_model`. It creates `model_fit_base` and
    `model_fit_full`; downstream targets use `model_fit_full`.
12. **Map spanning two files.** `_targets.R` maps over
    `values = list(area = c("urban", "rural"))` with the templates
    `tmpl_region_import` (end of `R/import.R`) and `tmpl_region_report`
    (`R/report.R`), referenced by bare symbol. Each area gets a data and a
    histogram target, and `area_hist_*` depends on `area_data_*` of the same
    area.
