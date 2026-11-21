# pipeworks: live review connection and guided console review

Status: draft for approval · 2026-11-21
Builds on: `2026-11-20-qa-reviews-design.md` (QA engine, review entries, statuses).

## Intent

Today a reviewer sees the QA status in the editor but records each verdict by
typing `qa_review()` in the console. The user does not want to copy calls
over. This round lets the reviewer decide in the editor itself, and adds a
quick console walk-through for rounds without a browser.

## Goals

1. **Live connection.** `pipeworks()` starts a small web server inside the
   R session and opens the editor from it. The console stays free.
   - Verdict buttons (correct / questionable / wrong, comment required for the
     last two) record a review entry exactly like `qa_review()`.
   - **Every verdict is committed** right away (decided): one commit per
     verdict containing only that review file, message
     `qa: <verdict> <item id>` with the reviewer as author. Reviewers can
     squash later.
   - The view refreshes by itself when source files or review entries change
     (edits in RStudio, a `git pull`, a verdict).
   - "Open in RStudio" jumps to the item via `rstudioapi::navigateToFile()`.
2. **`qa_walk()`.** A console loop over the items that need a verdict: shows
   item, status, last author, the code and its diff against base, asks for a
   verdict (and a comment when required), records and commits it, moves on.
   Skip and quit are always possible.

## Non-goals (this round)

- Writing roxygen, targets or wiring back from the editor (next round; it
  builds on this connection).
- Multi-user access, remote access, authentication beyond a local token.
- GitLab API.

## Anti-goals

- A verdict recorded through the browser that `qa_review()` would refuse.
- A verdict commit that sweeps in the user's other staged or unstaged work.
- Any page or process other than the opened editor being able to record
  verdicts.
- Blocking the R console.

## Decisions

- **Server:** `httpuv::startServer()` in the R session (non-blocking; served
  while the console is idle). Not Shiny (blocks the console), not a separate
  process (cannot reach RStudio). httpuv moves to Imports; it is installed and
  is a Shiny dependency, so typically present.
- **Binding:** `127.0.0.1`, random free port, a random per-session token in
  the URL; every API request must carry the token (header or query), else 403.
- **One server per project path**; calling `pipeworks()` again for the same
  project reuses it and reopens the view. `pipeworks_stop(path = ".")` stops
  it; servers stop when the R session ends.
- **The browser never writes files.** API calls go to R, which runs the same
  code path as `qa_review()` (one shared internal function), then commits.
- **Commit:** `git commit --only -- <review file>` (or equivalent) so staged
  changes of other files stay staged and are not included; author =
  reviewer's git identity; message `qa: <verdict> <item id>`. If the commit
  fails (e.g. hooks), the entry file stays, the error is shown, and the item
  shows "verdict not committed".
- **Refresh:** R checks, via `later`, every ~2 s while a server runs, whether
  any project source file or `qa/` changed (mtimes/sizes); the page polls a
  cheap `/api/version` and reloads the model when it changed. No websockets
  needed.
- **Static mode stays:** `pipeworks_html()` and the published demo keep
  working without a server; there the verdict buttons are replaced by the
  copyable `qa_review()` call, as today.
- **`qa_walk(path = ".", base = NULL, include = c("open", "check_again"))`:**
  order by block, then item; uses `utils::menu()`-style prompts via
  `readline()` so it works in RStudio and plain R; non-interactive sessions
  error clearly. Commits each verdict like the editor.

## Approaches considered

- **In-session httpuv server (chosen):** console free, direct access to
  rstudioapi, git and the package's own functions.
- Shiny app: blocks the console during review. Rejected.
- Separate R process (callr/plumber): no access to rstudioapi in the user's
  session; duplicated state. Rejected.
- Polling vs websockets for refresh: polling a version endpoint is simpler,
  robust behind RStudio's viewer proxy, and enough at a 2 s cadence.

## Constraints

- Works in the RStudio Viewer (`rstudioapi::viewer()` with a localhost URL)
  and in a normal browser (`viewer = FALSE`).
- Everything from the QA design stays true: static engine, entry format,
  status rules, four-eyes, fail-closed identity.
- Windows: no POSIX-only paths or shell features.

## Decisions after the builder check (controller calls)

These refine and, where they conflict, override the sections above.

1. **Dirty working tree:** `qa_review()` semantics stay unchanged (the whole
   code tree must be committed). The API tells the page per project whether
   verdicts can be recorded; when not, the verdict buttons are disabled with
   "Commit your changes first" and the list of uncommitted files. `qa_walk()`
   refuses up front with the same message.
2. **Verdict commit mechanics:** write the entry, `git add -- <entry>`, then
   `git commit --only -m "qa: <verdict> <item id>" -- <entry>` with the
   configured identity (no custom `--author`; the identity is the reviewer).
   Hooks run (no `--no-verify`). During a merge, rebase, cherry-pick or with
   an `index.lock`, refuse before writing anything. If the commit fails after
   writing, the entry stays on disk, counts in the status (it is on disk), and
   the item shows "verdict not committed" with a retry action that commits
   all uncommitted files under `qa/reviews/` the same way.
3. **Refresh without blocking:** two layers.
   - QA status is static and cheap: recomputed in-session whenever `R/`,
     `_targets.R`, factory sources or `qa/` change.
   - The structural model (`read_pipeline()`, which runs `_targets.R`) is
     rebuilt in a background process with `callr::r_bg()` (callr is already a
     dependency of targets) only when `R/` or `_targets.R` change, polled by
     `later`. Until it finishes the page keeps the last good model; on failure
     it keeps the last good model and shows a banner with the error.
   - The watcher also looks at `.git/HEAD` and the current ref, so checkouts
     and pulls trigger a refresh.
4. **Security:** bind 127.0.0.1; check `Host` is `127.0.0.1:<port>` or
   `localhost:<port>`; reject state-changing requests whose `Origin` is not
   the server's own; require the token in an `X-Pipeworks-Token` header for
   every API call. The token is passed once in the URL to load the page, then
   removed from the address bar with `history.replaceState`.
5. **"Open" items:** an item is open when it does not pass `qa_check()`
   (`qa_passing()` is FALSE). `qa_walk(include = c("open", "check_again"))`
   walks open items and optionally `check_again` hints. Items the current
   reviewer last changed are shown with a clear warning ("you last changed
   this; your verdict will be flagged as self-review") and are not refused,
   consistent with `qa_review()`.
6. **Lifecycle:** servers are keyed by the normalised absolute project path;
   reopening reuses the server and its token, so open tabs keep working.
   When the server is gone, the page shows "Connection to R lost: run
   pipeworks() again". `pipeworks_stop(path = ".")` is exported, documented
   and tested.
7. **Dependencies:** `httpuv` and `later` in Imports (callr already comes
   with targets; add it to Imports explicitly since it's used directly);
   `rstudioapi` stays in Suggests and "Open in RStudio" falls back to
   `utils::file.edit()` outside RStudio.

## Additions requested by the user (2026-11-21)

8. **Review and Build modes.** Reviewing and editing are separate.
   - *Review*: structure read-only. All editing actions (add target, add
     block, plug/unplug, remove, drag-to-connect, double-click to add, the
     wiring/code/format/pattern fields of the modal, Apply) are hidden or
     disabled. Shown: QA overlay, diff against base, verdict buttons, "Open in
     RStudio". Code changes happen in RStudio and are picked up by the refresh.
   - *Build*: editing actions available (they still only change the view in
     this round; writing back comes next round). Verdict buttons hidden.
   - A mode switch in the top bar. `pipeworks(path, mode = c("auto",
     "review", "build"))`: `auto` decides by role, on any branch: Review when
     there are open items whose last author is someone other than the current
     git user (person_of() on emails), else Build (the author working on their
     own `dev/` branch, or nothing open). The mode switch can always override,
     e.g. an author previewing what the reviewer will see before opening the
     merge request. The static page
     (`pipeworks_html()`, demo) supports both modes too.
9. **Collapsible sidebar.** A button in the top bar hides and shows the left
   bar; the canvas takes the full width and refits. Remembered per browser
   (localStorage, wrapped in try/catch).
10. **Theme switch.** A top-bar control cycling System → Light → Dark, setting
    `data-theme` on the root element (all colours are already tokens with
    light and dark values). Default System; remembered per browser.
11. **Carried gap from the QA round (ruling R25):** loader detection also
    flags `source`/`sys.source` used as values (e.g. `lapply(files, source)`,
    `purrr::walk(files, source)`), `do.call("source", …)` and
    `eval(parse(file = …))`, so code loaded that way fails the gate.

## Left to the builder

API shape and routes, how the page discovers it runs live (e.g. a flag in the
embedded model), the UI of the verdict panel (follow the approved review-view
sketch), the exact prompts of `qa_walk()`, test design (httpuv can be
exercised with `httr`-free base R `url()`/`curl` if available, or by calling
the request handler directly).
