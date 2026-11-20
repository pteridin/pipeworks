# pipeworks: QA reviews, file blocks and static branches

Status: draft for approval · 2026-11-20

## Intent

pipeworks helps analysts at WIG2 build `{targets}` pipelines for health
economic research and, above all, makes the second-analyst code review
(QA) of those pipelines simple, incremental and reportable.

Today a review happens in a GitLab merge request (MR) on large diffs that
nobody fully understands anymore. pipeworks turns it into an agile review:
function by function, where anything already reviewed and unchanged stays
done, and the result can be handed to a client (e.g. a pharmaceutical
company) as a PDF confirming that a second WIG2 analyst reviewed the code.

Users:

- **Analyst** (author): develops the pipeline locally in RStudio with the
  data available, on a branch such as `dev/sample-definition`.
- **Reviewer** (second analyst, often more senior): reviews the MR, may
  change code too.
- **Client**: reads the QA report.

The FDZ Gesundheit is an example of the restrictive environments the
pipelines may later run in. pipeworks itself is a local development tool
and never runs there.

## Goals

1. Show what needs review: every reviewable item carries a hash of its
   code; a verdict stays valid as long as that hash is unchanged.
2. Record verdicts (correct / questionable / wrong, with comment) in the
   repository, so they travel with git branches and merges.
3. Enforce the four-eyes principle: the last author of an item's code cannot
   approve it. This works in both directions (a reviewer who rewrites code
   hands that item back to the analyst).
4. A CI gate (`qa_check()`) for GitLab: fails while items are unreviewed,
   changed since review, wrong, or self-reviewed.
5. A PDF report (`qa_report()`) via Quarto + Typst for the current state or
   any earlier commit.
6. Model pipelines the way WIG2 writes them: one file per block, static
   branches (`tar_map()`) and dynamic branches visible as such.

## Non-goals (for now)

- Talking to the GitLab API, discussion threads, change proposals inside
  pipeworks. Discussion stays in the GitLab MR (decided: approach A).
- Editing function bodies in the editor. Code is written in RStudio.
- R environment / package table in the report (later "topping").
- Cryptographic signatures.

## Anti-goals (would make it a failure even if it technically works)

- A verdict that silently survives a code change.
- Someone approving their own code without the check noticing.
- Reviews that depend on having run `tar_make()`.
- Heavy dependencies or anything that needs a network connection.
- A second workflow next to GitLab that people must keep in sync by hand.

## Workflow (decided)

`main` → feature branch `dev/<topic>` → GitLab MR. The reviewer checks out
the branch, opens pipeworks, records verdicts (stored as files in `qa/`,
committed and pushed to the branch). Discussion happens in MR threads;
small fixes via GitLab suggestions, larger rewrites as commits by the
reviewer. A CI job runs `qa_check()` and builds the report. Merge when the
pipeline passes.

## Concepts

### Block

A block is a file in `R/` that contains functions and, at its end, the
block's targets as a list:

```r
# R/sample_definition.R
get_cs1 <- function(raw_claims) { ... }

pipeline_sample_definition <- list(
  tar_target(cs_1, get_cs1(raw_claims))
)
```

`_targets.R` composes blocks: `list(pipeline_import, pipeline_sample_definition)`.
Targets defined directly in `_targets.R` belong to a pseudo-block
`_targets.R`. A block is drawn as a box on the canvas. **`@family` is no
longer used for grouping** (decided); it stays ordinary roxygen.

### Reviewable item

| Kind | Example | Hash covers |
|---|---|---|
| `function` | `clean_cs()` | the function's code: deparsed without source references, so comments, roxygen and formatting do not count |
| `target` | `raw_file` (expression target) | its command |
| `map` | the `values` of one `tar_map()` | the deparsed `values` and `names` arguments |
| `file` | `report.Rmd` (factory source) | file contents |

Item ids are `<kind>:<name>`, e.g. `function:clean_cs`. For `map`, the name
is derived from the template target names (builder's call, must be stable
while the map's templates are unchanged). Targets that call a project
function are covered by reviewing that function plus the `map`, if mapped;
they are not separate items. A function used by several targets is one
item.

Hashes are computed by pipeworks from source, never from the targets store.
MD5 via `tools::md5sum()` on the normalized text (no new dependency).

### Review entry

One JSON file per verdict in `qa/reviews/`, never edited after writing
(one file per entry so that branches never conflict when merged):

```json
{
  "item": "function:clean_cs",
  "hash": "3f2a91c0…",
  "verdict": "questionable",
  "comment": "Bands follow the 2019 guideline; client to confirm.",
  "reviewer": "S. Senior",
  "date": "2026-11-20T10:31:00Z",
  "commit": "a1b2c3d…",
  "depends": { "function:rescale01": "54c811…" }
}
```

- `reviewer` comes from `git config user.name` (decided).
- `commit` is HEAD when the verdict was recorded.
- `depends` holds the hashes of project functions the item calls, so a
  change in a callee can be detected.
- A comment is required for `questionable` and `wrong`.

### Item status (derived, never stored)

For each current item, take the latest entry for that item:

| Status | Meaning |
|---|---|
| `unreviewed` | no entry |
| `changed` | latest entry's hash differs from the current hash |
| `check_again` | hash matches, but a hash in `depends` differs (a callee changed). A hint, not a reset |
| `correct` / `questionable` / `wrong` | hash matches, verdict as recorded |
| `self_reviewed` | flag on top of the above: the reviewer is the last git author of the item's current code |

Last author: `git blame` over the item's line range (function definition,
target call, `tar_map()` call, or file); the author of the most recent
commit touching those lines. Verdicts can only be recorded for committed
code: if the item's lines are uncommitted, `qa_review()` refuses with a
message to commit first.

### Static and dynamic branches (decided, editor part)

- A mapped target is drawn as stacked cards with a pill in its map's color,
  e.g. `this ×3`. One color per `tar_map()`.
- Clicking the pill unfolds all targets of that map (across all files) into
  their variants (`cs_this_a`, `_b`, `_c`); a "collapse" pill folds them back.
- A map can span several files (a `tar_map()` in `_targets.R` wrapping
  templates from several blocks). Files stay boxes; the map is a property
  of its targets (option B from the sketches).
- Dynamic branches (`pattern = map()`) get a marker `×?` before a run,
  `×n` after.
- Later build actions: a new target after a mapped one is either *into the
  map* or a *combination* via `tar_combine(..., command = f(list(!!!.x)))`.

## R interface

```r
qa_status(path = ".", base = NULL)
qa_review(item, verdict = c("correct", "questionable", "wrong"), comment = NULL, path = ".")
qa_check(path = ".", allow_questionable = TRUE)
qa_report(path = ".", ref = NULL, output = "qa-report.pdf", signatures = FALSE)
```

- `qa_status()` returns one row per item: id, kind, name, block/file, line
  range, current hash, status, verdict, reviewer, date, comment, last
  author, `changed_vs_base`. With `base = "main"`, `changed_vs_base` marks
  items whose hash differs from the base ref (computed by parsing the base
  version's files via `git show`, without running anything).
- `qa_review()` accepts a full id or an unambiguous name (`"clean_cs"`),
  validates, writes the entry, prints what it recorded. It does not commit.
- `qa_check()` passes only if every current item is `correct` (or
  `questionable` when allowed) and none is `self_reviewed`. Prints a short
  summary per failing item; returns invisibly the status table; signals an
  error on failure so that `Rscript -e "pipeworks::qa_check()"` exits non-zero
  in CI. `check_again` items do not fail the check (they are hints) but are
  listed.
- `qa_report()` renders `inst/report/qa-report.qmd` (Quarto, Typst format)
  to PDF. With `ref`, it reports on that commit: the repository is checked
  out into a temporary git worktree at `ref` and everything is read from
  there. Errors clearly if Quarto is missing.

## Report content (decided)

Cover page: organisation line, project name, code version (branch/ref,
short commit, date), analyst(s) (git authors of the reviewed code),
reviewer(s) (from review entries), creation date, summary tiles (items,
correct, questionable, wrong/open), statement that every item was reviewed
by a second analyst who did not write it and that each verdict refers to
the exact code by hash, a block-level pipeline diagram.

- `signatures = TRUE`: signature lines for analyst and reviewer.
- `signatures = FALSE`: the sentence "This report was generated digitally
  and is valid without signature." (decided).

Findings by block: per item its one-line roxygen title (or target
description), verdict, reviewer and date, short hash; comments under
questionable/wrong items. Open items listed explicitly if any.

Review history: per merge (taken from git merge commits on the reported
ref's history touching `qa/reviews/`): MR branch name, number of items,
number of review rounds (distinct review dates per item), merge date. Exact
derivation is the builder's call; it must work from git alone.

R environment table: not in this version.

## Editor changes in this phase

- Boxes are blocks (files), not families.
- Map pills with fold/unfold, colors per map; dynamic branch marker.
- Read-only QA overlay: each box shows its status (styles as in the review
  sketch: orange frame = needs review, dashed = check again, red = wrong,
  greyed = reviewed and unchanged), a top bar with progress, and for a
  selected function its diff against base and its verdict history. Verdicts
  are recorded with `qa_review()` in this phase; the modal shows the exact
  call to copy.
- Fonts are no longer loaded from Google (offline environments).

## Example project and test pipeline

Restructure `inst/examples/survey/` to the block convention (one
`pipeline_*` per file, composed in `_targets.R`), and add a `tar_map()`
that spans two blocks and one that sits inside a single block, keeping the
existing edge cases. Add `example_project(git = TRUE)` that creates a git
repository with a `main` branch (partly reviewed, review entries
committed) and a `dev/` branch with a few changes, so a reviewer can
immediately try a realistic QA round: `qa_status(base = "main")`,
`qa_review()`, `qa_check()`, `qa_report()`.

## Constraints

- Imports stay minimal: jsonlite, roxygen2, targets, withr (+ base `tools`,
  `utils`). Git is called via `system2("git", ...)`; Quarto via
  `system2("quarto", ...)`. Both are required only for the features that
  need them, with clear errors otherwise.
- Never execute pipeline code to compute hashes or review status.
  (`read_pipeline()` already runs `_targets.R` in a separate process the way
  `tar_manifest()` does; that stays the only exception.)
- Everything in `qa/` is plain text, diffable and human-readable.

## Approaches considered

Build order (decided: A):

- **A. QA first** (chosen): model v2 → QA engine in R → report, with a
  throwaway spike of the live connection in parallel; then live connection
  and editor actions. Delivers the CI gate and the client PDF earliest.
- B. Interface first: early clickable verdicts, but no client value until
  the end and the riskiest part first.
- C. Thin end-to-end slice: integration tested early, but nothing complete
  for weeks and every part touched twice.

GitLab integration (decided: A): git carries the review entries, GitLab
holds the discussion, pipeworks is map, log and gate. Rejected: talking to
the GitLab API (tokens, network, vendor lock-in); everything inside
pipeworks (duplicates GitLab).

Map visualisation (decided: B): map as a property with colored pills.
Rejected: file columns with map bands (breaks with many files, nested
maps); map as outer frame (files split into two boxes).

## Later phases (outline only)

- **Live connection**: an httpuv server inside the R session started by
  `pipeworks()`, keeping the console free; `rstudioapi::navigateToFile()`;
  refresh on file change; writing verdicts, roxygen and targets back to
  files (check file modification time first).
- **Review view with clickable verdicts** (as in the approved sketch) and
  **build actions**: add block, add target (function skeleton + roxygen +
  `tar_target()` at the end of the block list), connect (argument in
  signature, call and `@param`), into-map / combine.
- R environment table in the report.

## Decisions after the builder check

These refine and, where they conflict, override the sections above.

- **QA engine is purely static.** Items, hashes, blocks and status come
  from parsing source files only: nothing is loaded or run, so it works on a
  slim CI image and on any old commit. Targets are reviewed *as written*:
  a `tar_map()` template and its `values` code are items; expanded variants
  are not needed. Only the editor (`read_pipeline()`) uses `tar_manifest()`.
- **Item kinds** (replaces the table above): `function` (every top-level
  function in `R/`, including helpers no target uses), `target` (every
  `tar_target()` call as written: command, arguments incl. constants,
  `pattern`, `format`, `cue` and other settings), `map` (the `values` and
  `names` of a `tar_map()`), `object` (other top-level code in `R/` files
  and `_targets.R`: constants, lookup tables, `tar_option_set()`), `file`
  (factory sources such as `report.Rmd`). Data files are out of scope.
- **Hash** = MD5 of the item's parse tokens without comments and whitespace
  (from `getParseData()`), so formatting, comments, roxygen and R upgrades do
  not change it.
- **Last author** = author of the most recent commit in which the item's
  hash changed (found by walking the file's history and re-hashing), not
  whoever last touched the lines.
- **Robust to squash and rebase:** each review entry also stores
  `author` (name and email of that last author at review time) and the
  reviewer's email. `self_reviewed` compares the entry's reviewer with the
  entry's recorded author, so the check stays correct after any merge method.
- **Identity** is matched by git email. An optional `qa/people` file maps
  several emails to one person (e.g. GitLab web commits).
- **Report while the check fails:** renders with a clear "DRAFT – QA
  incomplete" marking and lists open items instead of the confirmation
  statement. `qa_report(final = TRUE)` refuses unless `qa_check()` passes.

## MVP scope (first implementation round)

Static source model and item hashing; review entries; `qa_review()`,
`qa_status()`, `qa_check()`; git helpers (last author by hash, identity,
uncommitted code refused); `qa_report()` with draft/final and signature
options; the example project restructured to blocks with two `tar_map()`s
and `example_project(git = TRUE)`; editor: blocks as boxes, map pills with
fold/unfold, read-only QA overlay with progress. The live connection,
clickable verdicts and build actions follow in the next round.

## Left to the builder

Internal structure of the R code, how `tar_map()` membership is recovered
(must be correct for a map inside one block and a map spanning blocks),
the stable naming of `map` items, how the block-level diagram is drawn,
the exact derivation of review rounds, test design.
