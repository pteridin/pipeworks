# Copy of the survey example for write-back tests, with a lazily loaded file set.
wb_example <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  src <- example_dir()
  files <- list.files(src, recursive = TRUE, all.files = TRUE, no.. = TRUE)
  files <- files[!grepl("^(_targets/|\\.Rproj\\.user/)|^report\\.html$", files)]
  for (f in files) {
    dir.create(file.path(dir, dirname(f)), recursive = TRUE, showWarnings = FALSE)
    file.copy(file.path(src, f), file.path(dir, f))
  }
  list(path = dir, files = wb_files(dir))
}

wb_lines <- function(files, rel) wb_files_get(files, rel)$lines

# Base of an item as the model computes it (shared helper wb_item_base()).
wb_base_of <- function(path, item) {
  files <- wb_files(path)
  r <- if (startsWith(item, "function:")) wb_find_function(files, sub("^function:", "", item)) else
    wb_find_target(files, sub("^target:", "", item))
  wb_item_base(r$p, item)
}
