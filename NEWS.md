# pipeworks 0.0.0.9000

Changes since the QA MVP.

## New

* `pipeworks()` now starts a live server in your R session. The editor stays
  connected: it refreshes when code, `qa/` or the git branch change, records
  verdicts, and opens items in RStudio ("Open in RStudio").
* Review mode has Correct / Questionable / Wrong buttons. Build mode edits the
  view. The mode is chosen by role (open items last changed by someone else:
  Review) and can be switched in the top bar or with `pipeworks(mode = )`.
* The sidebar collapses and the editor has a light/dark theme switch.
* `pipeworks_stop()` stops the server of a project.
* Works on RStudio Server and Posit Workbench through the proxy. Set
  `options(pipeworks.allowed_origins = "https://<your-rstudio-host>")` if a
  403 names a host or origin.
* `qa_walk()` goes through open items in the console (interactive sessions only).
* Verdicts are refused on a detached HEAD, and the editor keeps a banner with a
  Retry button for verdict files that are saved but not committed.
* `pipeworks()` returns the address invisibly (it returned the model before).

## Changed

* Every verdict is committed automatically, one commit per verdict
  (`qa: <verdict> <item>`) containing only its entry file. `qa_review()` has
  `commit = TRUE`; use `commit = FALSE` for the old behaviour. It needs a git
  identity and refuses during a merge, rebase, cherry-pick or revert.
* Stricter loader detection: code loaded indirectly, for example
  `lapply(files, source)`, now fails `qa_check()` until it lives in `R/`.
* One-time renumbering of unnamed top-level objects: ids such as
  `object:_targets.R:list#2` may shift once. A verdict given under an old id
  becomes an orphan and the item needs a new verdict.
