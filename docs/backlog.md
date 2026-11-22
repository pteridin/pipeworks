# pipeworks backlog

Collected from the reviews of the QA MVP round (2026-11-20) and the live
review round (2026-11-21). Items fixed in later waves are left out.

## Manual testing (planned for 2026-11-22)

- [ ] Editor in a real browser and in the RStudio Viewer: top bar wrapping
      (mode switch, sidebar and theme buttons), banner row, verdict buttons
      and comment field, confirmation panel (Build → Review), node toolbar
      ✓ ? ✗, canvas refit after hiding the sidebar, dark mode contrast,
      stacked map cards and pills.
- [ ] Live review end to end on the example: `pipeworks(p)` → verdict →
      commit appears in `git log` → view updates; edit a function in
      RStudio → view refreshes; break a file → error notice, last state kept.
- [ ] `qa_walk()` on the example: readability of hunks and callee diffs.
- [ ] RStudio Server / Workbench (if used): verdicts work through the proxy;
      on a 403, set `options(pipeworks.allowed_origins = "https://<host>")`
      as the message says, and report the host/origin seen.
- [ ] Windows (if analysts use it): `example_project(git = TRUE)`,
      `qa_review()`, `pipeworks()`, `qa_report()`.

## Decisions waiting for the user

- Scaffold API: the five decisions in
  `docs/superpowers/specs/2026-11-21-scaffold-api-review.md`
  (map identity as a named object; spec vs. pipe as the main interface;
  function naming; placeholders and four-eyes for scaffolded entries;
  drift policy and where protocol references go).

## Next features

- Write-back follow-ups: renaming a target that report sources read
  (`tar_read()`/`tar_load()`) is refused today; editing expression
  commands; scope-aware renames (shadowed local functions or formals);
  undo matching that requires context, not only the identical text.
- Scaffold API (after the decisions above).

## Performance

- Every QA refresh in the live server walks the git history once for the
  self-review flag (`pw_self_items()`, ~0.3 s on the example; the full
  refresh blocks the R thread ~0.5–1 s when idle). Measure on a real WIG2
  project; if slow, cache by HEAD sha + item hashes.
- `last_authors()`: no cache across calls; parent walk is O(history × items).
- `line_diff()` / client LCS diff have no size cap (slow for items with
  hundreds of lines).

## Robustness and edge cases

- `pipeworks_stop()` misses a server whose folder was deleted when the path
  is passed unresolved on macOS (`/var/…` vs `/private/var/…`).
- Slow or hanging git hooks / commit signing prompts block the R session
  during a verdict commit (document; maybe a timeout).
- Fallback token (no `/dev/urandom`, no openssl) is weaker than a CSPRNG.
- `pw_option_origins()` warns from inside a request handler; the
  once-per-value warning cache is never cleared.
- A git email change shows up in the self-review flag only at the next
  refresh.
- Build → Review confirmation might reappear if a Build dialog with unapplied
  edits survives the model update (unverified).
- Loader detection: `map*`/`walk*`/`modify*` prefixes over-match (e.g.
  `modifyList`); aliasing (`s <- source; s(f)`) is not caught; every
  `eval(parse(...))` is flagged.
- `check_again` item without a matching entry/empty `depends` prints the
  sentence without naming a callee.
- `review_rel()` assumes entries sit directly in `qa/reviews/`.
- Moving an item to another file restarts its authorship (mover becomes last
  author).
- `git_try()` on `git show` hides genuine read failures (check with
  `git cat-file -e` first); `git_file_clean()` treats a git failure as "not
  clean".
- `git_exec()` drops the `system2()` error message; pathspecs are not
  literal (glob characters in file names).
- Review entries are written non-atomically; the `-2`, `-3` suffix loop is
  not atomic.
- A `character(0)` comment is stored as `""`; recursive functions may list
  their own id in `depends`.
- Editor: template↔variant prefix tie-break across different maps;
  `map_param()` picks the first named argument (`stringsAsFactors`);
  aggregated view graph could contain a cycle (layout guard); `cardCall()`
  replaces every matching literal; a selected variant is dropped instead of
  moved to its card when folded; dead CSS (`.g-*`, `.fam-head`); `blocks()`
  recomputed inside a sort comparator; `d-ctx` class without CSS.
- Report: `check_again` not surfaced on the cover; review history is empty
  after squash/rebase merges (documented); long ids may overflow table
  cells; template `file.copy()` result unchecked; dead branch
  `is.na(commit) && dirty`.
- `roxygen_title()` ignores an explicit `@title` and doesn't require the
  block to be adjacent; a target's `fn` is the first project function in its
  command (loose for commands calling two functions).
- File-item hash differs from `md5sum()` for CRLF files (consistent between
  disk and git, by design).

## Tests

- Missing: callee removed → `check_again`; stale dependency on
  questionable/wrong; bad base ref inside a repo; `base` below the repo
  root; `last_author` taken from the entry; revert-to-reviewed-hash
  semantics; target hash stability; FUN/.f/f/what with an unlisted caller;
  zero-item draft rendered; dirty factory source; escaping and worktree
  cleanup in `qa_report(ref =)`; undo after fold and aggregated-edge unplug
  in the smoke test.
- Round-trip test of review entries doesn't assert every field.
- Test env not isolated from the global git config
  (`GIT_CONFIG_GLOBAL`/`GIT_CONFIG_NOSYSTEM`).
- Test cache: a failed cache build is not retryable (confusing cascade);
  cache source unprotected; copies lose mtimes; `reviewed_repo()` doesn't
  skip without git; no parallel testing.
- Some tests hard-code example line numbers; a few weak/anchoring nits
  (`expect_match(body, "spec")`, unpinned `area_data_*` dependencies).
- `example_project()` scenario: `edit()` anchors fail obscurely if the
  fixture changes; a failure midway leaves a partial directory.
