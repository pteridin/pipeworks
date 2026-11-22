# pipeworks: write-back from Build mode (design)

Status: approved for planning · 2026-11-22
Builds on: live server (2026-11-21 live review design), static source model
(`R/source_model.R`), Build-mode edits in `inst/app/index.html`.

## Intent

Build mode is for building the pipeline. Today every Build edit (roxygen,
arguments, body, wiring, new/removed/renamed targets, `format`, `pattern`)
stays in the page; the files never change. The editor should write them back,
so building on the canvas and editing in RStudio are two views of the same
project.

**The files are the only truth.** The page never keeps a version of its own
for longer than one write. Both directions (page → files, files → page) work
in **chunks**: the smallest piece of source that changed. Whole files are
never rewritten.

## Goals

- Every Build action on the live page is written to the files at once, as a
  chunk-level splice.
- Edits made in RStudio show up on the canvas (this exists: the `later`
  watcher), also while the page is in Build mode, without losing positions,
  selection, folded maps or an open dialog.
- A write never overwrites something the page has not seen: each chunk is
  checked against the text the page based its edit on.
- Formatting, comments and unknown constructs outside the touched chunk stay
  byte-identical. Inside a touched chunk, everything pipeworks does not model
  (unknown roxygen tags, extra `tar_target()` arguments, comments in a body)
  is kept too.
- Undo on the page undoes the write.
- The R writer is usable on its own, as the foundation for the scaffold API's
  `sc_write()`.

## Non-goals

- No commits. Code changes are the user's to commit (verdicts stay as they
  are: one commit each).
- No batch "review the diff, then write" step. (Rejected: keeps a second
  version in the page and needs merge logic.)
- No editing of expression-target commands, `tar_map()` `values`, factory
  arguments, or moving functions between files (all read-only in the dialog
  today; they stay that way).
- No writes from the static page (`pipeworks_html()`, the published demo):
  it keeps today's in-memory behaviour and wording.
- No compiled code. `utils::getParseData()` gives every token with line,
  column and comments; that is enough to locate chunks. (`{treesitter.r}` is
  the fallback if a concrete syntax tree is ever needed.)

## Anti-goals (a failure even if it "works")

- A write that loses user text: an RStudio edit, an unknown roxygen tag
  (`@export`, `@examples`, `@importFrom`, `@details`, …), a comment.
- Locating code with regular expressions over raw text instead of parse
  tokens (the page's `srcLoc()` regex is fine for display, not for writing).
- Reformatting code that was not touched.
- A half-applied multi-chunk change (e.g. a new argument without its
  `@param`, or a call site renamed in one file but not another).

## Constraints

- Static only: the writer parses files, never runs pipeline code (same rule
  as the QA engine).
- Files are read and written as UTF-8; line endings (LF/CRLF) and the
  presence of a trailing newline are preserved per file.
- R is single-threaded: API handlers, the watcher and background rebuilds
  run on the same thread; handlers must stay short.
- The full model rebuild (`tar_manifest()` in a separate process) takes
  ~1–2 s, so the page cannot wait for it before showing an edit.
- Keep the example's edge cases intact (`inst/examples/survey/README.md`);
  tests copy the example (`local_project()`, `local_example_repo()`).
- `inst/app/index.html` stays an HTML fragment.

## Approaches considered

1. **Change list, R splices chunks (picked).** The page sends one small,
   semantic change per action; R locates the chunk in the current file via
   parse data, checks it against the page's base, generates the new text and
   splices it in. Preserves everything outside the chunk; the same change
   vocabulary drives `sc_write()`. Cost: one splice routine per change kind,
   plus a token-level search for renames.
2. **Page regenerates whole files.** Cheap (the page already has preview
   generators), but rewrites formatting and drops whatever the editor does
   not model. Rejected.
3. **R rebuilds from a model and deparses.** Same loss of formatting via
   `deparse()`. Rejected.

Within 1, two sync models were weighed: **write-through** (every action writes
at once; picked) versus keeping edits in the page and rebasing them onto each
new model (allows a diff-then-write step, but needs merge logic and drops
edits on clashes).

## Design

### Data flow

```
page action ──POST api/edit {changes, base}──▶ R: save RStudio buffers
                                               locate chunks (parse data)
                                               check base per chunk
                                               build all new texts in memory
                                               write files (all or none)
                                               bump version, rebuild model
page ◀── {ok, write_id, version} ─────────────┘
page ◀── new model (poll, as today) ── applied as a patch, view state kept
```

### Change vocabulary (page → R)

Each change names the item it touches by its QA item id (`function:<name>`,
`target:<name>`; a map variant names its template) and carries the item's
**base**: an MD5 of the item's raw source text as the page last saw it
(lines `line1..line2` verbatim, for a function including its roxygen block).
The model gains this `base` per function and target (R computes it while
reading; it is not the QA hash, which ignores comments).

| Change | Fields | Writes |
|---|---|---|
| `set_doc` | `fn`, `field` (`title`, `description`, `returns`, `family`, `param`), `param` (for `param`), `value` | one field of the roxygen block; other lines and unknown tags untouched. Adds the block (above the function) or the tag line if missing. |
| `set_formals` | `fn`, `formals` (`[{name, default}]`) | the formals list between `function(` and `)`. |
| `set_body` | `fn`, `body` | the text between the body's braces. |
| `rename_function` | `fn`, `to` | the assignment name, every unqualified `SYMBOL_FUNCTION_CALL` of `fn` in `R/` and `_targets.R`, and target commands. |
| `set_target_arg` | `target`, `arg` (`format`, `pattern`, `description`), `value` (`null` = remove) | that argument inside the `tar_target()` call: replaced in place, appended before the closing paren, or removed with its comma. |
| `set_call` | `target`, `args` (`[{name, value, named}]`) | the command's call arguments (plug/unplug); the function name of the call stays. |
| `rename_target` | `target`, `to` | the name argument of its call and every reference in other targets' commands. |
| `add_target` | `target`, `block` (file), `fn` (name, roxygen fields, formals, body), `call` | the function (appended to the block file) and the `tar_target()` call (appended to `pipeline_<block> <- list(...)`). New file: creates `R/<block>.R` with both and adds `pipeline_<block>` to the composition list in `_targets.R`. |
| `remove_target` | `target` | its call, with the separating comma. The function stays. |

One page action sends all its changes in **one request**; they are applied
all-or-none. Examples:

- Dialog **Apply** → the diff between the dialog's start state and its end
  state, as the changes above (only fields that differ).
- **Plug** `a` into `t` → `set_call(t)`, plus `set_formals(fn)` and
  `set_doc(fn, param a)` when a formal is added.
- **Unplug** → `set_call`, plus `set_formals`/`set_doc(param, null)` when the
  formal is dropped (same rules as today's `unplugFrom()`).
- **Add target** → `add_target`; **Remove** → `remove_target`.

### Writing (R)

New file `R/write_back.R`; the server route lives in `R/server_api.R`.

1. **Save RStudio buffers** first: `rstudioapi::documentSaveAll()` when
   RStudio is available (behind the existing `rstudio_available()` seam).
   RStudio reloads unmodified buffers when files change on disk.
2. **Locate** each item in the current file with `parse_source_file()`-style
   parse data (reuse, don't duplicate). Sub-chunks (roxygen field, formals,
   body, one call argument) are located by tokens within the item.
3. **Check base**: the item's current raw text must hash to the change's
   `base`. Mismatch, item missing, or file not parseable → refuse the whole
   request with `409` and a message naming the file and item; the page
   reloads the model. The check is per item, so an RStudio edit elsewhere in
   the same file does not block the write.
4. **Build** every touched file's new text in memory; re-parse each result.
   A result that does not parse is refused (bug guard, never written).
5. **Write** each file via a temp file in the same directory + rename. If a
   later file fails, restore the ones already written. Preserve encoding,
   line endings and trailing newline.
6. **Record** the write for undo (session-only, in the server state):
   `write_id` → per file the chunks before and after.
7. **Bump** the state's version and start the background rebuild at once
   (kill a running one); don't wait for the watcher tick.

Generated text follows the page's current conventions (`roxygenFor()`,
`signatureFor()`, `tarCall()`): roxygen wrapped at 76 columns with `#' `,
two-space indent, `tar_target(name, fn(args))` on one line when it fits in 76
columns, otherwise one argument per line. Those generators move to R; the
page's "What would be written" preview may keep a JS copy for instant
display.

**Roxygen field splicing**: split the block into the title paragraph, the
description paragraph(s) and tag sections (a tag runs until the next line
starting with `@`). `@title`/`@description` tags count as those fields.
Replace only the section of the changed field; keep every other line
verbatim, including unknown tags and their order. New tags go in this order:
`@param` (formal order) → `@return` → `@family`, before any unknown tags.

### Undo

Page undo sends `POST api/undo {write_id}`. R restores each chunk's before
text only if the chunk still reads as its after text; otherwise `409` and the
page tells the user which item changed since. The undo record is dropped
after use. Undo history ends when the server stops.

### Files → page

- Unchanged: the watcher and background rebuild produce a new model version;
  the page polls.
- Changed: the page **always** takes the new model in Build mode too (there
  are no long-lived page edits any more), via `applyModel()` which already
  keeps positions, selection, folded maps and the open dialog. `PENDING`,
  `viewDiffers()`, the discard prompt and the Build→Review confirmation lose
  their reason and are removed.
- **Open dialog** (builder's-check call, not discussed): if the dialog's item changed on disk, fields the user has
  not touched take the new values; touched fields keep the user's text, and
  the dialog shows a notice ("changed in RStudio since you opened it").
  Apply then sends the touched fields with the new base. (Field-level merge;
  the dialog's start state is re-based on the new model.)

### Page during a write

- The action shows its result at once (optimistic) and marks the touched
  boxes "writing…".
- On `ok`, the page waits for the model whose version ≥ the returned
  version, then applies it (which clears the marks).
- On refusal, the page re-applies the last model, shows the message as a
  toast, and keeps the dialog open with the user's text if the action came
  from a dialog.
- One write at a time: further actions wait for the current request to
  return (queue of one action; the canvas stays usable for viewing).
- Toasts: "Written to R/import.R." instead of today's "Applied in this view.
  Your files are unchanged."; the "Writing to files comes with the live
  connection" hint goes away on the live page.

### Edge rules

- **Shared function** (`score_histogram()` behind two targets): doc, formals
  and body changes apply once to the function; new formals get `= NULL` when
  other targets share it (as today).
- **Map templates**: changes to a variant are sent for its template. Renaming
  a template is refused when any variant name is referenced by name in
  another target's command (e.g. `model_fit_full`); otherwise allowed. A
  template held in a symbol (`tmpl_region_import <- tar_target(area_data, …)`)
  keeps its holder symbol; only the target name changes.
- **Factory targets** (`tar_render()`): only `remove_target` and `format`/
  `pattern` where the call has them; inputs come from the report, as today.
- **Rename target** used by `tar_read()`/`tar_load()` in a report source:
  refused with a message ("rename it in <file> too, then here") — report
  sources are not edited in this round.
- **Rename function** also reached from report sources or by string
  (`do.call("fn")`): not followed; the toast says how many call sites were
  renamed so the user can check.
- **Remove target**: after the write, a hint says whether its function is now
  unused (no target, no caller).
- **New target in a file without a block list** (e.g. `R/utils.R`): creates
  `pipeline_<file> <- list(...)` at the end of the file and adds it to
  `_targets.R`. If the composition list in `_targets.R` cannot be found
  statically (no top-level `list(...)` holding `pipeline_*` symbols), the
  write is refused with a message.
- **New function body** left empty: written as
  `stop("Not implemented: <fn>()")` (same placeholder as the scaffold design).
- **Detached HEAD, rebase, dirty tree**: irrelevant for code writes (only
  verdicts commit).

### Effect on QA

Writes change item hashes like any edit: body, formals, call and rename
changes make reviewed items `changed`; roxygen-only changes do not (comments
are not hashed). A renamed function or target is a new item (`unreviewed`).
Nothing special to build.

### API

`R/server_api.R` route contract gains:

```
POST /api/edit   {changes: [...]}        -> {ok, write_id, version, files}
POST /api/undo   {write_id}              -> {ok, version, files}
```

Same host/origin/token checks. `409` for a stale base or failed undo (body:
`{error, item, file}`), `400` for malformed changes. (The Build/Review mode
lives in the page; the server does not gate edits by mode.)

## Testing

- **R unit tests** (`tests/testthat/test-write_back.R`), on copies of the
  example: one test per change kind, asserting the exact file text after the
  write and that lines outside the chunk are byte-identical. Cover the
  example's edge cases: renamed arguments (`read_survey(path)` called with
  `raw_file`), shared function, constant arguments, `format = "file"`,
  `pattern = map(regions)`, map in a block and map across two files,
  `tar_render()`, `R/utils.R` without a block list, missing `@param`/
  `@return`/`@family`.
- Stale base → `409`, no file changed. Multi-file change with a failure in
  the second file → first file restored. CRLF file stays CRLF. Unknown roxygen
  tags survive a `set_doc`.
- Undo restores text; undo after an intervening edit → `409`.
- Round trip: write a change, `read_pipeline()` reflects it.
- **Server tests**: `pw_app(state)$call(req)` for `api/edit` and `api/undo`
  (token, origin, mode, `409`), never a real RStudio.
- **jsdom smoke** (`tools/smoke.js`): actions produce the expected change
  lists; refusal restores the model; dialog field-level merge.
- **Manual**: real browser and RStudio Viewer, edit in RStudio while a dialog
  is open, undo, add a target into a new file.

## Left to the builder

- Internal structure of `R/write_back.R` (one function per change kind is
  expected), how undo records are stored, and how much of
  `parse_source_file()` is factored out for reuse.
- How the page computes the change list from the dialog diff.
- Exact wording of toasts and refusal messages (plain, in the style of the
  existing ones).
- Whether the JS preview generators stay as a copy or the preview asks R
  (`dry_run`); a dry-run flag on `api/edit` is welcome but not required.
- Updating `CLAUDE.md` ("Edits of the pipeline in the editor stay in memory"),
  the editor's notice text, NEWS and the backlog.
