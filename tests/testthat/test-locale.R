# Hashes must not depend on the session locale: a reviewer on a German
# workstation and a CI job with LC_ALL=C must agree.

hash_in_locale <- function(dir, locale, git = FALSE) {
  # the package code: its R/ sources when testing from the source tree, else
  # the installed package (R CMD check)
  r_dir <- normalizePath(testthat::test_path("..", "..", "R"), mustWork = FALSE)
  load <- if (dir.exists(r_dir)) {
    sprintf("pw <- new.env(); for (f in list.files(%s, pattern = '[.]R$', full.names = TRUE)) sys.source(f, envir = pw)", deparse(r_dir))
  } else {
    "pw <- asNamespace('pipeworks')"
  }
  get <- if (git) {
    sprintf("h <- pw$git_item_hashes(%s, 'HEAD', character(), new.env()); cat(h[order(names(h))], sep = '\\n')", deparse(dir))
  } else {
    sprintf("it <- pw$read_source(%s)$items; cat(it$hash[order(it$id)], sep = '\\n')", deparse(dir))
  }
  script <- tempfile(fileext = ".R")
  writeLines(c(load, get), script)
  out <- system2(file.path(R.home("bin"), "Rscript"), shQuote(script), stdout = TRUE, stderr = FALSE,
                 env = c(paste0("LC_ALL=", locale), paste0("LANG=", locale)))
  out
}

test_that("hashes of non-ASCII code are the same in every locale", {
  dir <- withr::local_tempdir()
  dir.create(file.path(dir, "R"))
  writeBin(charToRaw(enc2utf8('f <- function(x) ifelse(x, "männlich", "weiblich")\n')), file.path(dir, "R", "a.R"))
  writeBin(charToRaw("list()\n"), file.path(dir, "_targets.R"))
  it <- read_source(dir)$items
  here <- it$hash[order(it$id)]
  expect_equal(hash_in_locale(dir, "C"), here)
  # the version read back from git hashes the same as the working tree
  skip_if_not(git_available())
  git_cmd(dir, "init", "-q")
  git_cmd(dir, "add", "-A")
  git_cmd(dir, "-c", "user.name=A", "-c", "user.email=a@x", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "x")
  expect_equal(hash_in_locale(dir, "C", git = TRUE), here)
  h <- git_item_hashes(dir, "HEAD", character(), new.env())
  expect_equal(unname(h[order(names(h))]), here)
  la <- last_authors(dir, read_source(dir)$items)
  expect_false(anyNA(la$author_email))
})
