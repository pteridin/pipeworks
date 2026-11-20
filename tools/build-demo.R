# Builds mockup/pipeline-editor.html: the editor with the example project
# embedded, used for the published demo. Run from the package root:
#   Rscript tools/build-demo.R
devtools::load_all(quiet = TRUE)
model <- read_pipeline("inst/examples/survey")
pipeworks_html(model, "mockup/pipeline-editor.html")
message("Wrote mockup/pipeline-editor.html")
