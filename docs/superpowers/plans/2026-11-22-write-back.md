# Write-back from Build mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Build action on the live page is written to the project's files at once, as a chunk-level splice; files stay the only truth and RStudio edits keep flowing back to the canvas.

**Architecture:** The page diffs its state before/after each action into a list of semantic changes and POSTs it to `api/edit`. R (`R/write_*.R`) locates each chunk with `getParseData()`, checks the item's base hash, splices new text into in-memory copies of the files, re-parses, and writes all touched files atomically; it records an undo entry and starts the background rebuild. The page shows the edit optimistically and takes the next built model.

**Tech Stack:** R (base parser, `utils::getParseData()`, `tools::md5sum`), httpuv server (existing), vanilla JS in `inst/app/index.html`, testthat 3, jsdom smoke (`tools/smoke.js`).

**Spec:** `docs/superpowers/specs/2026-11-22-write-back-design.md`

## Global Constraints

- Static only: never source or evaluate project code while writing.
- Files read and written as UTF-8 (`read_utf8()`); line endings (LF/CRLF) and the presence of a trailing newline preserved per file.
- Lines outside a touched chunk stay byte-identical; inside a chunk, unknown roxygen tags, extra call arguments and comments are kept.
- Chunks are located by parse tokens, never by regex over raw text (the one exception: the refusal check for `tar_read()`/`tar_load()` in report sources, which only reads).
- Generated text: roxygen `#' ` wrapped at 76 columns; two-space indent; `tar_target(name, fn(args))` on one line when ≤ 76 columns, else one argument per line.
- Empty body of a new function: `stop("Not implemented: <fn>()")`.
- No commits for code writes.
- Static page (`pipeworks_html()`, demo) keeps today's in-memory behaviour and wording.
- `inst/app/index.html` stays an HTML fragment; state classes (`.sel`, `.dim`, `.hl`, `.drop`) stay separate from form-control classes. A new "writing" mark gets its own class `.wr`.
- Example fixture (`inst/examples/survey/`) is never modified; tests write to copies (`local_project()`, `local_example_repo()`).
- `devtools::test()` and `devtools::check()` clean before handing back.

## Review Focus

1. **Tabs and multibyte characters before a chunk:** parse-data columns expand tabs to multiples of 8 and count characters, not bytes; a splice on such a line must land on the right character. Test in Task 1.
2. **CRLF files:** a write keeps every line ending CRLF and the final-newline state. Test in Task 1 and Task 6.
3. **An RStudio edit elsewhere in the same file:** a different function in the file changed after the page loaded; a `set_doc` on this function must still succeed (base is per item). Test in Task 6.
4. **Roxygen with `@export`, `@examples` (code lines, blank `#'` lines) and `@importFrom`:** a `set_doc` of the title or a `@param` keeps all of them verbatim and in order. Test in Task 3.
5. **Appending to a block list whose last element has a trailing comment** (`tar_target(x, f()) # note`): the comma goes right after the call, the comment stays on its line, the new element goes on a new line. Test in Task 5.

---

## File Structure

- Create `R/write_text.R`: file I/O preserving encoding/EOL, parse-column → character conversion, line splicing, line-block hash.
- Create `R/write_locate.R`: parse a file's lines for writing; find a function (doc block, formals, body), a target call (args with spans), a block list, the composition list; item base.
- Create `R/write_roxygen.R`: split a roxygen block into sections, set one field, generate roxygen/function/target text.
- Create `R/write_back.R`: one function per change kind, `apply_changes()`, `undo_changes()`.
- Modify `R/read_pipeline.R` (`assemble_model()`): `base` per function and target.
- Modify `R/server_api.R`, `R/server.R`: routes `api/edit`, `api/undo`; `building` flag; undo store; refresh after code write.
- Modify `inst/app/index.html`: change diff, live commit, optimistic state, undo via API, removal of `PENDING`/discard/confirm, dialog merge.
- Modify `tools/smoke.js`: live-page write checks.
- Tests: `tests/testthat/test-write_text.R`, `test-write_locate.R`, `test-write_roxygen.R`, `test-write_back.R`, additions to `test-server.R`, `test-read_pipeline.R`.
- Docs: `CLAUDE.md`, `NEWS.md`, `docs/backlog.md`, `mockup/pipeline-editor.html` (rebuilt).

## Change vocabulary (shared by Tasks 4–8)

JSON objects, one per change; `item`/`base` present on every change except `add_target`. Map variants always name their template.

```
set_doc         {kind, item:"function:<fn>", base, fn, field:"title"|"description"|"returns"|"family"|"param", param?, value: string|null}
set_formals     {kind, item, base, fn, formals:[{name, default: string|null}]}
set_body        {kind, item, base, fn, body}            # dedented text, as in the model
set_target_arg  {kind, item:"target:<t>", base, target, arg:"format"|"pattern"|"description", value: string|null}
set_call        {kind, item, base, target, args:[{name, value, named}]}
rename_function {kind, item, base, fn, to}
rename_target   {kind, item, base, target, to}
remove_target   {kind, item, base, target}
add_target      {kind, target, block, fn:{name,title,description,returns,family,params:{},formals:[],body}, args:[...], format, pattern}
```

- `value` of `format`/`description` is a plain string (R quotes it); of `pattern` it is R code. `null` removes the argument (`format = "rds"` is sent as `null`).
- Order within one request: all `set_*` (old names) → `rename_function` → `rename_target` → `remove_target` → `add_target`. R applies them in the given order, re-parsing after each; `base` is checked only the first time an item is touched in a request.
- `set_formals` and `set_call` are applied as **diffs by name** (formals) / by `(name, value)` (args) against the source: unchanged entries keep their source text, removed ones are cut with their comma, added ones are appended before `)`. Reordering is not supported (the page never reorders).
- `base` = `md5_lines(lines[line1:line2])` of the item's raw text: a function from its first roxygen line (`doc_line`) to `end_line`; a target from the first to the last line of its call.

---

### Task 1: Text layer

**Files:**
- Create: `R/write_text.R`
- Test: `tests/testthat/test-write_text.R`

**Interfaces:**
- Produces:
  - `read_text(file) -> list(lines = character, eol = "\n" | "\r\n", final_nl = logical)`. `lines` have no `\r`.
  - `write_text(file, txt)`: `txt` as from `read_text()`; writes a temp file in the same directory, then `file.rename()`; creates parent dirs for new files.
  - `pd_char(line, col) -> integer`: character index in `line` of parse-data column `col` (tabs advance to the next multiple of 8, 1-based columns).
  - `splice_lines(lines, edits) -> character`: `edits` is a data frame `line1, col1, line2, col2, text` in parse-data columns; replaces the inclusive range; `col2 == col1 - 1` on `line2 == line1` inserts before `col1`; `text` may contain `\n`. Applied bottom-up; overlapping edits → error `"Overlapping edits"`.
  - `md5_lines(lines) -> character` = `md5_text(paste(lines, collapse = "\n"))`.

- [ ] **Step 1: Write the failing tests**

```r
test_that("read_text/write_text keep CRLF and a missing final newline", {
  dir <- withr::local_tempdir(); f <- file.path(dir, "a.R")
  writeBin(charToRaw("x <- 1\r\ny <- 2"), f)
  t <- read_text(f)
  expect_equal(t$lines, c("x <- 1", "y <- 2")); expect_equal(t$eol, "\r\n"); expect_false(t$final_nl)
  t$lines[2] <- "y <- 3"; write_text(f, t)
  expect_equal(readBin(f, "raw", 100), charToRaw("x <- 1\r\ny <- 3"))
})
test_that("pd_char maps parse columns after tabs and multibyte characters", {
  line <- "\tx <- \"ä\"; y"
  pd <- utils::getParseData(parse(text = line, keep.source = TRUE))
  y <- pd[pd$token == "SYMBOL" & pd$text == "y", ]
  expect_equal(substr(line, pd_char(line, y$col1), pd_char(line, y$col2)), "y")
})
test_that("splice_lines replaces, inserts and refuses overlaps", {
  l <- c("f(a, b)", "g()")
  e <- data.frame(line1 = c(1, 2), col1 = c(6, 3), line2 = c(1, 2), col2 = c(6, 2), text = c("c", "z"))
  expect_equal(splice_lines(l, e), c("f(a, c)", "g(z)"))
  expect_equal(splice_lines(l, data.frame(line1 = 1, col1 = 8, line2 = 1, col2 = 7, text = "\n# x")), c("f(a, b)", "# x", "g()"))
  expect_error(splice_lines(l, data.frame(line1 = c(1, 1), col1 = c(1, 3), line2 = c(1, 1), col2 = c(4, 5), text = "")), "Overlapping")
})
```

- [ ] **Step 2: Run** `Rscript -e 'devtools::test(filter = "write_text")'` — Expected: FAIL, `could not find function "read_text"`.
- [ ] **Step 3: Implement the five functions in `R/write_text.R`** (`read_text` reads bytes with `readBin`, detects `\r\n` from the first line break, decodes as UTF-8).
- [ ] **Step 4: Run** the same command — Expected: PASS.
- [ ] **Step 5: Commit** `git add R/write_text.R tests/testthat/test-write_text.R && git commit -m "feat(write): text layer that keeps encoding, line endings and columns"`

---

### Task 2: Locating chunks and item bases

**Files:**
- Create: `R/write_locate.R`
- Modify: `R/read_pipeline.R` (`assemble_model()`: add `base`)
- Test: `tests/testthat/test-write_locate.R`, `tests/testthat/test-read_pipeline.R`

**Interfaces:**
- Consumes: `md5_lines()`, `TARGET_CALLS`, `match_call_args()`, `parse_descendants()` (existing).
- Produces:
  - `wb_parse(lines, file) -> list(lines, pd, kids)`; error `"Cannot parse <file>: …"` when it does not parse.
  - `wb_function(p, name) -> NULL | list(id, doc1, line1, line2, name_id, formals = data.frame(name, line1, col1, line2, col2), open_paren, close_paren, body_id, body_braced)`. `doc1` = first line of the contiguous `#'` block directly above, else `line1`. Spans are parse-data positions; formal spans cover `name = default`.
  - `wb_target(p, name) -> NULL | list(id, fn, line1, line2, close_paren, args = data.frame(name, line1, col1, line2, col2, text), cmd_id)`: the first call in `TARGET_CALLS` whose name argument is `name` (searched in every top-level expression, including inside `tar_map()`). `args$name` is `""` for positional args; `cmd_id` is the command expression (function-mode: the call whose args `set_call` edits).
  - `wb_block_list(p, holder) -> NULL | list(id, args, close_paren)` for the top-level `holder <- list(...)`.
  - `wb_composition(p) -> NULL | list(id, args, close_paren)`: the top-level `list(...)` in `_targets.R` that has at least one `pipeline_*` symbol argument.
  - `item_base(lines, line1, line2) -> character` = `md5_lines(lines[line1:line2])`.
  - Model: every function record gets `base` (over `doc_line..end_line`), every target record gets `base` (over its target item's `line1..line2`; variants use their template's item; `NULL` when no item).

- [ ] **Step 1: Write the failing tests** on `read_example()` file copies:

```r
test_that("wb_function finds doc block, formals and body of read_survey", {
  p <- wb_parse(read_utf8(file.path(example_dir(), "R/import.R")), "R/import.R")
  f <- wb_function(p, "read_survey")
  expect_equal(c(f$doc1, f$line1), c(1L, 9L)); expect_equal(f$formals$name, "path"); expect_true(f$body_braced)
})
test_that("wb_target finds calls in lists, in tar_map() and in template holders", {
  p <- wb_parse(read_utf8(file.path(example_dir(), "R/model.R")), "R/model.R")
  expect_equal(wb_target(p, "model_fit")$fn, "tar_target")
  expect_equal(wb_target(p, "predictions")$args$text[2], "predict_scores(model_fit_full, features)")
  pi <- wb_parse(read_utf8(file.path(example_dir(), "R/import.R")), "R/import.R")
  expect_equal(wb_target(pi, "raw_file")$args$name, c("", "", "format", "description"))
  expect_false(is.null(wb_target(pi, "area_data")))
  expect_null(wb_target(pi, "nope"))
})
test_that("wb_composition finds the list of blocks in _targets.R", {
  p <- wb_parse(read_utf8(file.path(example_dir(), "_targets.R")), "_targets.R")
  expect_equal(nrow(wb_composition(p)$args), 4L)
})
```

In `test-read_pipeline.R`: `base` of `read_survey` equals `item_base(read_utf8(<R/import.R>), doc_line, end_line)` of its record; `model_fit_full$base == model_fit_base$base`; every target with a `qa` item has a 32-char `base`.

- [ ] **Step 2: Run** `Rscript -e 'devtools::test(filter = "write_locate|read_pipeline")'` — Expected: FAIL.
- [ ] **Step 3: Implement `R/write_locate.R`** and add `base` in `assemble_model()` (items are already at hand there; read each file once).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(write): locate functions, targets and block lists by parse tokens; base per item"`

---

### Task 3: Roxygen splicing and text generators

**Files:**
- Create: `R/write_roxygen.R`
- Test: `tests/testthat/test-write_roxygen.R`

**Interfaces:**
- Produces:
  - `rox_set(block, field, value, param = NULL, formals = character()) -> character`: `block` = roxygen lines (may be `character()`), returns the new block. Sections: title paragraph, description paragraph(s) (or `@title`/`@description` tags), tag sections (a tag runs until the next line whose text after `#'` starts with `@`). Only the changed field's section is replaced; `value = NULL` removes it (used for `param`). Missing tag inserted in the order `@param` (in `formals` order) → `@return` → `@family`, before the first unknown tag; missing block → generated from scratch with `"TODO: one-line title"` as title.
  - `rox_lines(text, tag = NULL) -> character`: `#' ` lines wrapped at 76 columns; continuation lines of a tag indented `#'   `.
  - `function_text(fn) -> character` (roxygen + `name <- function(formals) {` + body indented 2 + `}`; same output as the page's `fnBlock()`).
  - `target_text(name, fn, args, format = NULL, pattern = NULL) -> character` (same layout as the page's `tarCall()`).

- [ ] **Step 1: Write the failing tests**

```r
blk <- c("#' Old title", "#'", "#' Some text.", "#'", "#' @param x An x.",
         "#' @return A y.", "#' @examples", "#' f(1)", "#'", "#' f(2)", "#' @export", "#' @importFrom stats lm")
test_that("set title keeps every other line verbatim", {
  out <- rox_set(blk, "title", "New title")
  expect_equal(out[1], "#' New title"); expect_equal(out[-1], blk[-1])
})
test_that("set param replaces only its section; missing tags go before unknown tags", {
  out <- rox_set(blk, "param", "A longer x.", param = "x", formals = "x")
  expect_equal(out[5], "#' @param x A longer x."); expect_equal(out[-5], blk[-5])
  out2 <- rox_set(blk, "family", "Modelling")
  expect_equal(out2[7], "#' @family Modelling"); expect_equal(out2[8:13], blk[7:12])
})
test_that("param removal and a missing block", {
  expect_false(any(grepl("@param x", rox_set(blk, "param", NULL, param = "x"))))
  expect_equal(rox_set(character(), "returns", "A z.")[c(1, length(rox_set(character(), "returns", "A z.")))],
               c("#' TODO: one-line title", "#' @return A z."))
})
test_that("target_text uses one line when it fits", {
  expect_equal(target_text("a", "f", list(list(name = "x", value = "b", named = FALSE))), "tar_target(a, f(b))")
})
```

- [ ] **Step 2: Run** `Rscript -e 'devtools::test(filter = "write_roxygen")'` — Expected: FAIL.
- [ ] **Step 3: Implement** `R/write_roxygen.R` (port `wrap()`, `roxygenFor()`, `signatureFor()`, `tarCall()` from `inst/app/index.html:1157-1182`).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(write): roxygen field splicing and text generators"`

---

### Task 4: Change kinds within one item

**Files:**
- Create: `R/write_back.R`
- Test: `tests/testthat/test-write_back.R`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: each `chg_<kind>(files, ch) -> files`, where `files` is a named list `rel path -> read_text()` result (loaded lazily by `wb_files_get(files, path, rel)`; see Task 6) and `ch` is a change (list from JSON). Errors use `wb_bad(msg)` (class `pipeworks_bad_change`) for impossible changes:
  - `chg_set_doc`, `chg_set_formals`, `chg_set_body`, `chg_set_target_arg`, `chg_set_call`.
  - `wb_find_function(files, name) -> list(rel, p, f)`, `wb_find_target(files, name) -> list(rel, p, t)` search all `R/**.R` and `_targets.R`.
  - `set_body` on a function without braced body → `wb_bad("<fn>() has no braced body; change it in RStudio.")`.

- [ ] **Step 1: Write the failing tests** (a helper `wb_example()` copies the example with `local_project()` and returns `list(path, files = wb_files(path))`; `wb_lines(files, rel)` returns lines):

```r
test_that("set_doc on read_survey changes only its title line", {
  x <- wb_example(); before <- wb_lines(x$files, "R/import.R")
  out <- chg_set_doc(x$files, list(kind = "set_doc", fn = "read_survey", field = "title", value = "Read the export"))
  after <- wb_lines(out, "R/import.R")
  expect_equal(after[1], "#' Read the export"); expect_equal(after[-1], before[-1])
})
test_that("set_formals adds a formal and keeps the others' text", {
  x <- wb_example()
  out <- chg_set_formals(x$files, list(fn = "score_histogram",
    formals = list(list(name = "data", default = NULL), list(name = "title", default = NULL), list(name = "bins", default = "NULL"))))
  expect_true(any(wb_lines(out, "R/report.R") == "score_histogram <- function(data, title, bins = NULL) {"))
})
test_that("set_call plugs an argument into raw_data's command, keeping the arg name differing from the target (read_survey(path) <- raw_file)", {
  x <- wb_example()
  out <- chg_set_call(x$files, list(target = "raw_data", args = list(
    list(name = "path", value = "raw_file", named = FALSE), list(name = "regions", value = "regions", named = TRUE))))
  expect_true(any(grepl("tar_target(raw_data, read_survey(raw_file, regions = regions))", wb_lines(out, "R/import.R"), fixed = TRUE)))
})
test_that("set_target_arg replaces, appends and removes format/pattern/description", {
  x <- wb_example()
  out <- chg_set_target_arg(x$files, list(target = "raw_file", arg = "format", value = NULL))
  expect_false(any(grepl('format = "file"', wb_lines(out, "R/import.R"))))
  out <- chg_set_target_arg(x$files, list(target = "clean_data", arg = "format", value = "qs"))
  expect_true(any(grepl('tar_target(clean_data, clean_survey(raw_data), format = "qs")', wb_lines(out, "R/import.R"), fixed = TRUE)))
})
test_that("set_body re-indents and keeps the signature", {
  x <- wb_example()
  out <- chg_set_body(x$files, list(fn = "select_area", body = "x <- 1\ndata"))
  l <- wb_lines(out, "R/import.R"); i <- which(l == "select_area <- function(data, area) {")
  expect_equal(l[i + 1:3], c("  x <- 1", "  data", "}"))
})
```

- [ ] **Step 2: Run** `Rscript -e 'devtools::test(filter = "write_back")'` — Expected: FAIL.
- [ ] **Step 3: Implement the five `chg_*` functions** in `R/write_back.R`; each builds an `edits` frame and calls `splice_lines()`. New arguments/formals are appended as `, <text>` before `close_paren`; if existing args are one per line, the new one goes on its own line with the same indentation.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(write): doc, formals, body, call and target-argument changes"`

---

### Task 5: Renames, removal, new targets

**Files:**
- Modify: `R/write_back.R`
- Test: `tests/testthat/test-write_back.R`

**Interfaces:**
- Produces: `chg_rename_function`, `chg_rename_target`, `chg_remove_target`, `chg_add_target` (same signature as Task 4). Each may touch several files.
  - `chg_*` may add a note via `attr(files, "notes")` (character, appended); `rename_function` adds `"Renamed <n> call(s) of <fn>(); calls by string or in reports are not followed."`.
  - `rename_function`: assignment name token, every `SYMBOL_FUNCTION_CALL` with text `fn` not preceded by `NS_GET`/`NS_GET_INT`, in all `R/**.R` and `_targets.R`. Target name exists → `wb_bad`.
  - `rename_target`: the name argument, plus every `SYMBOL` token `== target` inside other target calls' non-name arguments. Refused (`wb_bad`) when: a report source (`tar_render`/`tar_quarto` path argument) matches `tar_(read|load)\(\s*<target>\s*[,)]`; the target is a map template and any `SYMBOL` outside its map starts with `<target>_`; the new name is taken.
  - `remove_target`: the call and one separating comma (the following one; the preceding one for the last element). Refused when it is the only template of a `tar_map()`.
  - `add_target`: block file `ch$block` (`R/<stem>.R`, holder `pipeline_<stem>`). Function inserted above the holder's assignment (blank line before and after); call appended to the block list (comma after the last element's expression, new element on a new line after that line, indented like the last element, or two spaces for an empty list). No holder in the file → append `pipeline_<stem> <- list(\n  <call>\n)` at the end and add `pipeline_<stem>` to `wb_composition()` the same way. No composition found → `wb_bad("Cannot find the list of blocks in _targets.R; add pipeline_<stem> there by hand.")`. New file → created with the function and the holder, plus the composition entry. Empty body → `stop("Not implemented: <fn>()")`.

- [ ] **Step 1: Write the failing tests**

```r
test_that("rename_function renames the definition and calls, not pkg::calls", {
  x <- wb_example()
  out <- chg_rename_function(x$files, list(fn = "rescale01", to = "rescale_unit"))
  expect_true(any(grepl("^rescale_unit <- function", wb_lines(out, "R/utils.R"))))
  expect_equal(sum(grepl("rescale_unit(", wb_lines(out, "R/model.R"), fixed = TRUE)), 2L)
  expect_false(any(grepl("rescale01", unlist(lapply(names(out), function(r) wb_lines(out, r))))))
})
test_that("rename_target updates references and refuses map templates referenced by variant", {
  x <- wb_example()
  out <- chg_rename_target(x$files, list(target = "clean_data", to = "tidy_data"))
  expect_true(any(grepl("build_features(tidy_data)", wb_lines(out, "R/model.R"), fixed = TRUE)))
  expect_error(chg_rename_target(x$files, list(target = "model_fit", to = "fit")), "model_fit_full", class = "pipeworks_bad_change")
})
test_that("rename_target refuses a target read by the report", {
  x <- wb_example()
  expect_error(chg_rename_target(x$files, list(target = "predictions", to = "preds")), "report", class = "pipeworks_bad_change")
})
test_that("remove_target cuts the call and its comma", {
  x <- wb_example()
  out <- chg_remove_target(x$files, list(target = "regions"))
  p <- wb_parse(wb_lines(out, "R/import.R"), "R/import.R")
  expect_null(wb_target(p, "regions")); expect_equal(nrow(wb_block_list(p, "pipeline_import")$args), 3L)
})
test_that("add_target keeps a trailing comment on the last element's line", {
  path <- local_project(list("_targets.R" = c("library(targets)", "tar_source()", "list(pipeline_a)"),
    "R/a.R" = c("f <- function() 1", "", "pipeline_a <- list(", "  tar_target(x, f()) # note", ")")))
  out <- chg_add_target(wb_files(path), list(target = "y", block = "R/a.R",
    fn = list(name = "g", title = "G", description = "", returns = "One.", family = "", params = list(), formals = list(), body = "1"),
    args = list(), format = NULL, pattern = NULL))
  l <- wb_lines(out, "R/a.R"); i <- which(l == "  tar_target(x, f()), # note")
  expect_equal(l[i + 1:2], c("  tar_target(y, g())", ")"))
})
test_that("add_target into a new file creates block and composition entry", {
  x <- wb_example()
  out <- chg_add_target(x$files, list(target = "report_table", block = "R/tables.R",
    fn = list(name = "make_table", title = "Make the table", description = "", returns = "A tibble.", family = "",
              params = list(predictions = "Predictions."), formals = list(list(name = "predictions", default = NULL)), body = ""),
    args = list(list(name = "predictions", value = "predictions", named = FALSE)), format = NULL, pattern = NULL))
  l <- wb_lines(out, "R/tables.R")
  expect_true(any(l == '  stop("Not implemented: make_table()")'))
  expect_true(any(grepl("tar_target(report_table, make_table(predictions))", l, fixed = TRUE)))
  expect_true(any(grepl("pipeline_tables", wb_lines(out, "_targets.R"))))
})
test_that("add_target into R/utils.R (no block list) creates pipeline_utils", {
  # same call as the new-file test with block = "R/utils.R"; assert a line `pipeline_utils <- list(`
  # in R/utils.R and that `pipeline_utils` is an argument of wb_composition() of _targets.R
})
```

- [ ] **Step 2: Run** `Rscript -e 'devtools::test(filter = "write_back")'` — Expected: the new tests FAIL.
- [ ] **Step 3: Implement the four functions.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(write): renames, removal and new targets"`

---

### Task 6: Transaction and undo

**Files:**
- Modify: `R/write_back.R`
- Test: `tests/testthat/test-write_back.R`

**Interfaces:**
- Produces:
  - `wb_files(path) -> environment-backed lazy list`; `wb_files_get(files, rel)`.
  - `apply_changes(path, changes) -> list(files = character (rel), notes = character, undo = list(<rel> = list(before = character, after = character, existed = logical)))`.
    1. Validate every change (known `kind`, required fields as strings/lists) → `pipeworks_bad_change`.
    2. For each change in order: if it has `item`/`base` and the item was not touched earlier in this request, locate it and compare `item_base()` → mismatch or missing: `wb_stale(item, rel)` (class `pipeworks_stale`, message `"<item> in <file> changed since the page loaded it. The view is refreshed; try again."`). Then dispatch `chg_<kind>()`.
    3. Re-parse each touched file; failure → `stop("Bug: the change would break <file>; nothing was written.")`.
    4. Write each touched file with `write_text()`; on error restore the already written ones from `before` (delete new files) and rethrow.
  - `undo_changes(path, undo) -> character (rel files)`: per file trim the common prefix and suffix of `before`/`after` to one region; find the region's `after` lines exactly once in the current file → replace with the `before` lines (a created file is deleted if it still equals `after`); else `wb_stale()` with message `"<file> changed since that edit; undo it in RStudio."`. Checks all files before writing any.

- [ ] **Step 1: Write the failing tests**

```r
test_that("a stale base refuses the whole request and writes nothing", {
  x <- wb_example(); md5 <- tools::md5sum(file.path(x$path, "R/import.R"))
  ch <- list(list(kind = "set_doc", item = "function:read_survey", base = "0", fn = "read_survey", field = "title", value = "X"))
  expect_error(apply_changes(x$path, ch), class = "pipeworks_stale")
  expect_equal(tools::md5sum(file.path(x$path, "R/import.R")), md5)
})
test_that("an edit of another function in the same file does not block the write", {
  x <- wb_example(); base <- wb_base_of(x$path, "function:read_survey")
  l <- read_utf8(file.path(x$path, "R/import.R")); l[l == "  dplyr::filter(data, .data$area == .env$area)"] <- "  dplyr::filter(data, area == .env$area)"
  writeLines(l, file.path(x$path, "R/import.R"))
  res <- apply_changes(x$path, list(list(kind = "set_doc", item = "function:read_survey", base = base, fn = "read_survey", field = "title", value = "X")))
  expect_equal(res$files, "R/import.R")
})
test_that("CRLF survives apply and undo", {
  x <- wb_example(); f <- file.path(x$path, "R/report.R")
  orig <- charToRaw(paste0(paste(read_utf8(f), collapse = "\r\n"), "\r\n")); writeBin(orig, f)
  res <- apply_changes(x$path, list(list(kind = "set_doc", item = "function:score_histogram",
    base = wb_base_of(x$path, "function:score_histogram"), fn = "score_histogram", field = "title", value = "Histogram")))
  txt <- rawToChar(readBin(f, "raw", 1e6))
  expect_false(grepl("[^\r]\n", txt)); expect_match(txt, "^#' Histogram\r\n")
  undo_changes(x$path, res$undo); expect_equal(readBin(f, "raw", 1e6), orig)
})
test_that("a failing second file restores the first", {
  x <- wb_example(); base_write <- write_text
  before <- lapply(c("R/utils.R", "R/model.R"), function(r) read_utf8(file.path(x$path, r)))
  local_mocked_bindings(write_text = function(file, txt) if (grepl("model", file)) stop("disk full") else base_write(file, txt))
  expect_error(apply_changes(x$path, list(list(kind = "rename_function", item = "function:rescale01",
    base = wb_base_of(x$path, "function:rescale01"), fn = "rescale01", to = "rescale_unit"))), "disk full")
  expect_equal(lapply(c("R/utils.R", "R/model.R"), function(r) read_utf8(file.path(x$path, r))), before)
})
test_that("undo restores the text and refuses after an intervening edit", {
  # apply set_doc(read_survey title) -> undo_changes() -> R/import.R equals the original lines;
  # apply again, then change the new title line by hand -> undo_changes() errors with class "pipeworks_stale"
  # and leaves the file as edited by hand
})
```

`wb_base_of(path, item)` is a test helper computing the base like the model does (`item_base()` over the item's lines from `read_source()` items / `read_functions()` records).

- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement** `wb_files`, `apply_changes`, `undo_changes`, `wb_stale`, `wb_bad`.
- [ ] **Step 4: Run** `Rscript -e 'devtools::test(filter = "write")'` — Expected: PASS. Then one round-trip test: apply `rename_target(clean_data -> tidy_data)` on a `local_example_repo()` copy and assert `read_pipeline(path, status = FALSE)` has a target `tidy_data`.
- [ ] **Step 5: Commit** `git commit -m "feat(write): all-or-none transaction with stale checks and undo"`

---

### Task 7: Server routes

**Files:**
- Modify: `R/server_api.R` (routes, header comment), `R/server.R` (`pw_state()`: `writes`, `write_seq`; `pw_live()`: `building`)
- Test: `tests/testthat/test-server.R`

**Interfaces:**
- Consumes: `apply_changes()`, `undo_changes()`, `rstudio_available()`.
- Produces:
  - `POST /api/edit {changes}` → `200 {ok: true, write_id, version, files, notes}`; `409 {error, item, file}` (`pipeworks_stale`); `400 {error}` (`pipeworks_bad_change`, non-list `changes`, empty list).
  - `POST /api/undo {write_id}` → `200 {ok, version, files}`; `404` unknown id; `409` stale. The undo record is dropped after success.
  - `pw_save_buffers()`: `if (rstudio_available()) try(rstudioapi::documentSaveAll(), silent = TRUE)`; called before both routes.
  - `pw_refresh_after_code_write(state)`: `pw_refresh_qa(state)`, `pw_start_bg(state)`, `state$fingerprint$code <- pw_fingerprint(state)$code`, version bumped.
  - `pw_live()$building`: `TRUE` while `state$bg` is non-NULL.
  - `state$writes`: environment `write_id -> undo`; ids `"w1"`, `"w2"`, …; at most 100 kept (oldest dropped).

- [ ] **Step 1: Write the failing tests** (with `local_state()` on `local_example_repo()`; mock `pw_start_bg` to set `state$bg <- list(is_alive = function() TRUE, kill = function() NULL)` so no process starts):

```r
test_that("api/edit writes, returns a write id and marks the model as building", {
  repo <- local_example_repo(); state <- local_state(repo)
  local_mocked_bindings(pw_start_bg = function(state) { state$bg <- fake_bg(); invisible(state) })
  base <- wb_base_of(repo, "function:read_survey")
  res <- call_app(state, method = "POST", path = "/api/edit", body = list(changes = list(list(
    kind = "set_doc", item = "function:read_survey", base = base, fn = "read_survey", field = "title", value = "X"))))
  expect_equal(res$status, 200L); expect_equal(res$json$write_id, "w1")
  expect_equal(readLines(file.path(repo, "R/import.R"))[1], "#' X")
  expect_true(call_app(state, path = "/api/model")$json$live$building)
})
test_that("api/edit answers 409 on a stale base and 400 on a bad change", {
  # base = "0" -> status 409, json$item == "function:read_survey", json$file == "R/import.R", file unchanged
  # changes = list(list(kind = "frobnicate")) -> 400; body without `changes` -> 400; changes = list() -> 400
})
test_that("api/undo restores and forgets the write", {
  # edit as above -> undo {write_id: "w1"} -> 200, R/import.R line 1 is the original title;
  # the same undo again -> 404; undo {write_id: "w9"} -> 404
})
```

- [ ] **Step 2: Run** `Rscript -e 'devtools::test(filter = "server")'` — Expected: FAIL.
- [ ] **Step 3: Implement** routes and helpers; update the route-contract comment at the top of `R/server_api.R` and the file header of `R/server.R` ("The browser never writes files" → writes go through `record_verdict()` and `apply_changes()`).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(server): api/edit and api/undo write code changes"`

---

### Task 8: Page writes through to the files

**Files:**
- Modify: `inst/app/index.html`
- Test: `tools/smoke.js`

**Interfaces:**
- Consumes: routes from Task 7; `base` on functions and targets (Task 2; copy it in `fromModel()`).
- Produces (JS, in `index.html`):
  - `diffChanges(a, b) -> Array<change>`: `a`, `b` are `{targets, fns, edges}` snapshots. Per target id in both: name → `rename_target`; `format` (`'rds'` → `null`), `pattern`, `description` (expression targets only) → `set_target_arg`; args differ → `set_call`. Per function (matched through targets: same id, `a.fn !== b.fn` and `a.fns[old]` missing in `b` → `rename_function`): title/description/returns/family/each param → `set_doc`; formals → `set_formals`; body → `set_body`. Ids only in `a` → `remove_target`; only in `b` → `add_target`. Map variants map to their template (`t.map.template`); duplicates from several variants are dropped. Emitted in the vocabulary's order; `item`/`base` from `a`.
  - `liveCommit(before, label)`: called at the end of `connect`, `unplug`, `removeTarget`, `saveModal` when `IS_LIVE` (instead of `push()`); computes `diffChanges(JSON.parse(before), current)`, marks touched nodes with class `.wr`, POSTs `api/edit`. One request at a time: actions while a request is open are refused with toast `"Still writing the last change…"`.
    - success: `undoStack.push({write_id, label})`, `WAIT = version`, toast `"Written to <files>."` plus the server's `notes` (with Undo). After `remove_target`, if its function has no remaining target (`usedBy`) and no caller (`called_by`), the toast adds `"<fn>() is now unused."`.
    - error: `applyModel(RAW)` (last model), toast with the server's message; a dialog action keeps the dialog open with the user's text.
  - `fetchModel()`: in Build mode, apply the model only when `!m.live.building && (WAIT == null || m.live.version > WAIT)`; then `WAIT = null`. Review mode unchanged.
  - Live `undo()`: POST `api/undo {write_id}` of the top entry; on success toast `"Undone: <label>."`.
  - Remove `PENDING`, `viewDiffers()`, `modalDirty()` uses for gating, `askDiscard()`, the Build→Review confirmation panel and its CSS/markup; `applyPending()` goes.
  - Live wording: drop `"Writing to files comes with the live connection"`; the Build-dialog footer hint reads `"Apply writes to your files"`. Static page keeps current texts and snapshot undo.

- [ ] **Step 1: Write the failing smoke checks** in `tools/smoke.js` (a live page built with `makeDom(html with live block, { fetch })`, where the fake fetch records POST bodies and answers `{ok:true, write_id:'w1', version: 2, files:['R/import.R']}`):
  - Applying a new title on `raw_data`'s dialog posts exactly one change `{kind:'set_doc', fn:'read_survey', field:'title', item:'function:read_survey'}` with the model's `base`.
  - Plugging `regions` into `raw_data` posts `set_call` + `set_formals` + `set_doc(param regions)` in that order.
  - Renaming target `clean_data` posts `rename_target` and no `set_call` for its users.
  - Editing `model_fit_full`'s function title posts one change for function `fit_score_model`.
  - A `409` answer restores the previous title on the canvas and shows the message.
  - While a model with `building: true` arrives, the canvas keeps the optimistic edit; a later `building: false, version: 3` model is applied.
  - Undo posts `api/undo {write_id:'w1'}`.
- [ ] **Step 2: Run** `Rscript tools/build-demo.R && NODE_PATH=$(npm root -g) node tools/smoke.js mockup/pipeline-editor.html` — Expected: the new checks FAIL, existing ones pass.
- [ ] **Step 3: Implement** the functions above in `inst/app/index.html`.
- [ ] **Step 4: Run** the same command — Expected: `all checks passed`.
- [ ] **Step 5: Commit** `git commit -m "feat(editor): Build actions write through to the files"`

---

### Task 9: Open dialog follows file changes

**Files:**
- Modify: `inst/app/index.html` (`openModal`, `applyModel`, `saveModal`)
- Test: `tools/smoke.js`

**Interfaces:**
- Produces: `M.start` (deep copy of `{t, f, deps}` at open). `saveModal()` diffs `M.start` → `M` (not the current `S`), so only touched fields are sent. In `applyModel()`, with a dialog open on a surviving target: each field (target name/description/format/pattern, function title/description/returns/family/body/each param) where `M` equals `M.start` takes the new model's value; touched fields keep the user's text; if any touched field's new model value differs from `M.start`, show a notice `"<item> changed in your files since you opened this dialog. Your edits are kept; untouched fields were updated."`; then `M.start` = new model values and `base` = new base.

- [ ] **Step 1: Write the failing smoke checks:** open `clean_data`'s dialog, type a new description, deliver a model in which `clean_survey`'s title changed on disk → title field shows the new title, description keeps the typed text, notice shown; Apply posts only `set_doc(description)` with the new base.
- [ ] **Step 2: Run** the smoke command — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: `all checks passed`.
- [ ] **Step 5: Commit** `git commit -m "feat(editor): open dialog merges file changes field by field"`

---

### Task 10: Docs and final checks

**Files:**
- Modify: `CLAUDE.md` (Editor frontend: replace "Edits of the pipeline in the editor stay in memory…" with the write-back rule and `R/write_*.R`; Live server: new routes), `NEWS.md`, `docs/backlog.md` (remove the write-back item; add "rename in report sources" and "edit expression commands" as follow-ups), the editor's notice text (`"The editor is connected to R, but edits of the pipeline … stay in memory"` → says Build edits are written to the files), `mockup/pipeline-editor.html` (rebuild).

- [ ] **Step 1:** Update the texts above; `grep -rn "stay in memory\|files are unchanged" inst R CLAUDE.md` — Expected: no hits on the live path (static-page wording may stay).
- [ ] **Step 2:** `Rscript tools/build-demo.R && NODE_PATH=$(npm root -g) node tools/smoke.js mockup/pipeline-editor.html` — Expected: `all checks passed`.
- [ ] **Step 3:** `Rscript -e 'devtools::document(); devtools::test()'` — Expected: 0 failures. `Rscript -e 'devtools::check()'` — Expected: 0 errors, 0 warnings, 0 notes.
- [ ] **Step 4: Commit** `git commit -m "docs: write-back from Build mode"`
