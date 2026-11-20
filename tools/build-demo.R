# Builds mockup/pipeline-editor.html: the editor with the example project
# embedded, used for the published demo. The example is copied with its git
# review scenario (example_project(git = TRUE)), so the demo shows the QA
# overlay. Run from the package root:
#   Rscript tools/build-demo.R
devtools::load_all(quiet = TRUE)
dest <- file.path(tempfile("pipeworks-demo-"), "survey")
path <- example_project(dest, git = TRUE)
model <- read_pipeline(path)
model$root <- "survey"
pipeworks_html(model, "mockup/pipeline-editor.html")
unlink(dirname(dest), recursive = TRUE)
message("Wrote mockup/pipeline-editor.html")
