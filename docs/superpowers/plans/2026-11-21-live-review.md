# Live Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reviewers record and commit verdicts from the editor (live, console free) or with `qa_walk()` in the console; the editor separates Review and Build modes, can hide its sidebar and switch themes.

**Architecture:** One internal verdict path (`record_verdict()` + `commit_verdict()`) shared by `qa_review()`, `qa_walk()` and the server. `pipeworks()` starts an in-session httpuv server per project (token, Host/Origin checks), serves the editor with a `live` flag, answers small JSON API calls, watches files via `later`, and rebuilds the structural model in a `callr::r_bg()` process. The page polls a version endpoint.

**Tech Stack:** R (>= 4.1), httpuv, later, callr, jsonlite, roxygen2, targets, withr; git CLI; vanilla JS in `inst/app/index.html`; jsdom for smoke tests.

**Spec:** `docs/superpowers/specs/2026-11-21-live-review-design.md` (sections "Decisions after the builder check" and "Additions requested by the user" override earlier sections). Builds on `docs/superpowers/specs/2026-11-20-qa-reviews-design.md`.

## Global Constraints

- Imports add exactly: `httpuv`, `later`, `callr`. `rstudioapi` stays in Suggests.
- The browser never writes files; every write goes through `record_verdict()` with `qa_review()`'s checks unchanged (whole code tree committed, comment for questionable/wrong, git identity required, author known).
- Verdict commit: `git add -- <entry>` then `git commit --only -m "qa: <verdict> <item id>" -- <entry>`; configured identity; hooks run; refuse before writing during merge/rebase/cherry-pick or with `.git/index.lock`.
- Server binds `127.0.0.1`, random free port; API requires header `X-Pipeworks-Token`; `Host` must be `127.0.0.1:<port>` or `localhost:<port>`; state-changing requests with a foreign `Origin` → 403; token removed from the address bar after load.
- One server per normalised absolute project path; reopening reuses server and token.
- Mode `auto` decides by role: Review when open items exist whose last author is not the current git user (via `person_of()`), else Build.
- `inst/app/index.html` stays an HTML fragment; state classes `.sel/.dim/.hl/.drop` never on form controls; the `[hidden][hidden]` rule stays the last CSS rule.
- No POSIX-only paths or shell features (Windows).
- `devtools::test()` and `devtools::check()` clean after every task; smoke test (`tools/smoke.js`) green after every frontend task.
- Commits via `jj commit -m "<subject>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.

## Review Focus

1. A verdict while the user has other files staged: only the entry is committed; the other files stay staged and uncommitted. Test in Task 2.
2. Two quick verdicts on different items: both entries end up in two commits; no "index.lock" race between them. Test in Task 2.
3. A request without the token, with a wrong Host, or a POST with a foreign Origin: 403, nothing written. Test in Task 4.
4. `_targets.R` saved half-edited (syntax error) while the editor is open: page keeps the last good model and shows the error; QA status still updates for other files. Test in Task 4 (handler-level) and Task 5 (smoke).
5. `qa_walk()` in a non-interactive session or with a dirty tree: clear error before any prompt. Test in Task 3.

---

## File Structure

| File | Responsibility |
|---|---|
| `R/source_model.R` | loader detection (Task 1) |
| `R/qa.R` | `qa_review()` on top of `record_verdict()` |
| `R/verdict.R` | `record_verdict()`, `commit_verdict()`, `git_busy()`, `retry_uncommitted()` |
| `R/qa_walk.R` | `qa_walk()` |
| `R/server.R` | server lifecycle, routes, security, watcher, background model |
| `R/pipeworks.R` | `pipeworks()` (live), `pipeworks_stop()`, `pipeworks_html()` (static), `mode` |
| `inst/app/index.html` | live client, verdict panel, modes, sidebar toggle, theme switch |
| `tools/smoke.js` | jsdom checks incl. a fake live API |

---

### Task 1: Loader detection gap

**Files:** Modify `R/source_model.R` (loader detection); Test `tests/testthat/test-coverage.R`.

**Interfaces:** Produces: the existing external-loader report used by `qa_status()`/`qa_check()` also contains these cases.

- [ ] **Step 1: Failing tests** — each of these in `_targets.R` (with a `scripts/h.R` file) makes `qa_check()` fail with a message naming the call and file:
```r
"lapply(list.files('scripts', full.names = TRUE), source)"
"purrr::walk(list.files('scripts', full.names = TRUE), source)"
"do.call('source', list('scripts/h.R'))"
"eval(parse(file = 'scripts/h.R'))"
"invisible(sapply(c('scripts/h.R'), sys.source, envir = globalenv()))"
```
and `x <- function(source) source + 1` (a formal named `source`) does NOT fail.
- [ ] **Step 2: Run** `Rscript -e 'devtools::test(filter = "coverage")'` → FAIL.
- [ ] **Step 3: Implement**: also flag `SYMBOL` tokens `source`/`sys.source` used as values (not as formals or `$`-members), `do.call` with first argument `"source"`/`"sys.source"`/`source`, and `eval(parse(file = ...))`/`eval(parse(<string>))`.
- [ ] **Step 4: Run** → PASS; full suite PASS.
- [ ] **Step 5: Commit** `fix(qa): detect source used as a value and eval(parse())`

---

### Task 2: Shared verdict path with commit

**Files:** Create `R/verdict.R`; Modify `R/qa.R`, `R/example.R` (scenario no longer commits entries separately if `qa_review()` commits); Test `tests/testthat/test-verdict.R`, adjust `test-qa_review.R`, `test-example.R`.

**Interfaces:**
- Produces `record_verdict(path, item, verdict, comment = NULL, commit = TRUE) -> list(entry, file, committed (lgl), commit (chr or NA), error (chr or NA))`. Validates exactly like today's `qa_review()`, refuses up front via `git_busy(path)`, writes the entry, then `commit_verdict()` when `commit = TRUE`. A commit failure returns `committed = FALSE` with `error`, it does not throw (the entry stays on disk).
- Produces `commit_verdict(path, file, message) -> chr commit sha` (errors with git's message); `git_busy(path) -> chr or NA` (NA when free, else a reason: "merge in progress", "rebase in progress", "cherry-pick in progress", "index.lock present"); `uncommitted_reviews(path) -> chr` (entry files not committed); `retry_uncommitted(path) -> data.frame(file, committed, error)`.
- `qa_review(item, verdict, comment = NULL, path = ".", commit = TRUE)` delegates to `record_verdict()`; errors if `committed` is FALSE after writing ("The verdict was saved to <file> but not committed: <error>"); returns the entry invisibly; message `✔ <id>: <verdict> (hash <7>), committed <sha7>`.

- [ ] **Step 1: Failing tests** (`test-verdict.R`):
```r
test_that("a verdict commits only its entry, staged work stays staged", {
  repo <- local_git_repo(list("R/a.R" = "f <- function(x) x", "_targets.R" = "list(tar_target(t1, f(1)))",
                              "notes.txt" = "a"), author = c("Ann", "ann@wig2.de"))
  set_git_user(repo, "Bob", "bob@wig2.de")
  writeLines("b", file.path(repo, "notes.txt")); git_run(repo, c("add", "notes.txt"))
  r <- record_verdict(repo, "function:f", "correct")
  expect_true(r$committed)
  expect_equal(git_run(repo, c("log", "-1", "--format=%s")), "qa: correct function:f")
  expect_equal(git_run(repo, c("show", "--name-only", "--format=", "HEAD")), sub(paste0(repo, "/"), "", r$file, fixed = TRUE))
  expect_equal(git_run(repo, c("diff", "--cached", "--name-only")), "notes.txt")
})
test_that("two quick verdicts give two commits", { … record_verdict twice on function:f and target:t1 → `git rev-list --count HEAD` grew by 2 … })
test_that("busy repositories are refused before writing", { … create .git/index.lock → error matching "index.lock", no file in qa/reviews … })
test_that("a failing commit keeps the entry and reports it", { … install a failing pre-commit hook (R script via Rscript for portability) → committed FALSE, file exists, uncommitted_reviews() lists it; remove hook → retry_uncommitted() commits it … })
```
- [ ] **Step 2: Run** `devtools::test(filter = "verdict")` → FAIL.
- [ ] **Step 3: Implement** `R/verdict.R`; rewire `qa_review()`; update `example_project(git = TRUE)` so it relies on `qa_review()` committing (no duplicate commits; keep its scenario and expected open ids).
- [ ] **Step 4: Run** focused + full suite → PASS.
- [ ] **Step 5: Commit** `feat(qa): verdicts are committed one by one`

---

### Task 3: qa_walk()

**Files:** Create `R/qa_walk.R`; Test `tests/testthat/test-qa_walk.R`.

**Interfaces:**
- Produces `qa_walk(path = ".", base = NULL, include = c("open", "check_again"), input = NULL) -> invisible(data.frame(item, verdict, committed))`. `include` selects open items (not `qa_passing()`) and/or `check_again` hints; order by block then item. For each item prints id, status, last author (warning line when it is the current reviewer: "You last changed this; your verdict will be flagged as self-review."), the item's code and its diff against `base` (default: the repo's `main`/`master` if present). Prompt `[c]orrect  [q]uestionable  [w]rong  [s]kip  [x] quit:`; questionable/wrong then ask `Comment:` (empty re-asks). Records via `record_verdict()`. Refuses up front in non-interactive sessions when `input` is NULL ("qa_walk() needs an interactive session"), with a dirty tree (same message as qa_review, listing files), or when `git_busy()`.
- `input` is a testing seam: a function `(prompt) -> chr` used instead of `readline()`.

- [ ] **Step 1: Failing tests**: on `example_project(git = TRUE)` as the senior, `qa_walk(p, input = scripted(c("c", "q", "needs a unit test", "c")))` records 3 verdicts as 3 commits and `qa_check(p)` then fails only if something remains (assert exactly which); `x` quits early leaving the rest open; non-interactive without `input` errors; dirty tree errors before any prompt (assert `input` was never called).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** focused + full → PASS.
- [ ] **Step 5: Commit** `feat(qa): qa_walk() for quick console reviews`

---

### Task 4: Live server (R side)

**Files:** Create `R/server.R`; Modify `R/pipeworks.R`, `R/read_pipeline.R` (expose a cheap QA-only refresh), DESCRIPTION; Test `tests/testthat/test-server.R`.

**Interfaces:**
- Produces `pipeworks(path = ".", viewer = getOption("pipeworks.viewer", TRUE), mode = c("auto", "review", "build"))` → starts or reuses the server, opens `http://127.0.0.1:<port>/?token=<token>` in the Viewer (`rstudioapi::viewer`) or browser; returns `invisible(url)`. `pipeworks_stop(path = ".")` → stops it (invisible TRUE/FALSE). Internal registry keyed by `normalizePath(path)`.
- `pipeworks_html(model, file)` stays static (no `live` flag).
- Internal `pw_app(state) -> list(call = function(req) ...)` so tests call the handler directly with fake `req` environments. Routes (all API routes require the token header; return JSON):
  - `GET /` → editor HTML with model embedded and `live: {version, mode, base, can_record, blockers}` added to the model JSON.
  - `GET /api/version` → `{version}` (integer bumped on any detected change).
  - `GET /api/model` → full model (last good) + `live` + `model_error` (chr or null).
  - `POST /api/verdict` body `{item, verdict, comment}` → `record_verdict()` result `{ok, committed, commit, error, entry}`; 409 with `{error}` when refused.
  - `POST /api/retry` → `retry_uncommitted()` result.
  - `POST /api/open` body `{item}` → `rstudioapi::navigateToFile(file, line)` if available else `utils::file.edit(file)`; `{ok}`.
- `can_record` FALSE with `blockers` (uncommitted code files, or the `git_busy()` reason) when `record_verdict()` would refuse for repo-level reasons.
- Watcher: `later::later()` loop every 2 s while the server lives: fingerprint (mtime+size) of `R/**`, `_targets.R`, factory sources, `qa/**`, `.git/HEAD` and the current ref file. QA-only change → recompute QA in-session, bump version. Code change → also start `callr::r_bg(read_pipeline, …)` (one at a time; restart if a newer change arrives); on completion replace the model or set `model_error` keeping the last good model; bump version.
- Mode `auto` per Global Constraints.

- [ ] **Step 1: Failing tests** (handler-level, no real HTTP): token missing → 403; wrong Host → 403; POST with `Origin: http://evil.example` → 403; GET / with token → 200 HTML containing `"live"`; POST verdict on the example scenario as the senior → `committed: true` and a new commit; dirty tree → `can_record: false` with the file listed and POST verdict → 409; QA-only change bumps version; a broken `_targets.R` keeps the last model and sets `model_error` (drive the watcher tick function directly and wait for the bg process); `mode = "auto"` gives `review` for the senior on the dev branch and `build` for the analyst; `pipeworks()` twice → same URL; `pipeworks_stop()` → TRUE then FALSE. One real-HTTP smoke test: start server, fetch `/api/version` with `curl::curl_fetch_memory` if curl is installed (skip otherwise), servicing with `httpuv::service()` in a loop.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** focused + full → PASS; `devtools::check()` clean.
- [ ] **Step 5: Commit** `feat: live server for pipeworks()`

---

### Task 5: Editor: live review, modes, sidebar, theme

**Files:** Modify `inst/app/index.html`, `tools/smoke.js`, `tools/build-demo.R`.

**Interfaces:** Consumes the routes and `live` object from Task 4.
- Live detection: `RAW.live` present → live client: read the token from `location.search`, then `history.replaceState` to drop it; every fetch sends `X-Pipeworks-Token`. Poll `/api/version` every 2 s; on change fetch `/api/model` and re-render keeping selection, fold state, mode, viewport. Server unreachable → banner "Connection to R lost: run pipeworks() again".
- Verdict panel (Review mode only), following the approved review-view sketch: in the modal's Review section and as a compact action on the selected node's toolbar — Correct / Questionable / Wrong buttons, comment field required for the latter two, self-review warning line, disabled with "Commit your changes first" + blocker list when `live.can_record` is false; after POST show the result ("committed abc1234" or "saved, not committed: <error>" with a Retry button → `/api/retry`). Static page: buttons replaced by the copyable `qa_review()` call (today's behaviour).
- "Open in RStudio": live → POST `/api/open`; static → today's toast.
- Modes: top-bar switch Review/Build; initial value from `live.mode` (static: Review if `qa_summary` has open items, else Build). Review hides/disables: add target/block buttons, double-click-to-add, port dragging, plug/unplug, remove, the modal's wiring/command/format/pattern/name fields and Apply. Build hides verdict buttons.
- Sidebar toggle button in the top bar (aria-expanded), canvas refits; theme control cycling System → Light → Dark setting/removing `data-theme` on `document.documentElement`; both remembered in localStorage (try/catch).
- `model_error` banner when set.

- [ ] **Step 1:** Extend `tools/smoke.js` first (fails): a fake `fetch` serving `/api/version`, `/api/model`, `/api/verdict` from a fixture model with `live`; checks: token stripped from URL and sent as header; Review mode hides add/remove/ports and shows verdict buttons; Build mode the reverse; questionable without comment is not sent; a verdict POST shows "committed"; `can_record: false` disables buttons and lists blockers; version bump triggers re-render keeping the selected node; unreachable server shows the banner; sidebar toggle hides the sidebar; theme cycles `data-theme` none → light → dark → none; static page shows the copyable call and no buttons. Run → FAIL.
- [ ] **Step 2: Implement**; `Rscript tools/build-demo.R`.
- [ ] **Step 3: Verify** `NODE_PATH=<scratchpad>/node_modules node tools/smoke.js mockup/pipeline-editor.html` → all checks passed; full R suite + check clean.
- [ ] **Step 4: Commit** `feat(editor): live verdicts, review/build modes, sidebar toggle, theme switch`

---

### Task 6: Documentation and hand-over check

**Files:** Modify `README.md` (live review section, `qa_walk()`, modes, `pipeworks_stop()`, verdict commits), `CLAUDE.md` (server, verdict path, modes), `NEWS.md` (create: changes since the QA MVP incl. one-time renumbering of unnamed objects).

- [ ] **Step 1:** Write the docs. **Step 2:** `roxygen2::roxygenise()`; `devtools::check()` → 0/0/0; full suite pristine. **Step 3:** Manual end-to-end in a temp copy: `example_project(git = TRUE)` → `pipeworks(p, viewer = FALSE)` starts and `/api/version` answers (curl), a verdict via the API commits, `pipeworks_stop(p)` stops it; record the commands and outputs in the report.
- [ ] **Step 4: Commit** `docs: live review and qa_walk()`
