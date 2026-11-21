# Review: pipeworks scaffolding API (2026-11-21 high-level design)

Reviewer stance: critical design review, nothing implemented. Evidence comes from
the repo (read-only) and six small experiments run in temp dirs (scripts in
`scratchpad/exp/e1.R` … `e5.R`, output quoted below).

## Summary verdict

The idea is sound and fits pipeworks well: the static source model
(`R/source_model.R`) already knows blocks, targets, maps and functions, so
"check a declared skeleton against the project" is cheap, and token-level
append into `pipeline_<block> <- list(...)` works (E3). But the design as
written has one outright bug, two modelling gaps that will hurt the first real
protocol, and it underrates three hard problems: map identity, drift between
the scaffold and an evolving implementation, and QA side-effects (four-eyes,
hashes). It also leans on a stateful pipe API where LLMs do better with a
declarative spec. Recommended: one scaffold object, two front doors (a spec
list/YAML via `sc_from_spec()` as the primary LLM path, thin pipe verbs over
the same object for humans), `sc_check()` with stable finding codes, and
`sc_write()` dry-run by default. The code stays the only persistent source of
truth; the spec is a one-shot input, regenerable from code with `sc_spec()`.

---

## Experiments (what was tested, what happened)

| # | Question | Result |
|---|---|---|
| E1 | Names `tar_map()` generates from a data frame with numeric / non-syntactic / non-ASCII values | `res_1`, `res_2`, `res_3`; `"AOK Bayern"` → `cnt_AOK.Bayern`, `"TK-Nord"` → `cnt_TK.Nord`, `"ä"` → `cnt_ä`. Works, but names are mangled and non-ASCII names appear. |
| E2 | Target and function with the same name (`tar_target(cs_sample, cs_sample(a))`) | Builds, but targets warns: *"Targets and globals must have unique names. Ignoring global objects that conflict with target names: cs_sample."* → the function is dropped from dependency tracking; editing it will **not** invalidate the target. Silent staleness. |
| E3 | `tar_combine()` after a map, command `fn(list(!!!.x))` | Requires the map to be an R object (`m <- tar_map(...)`, then `m[["model_fit"]]`). `list(!!!.x)` already yields a **named** list (`model_fit_base = model_fit_base, …`); `dplyr::lst()` is unnecessary. |
| E4 | Does `read_source()` / `read_pipeline()` understand that shape (map assigned to `m_spec`, combine inside `pipeline_extra`)? | Yes: `target:fit_two` with `map:fit_two`, `object:R/extra.R:m_spec`, `target:fits_all` with `fn = combine_fits`; `read_pipeline()` gives `fit_two_a` mode `function`, map variant `a`. The combine target has no link to its map in the model (`map = NULL`). |
| E5 | Append a `tar_target()` into an existing `pipeline_import <- list(...)` with a trailing comment inside the list, using parse data only | Works: comma added after the last element, comment kept, new target lands before the closing `)`, `read_source()` sees `cs_sample` at lines 78-82. ~25 lines of code. |
| E6 | `tar_map(values = zz_values)` in `R/aa.R` with `zz_values` defined in `R/zz.R` | `tar_manifest()` fails: *"Objekt 'zz_values' nicht gefunden"*. `tar_source()` sources alphabetically, and block lists are evaluated at source time. |
| E7 | Stub functions and `tar_make()` | Default `error = "stop"` halts at the first stub. With `tar_option_set(error = "null")` the downstream target `after` **completes on a NULL input**. Do not recommend `"null"`. |
| E8 | Custom roxygen tag `@protocol 6.2` | roxygen2 warns *"@protocol is not a known tag"* and drops it. `@section Protocol:` and the standard `@references` both survive. |

---

## 1. Missing functions and capabilities

### Bugs and gaps in the proposed verbs

1. **Duplicate formal in `sc_add_static_map(name, df, name = <column>)`.** Two
   arguments called `name`; R will not even define this function. The user's
   sketch has the same clash (`sc_add_static_map("df_map", name = "name", …)`).
   Use `sc_map(sc, name, values, names = <column(s)>)`, which also matches
   `tar_map(names = )`.
2. **A map has no name in code.** The source model identifies a map by its
   templates (`map:model_fit`, `map:area_data+area_hist`, see
   `resolve_source()` in `R/source_model.R`), because `tar_map()` has no name
   argument. A scaffold map called `df_map` therefore cannot be found again
   on the next run (no idempotence), unless the name is written into code.
   E3/E4 give the natural answer: write the map as a named object
   (`map_regions <- tar_map(...)`) and put the symbol into the block list.
   This is required anyway for `tar_combine()`, and `read_source()` already
   records it (`object:R/extra.R:m_spec`, the map's template holder).
   Decision needed (see 6): map name = the object name.
3. **Inputs conflate argument names and target names.** The model explicitly
   supports `path ← raw_file` (CLAUDE.md, README edge case 1, `target_call()`).
   `inputs = c("obs_start", "obs_end")` cannot express it. Use a named
   character: `inputs = c(path = "raw_file", data = "clean_data")`, unnamed
   elements meaning "argument name = target name".
4. **Constant arguments are missing.** `score_histogram(raw_data, title = "Raw submissions")`
   (edge case 3) cannot be declared. Add `args = list(title = "Raw submissions")`.
5. **One function, several targets.** `sc_add_target()` declares "a target and
   its function skeleton", so the second target that uses `score_histogram()`
   either duplicates the roxygen (and the function, which `resolve_source()`
   rejects: "defined more than once") or must silently reuse. Split the
   concept: `sc_function()` declares a function (roxygen, params, return);
   `sc_target(fn = )` references it; `sc_target()` may create the function
   inline for the common 1:1 case.
6. **Function documentation is per argument, not per input target.** The
   design writes "one `@param` per input with the input's own
   title/description". For `path ← raw_file` the param must document `path`
   ("Path to the survey CSV"), not `raw_file`'s title. Default to the input's
   description only as a fallback, and let `sc_function(params = c(path = "…"))`
   override.
7. **`block` defaults to the last added block.** Hidden state is the most
   common failure mode for LLM tool use (the model loses track after a
   read-back or a retry). Make `block` required on every target/function.
8. **`fn` naming rule** (open question): E2 settles part of it. Same name as
   the target must be an `error` in `sc_check()`, not a convention choice.
   Require `fn` explicitly; offer `sc_check()` a hint "WIG2 convention:
   verb_noun" rather than generating names.

### Capabilities the design does not cover

| Capability | Needed in MVP? | Notes |
|---|---|---|
| File targets (`format = "file"`), raw extract paths | Yes | Protocols start from data extracts; `raw_file` (edge case 5) is the pattern. `sc_input(format = "file")`. |
| Dynamic branching | Yes (already `pattern`) | Check that every symbol in `pattern` is an input. |
| `tar_combine()` details | Yes | Needs the map object (E3), which template (`m[["fit"]]`), and the function with a named-list param. Document that the list is named by variant target names. |
| Factories `tar_render()` / `tar_quarto()` | Later | `sc_report(name, path, uses = c(...))` writing a stub `.Rmd`/`.qmd` with one `tar_read()` per used target (dependencies of factories come from those calls, edge case 7). |
| `tar_option_set(packages = )` | Later | At scaffold time packages are guesses; leave to the junior. |
| `_targets.R` composition | Yes | Append `pipeline_<block>` to the outer `list(...)`; the example's composition also holds a spanning map, so it is not a plain symbol list. |
| Connect to existing targets/functions | Yes | Inputs may name existing targets; `fn` may name an existing function (then no skeleton, but the check compares formals). |
| Remove / rename inside the scaffold (before writing) | Yes (cheap) | `sc_drop(sc, name)`; rename is drop + add. Never on written code. |
| Remove / rename written code | No | That is refactoring; RStudio + `refactor_context`. |
| Update docs of existing items | Later, opt-in | See 4 (drift). Note: comments are not part of the QA hash (`node_hash()` drops `COMMENT` tokens), so a doc change never triggers re-review. |
| Constants vs parameters | Yes | `sc_input(name, value, description, format)` with `value` as R code text (parsed and checked). |
| Read back / inspect | Yes | `as.data.frame()` with one row per declared thing plus a `state` column (`new`, `exists`, `differs`). |
| Serialise to/from file | Yes | `sc_from_spec()` / `sc_spec()`; see 5. |
| Helper functions (not targets) | Later | `sc_function()` without a target, `@keywords internal` (edge case 8). |
| Map spanning several blocks | Later | Exists in the example (edge case 12) but is awkward to scaffold; MVP: a map lives in one block. |

---

## 2. Feasibility

| Part | Feasible? | Hard part / evidence |
|---|---|---|
| Read project into scaffold | Easy | `read_source()` + `read_functions()` are static and already used by QA. Empty project: `check_project()` must allow a folder without `_targets.R`/`R/`. |
| Append targets into `pipeline_<block> <- list(...)` | Yes, with limits | E5: parse-data surgery keeps formatting and comments. Must **refuse** (finding, not crash) when the RHS is not a literal `list(` call (`c(...)`, `tar_plan(...)`, a pipe, a variable). Must handle `list()` empty and comments after the last element (both handled in E5). Never re-deparse existing code. |
| Append functions | Easy | Insert before the `pipeline_<block>` assignment, so functions come first (WIG2 convention). |
| New block file | Easy | Template. Write `pipeline_<name> <- list(\n)`. |
| `_targets.R` composition | Medium | Same surgery as blocks, on the outer `list(...)`. Refuse if `_targets.R` has no top-level `list(` with `pipeline_*` symbols. |
| Generating code text | Medium | Use templates, not `deparse()` (which produces `structure()` noise and breaks long strings). Values tables: emit `data.frame(name = c(...), ...)` with `dput`-style vectors per column; restrict column types to character/numeric/integer/logical/Date. |
| Values location | Constraint | E6: a values table must be defined in the same file **above** its use, or inline in `tar_map(values = )`. Emit inline or as an object directly above the map. |
| Names generated by `tar_map()` | Predictable but mangled | E1: `make.names`-like mangling, non-ASCII passes through. `sc_check()` must require the `names` column(s) to be unique, ASCII, syntactic once joined; then generated names are `<template>_<value>` and can be checked against downstream inputs (`model_fit_full`). |
| Idempotence | Yes, if identity is in code | Target/function identity = name (unique by construction). Map identity = object name (decision 1). Block identity = file. A second `sc_write()` must be a no-op: test with "write, re-read, write, diff = empty". |
| "Already implemented" detection | Partly | Existence is easy. "Implemented" vs "still a stub" needs a marker: body is exactly `stop("Not implemented: <fn>()")` (or a `pipeworks::todo()` call). Existence ≠ agreement: see drift in 4. |
| Diff for `dry_run` | Easy | Write into a temp copy, `diff` per file; no new dependency needed (base R line diff or `tools::Rdiff`-like). |
| Stubs and `tar_make()` | Fine | E7: default `error = "stop"` fails loudly, which is what the design wants. Warn in docs against `error = "null"`. |
| Protocol refs in roxygen | Fine with standard tags | E8: use `@references Protocol 6.2` (standard tag, shows in help) or `@section Protocol:`; not a custom tag. |

QA side-effects that the design does not mention (from `R/source_model.R`
and `R/qa_status.R`):

- Appending a target changes the hash of the block's "rest" object item
  (`object:R/<block>.R:pipeline_<block>`, built with `exclude = covered`
  and one `<item>` token per target). Every scaffold write therefore
  reopens that item for review. Acceptable, but say so.
- Four-eyes: the person who runs `sc_write()` becomes the last author of
  every target entry and stub. If the senior scaffolds and the junior
  implements, the junior becomes the last author of function bodies (fine),
  but the target entries stay the senior's, so the senior cannot approve
  them. Either the junior reviews those, or the target lines get touched
  in implementation. Decide and document.
- A stub could be approved (hash matches) and then drop out of the "open"
  list until the body changes. `qa_check()` should fail on placeholders
  whatever their verdict, and the editor should show them as their own
  state, not only as `unreviewed`.

---

## 3. Nice to have (ranked by value)

1. **Declarative spec (list/YAML/JSON) with a JSON Schema shipped in
   `inst/llm/`.** LLMs produce one validated document far more reliably than
   a 40-call stateful chain; the schema gives tool-calling frameworks
   structured output for free.
2. **Placeholder progress view.** `sc_status()` / an editor overlay: stubs
   vs implemented vs reviewed per block, so a junior sees "next function to
   implement" in topological order (inputs first).
3. **Protocol traceability in the QA report.** `@references Protocol 6.2`
   becomes a column in `qa_report()`: for a pharma client this is the
   strongest selling point ("every protocol section maps to reviewed code").
   Plus a check: protocol sections listed in the spec with no target.
4. **Test skeletons.** `tests/testthat/test-<block>.R` with one
   `test_that("<fn> returns <outputs>", skip("not implemented"))` per
   function, optionally `expect_named()` from a declared contract.
5. **Lightweight data contracts.** Optional `columns = c(pid = "character",
   n = "integer")` per target, written into `@return` as `\describe{}` and
   into the test skeleton. Keep it documentation, not runtime validation, in
   the first round.
6. **Standard block library.** WIG2 recurring blocks (continuous insurance,
   Charlson index) as spec fragments that `sc_from_spec()` can include. Only
   once there are three real projects to extract from.
7. **Stable finding codes with fix hints.** `E_UNDECLARED_INPUT`,
   `E_FN_EQUALS_TARGET`, `W_DRIFT_FORMALS` …, each with a `fix` column
   ("declare `obs_start` with sc_input(), or did you mean `obs_start_date`?"
   via `agrep`). This is what makes an LLM loop converge.

---

## 4. Limitations and risks

What the approach cannot express or guarantee:

- **Correctness of the analysis.** A scaffold fixes the shape, not the
  logic. A well-documented wrong skeleton is worse than none because it
  looks authoritative.
- **Drift after implementation.** "Skip if exists" means a revised protocol
  never reaches implemented code, and a junior who changes formals is never
  told the skeleton disagrees. Needs a `differs` state: declared inputs vs
  formals, declared fn vs actual call, declared `@return` vs written one.
  Report, never apply (except opt-in `update_docs`).
- **Data-dependent structure.** Dynamic branching over values only known at
  run time can be declared, but the scaffold cannot check variant names.
- **Things that do not fit the block convention** (code outside `R/`,
  `tar_plan()` `name = cmd` entries, which `parse_source_file()` treats as
  unrecognised) cannot be targets of write-back.
- **Database connections / sessions** are not serialisable target values;
  a protocol that says "query the benchmark DB" needs a pattern (a file or
  checksum target), as the user's `cs_sample` "returns a checksum" shows.

Where LLM-driven use goes wrong, and the guardrail:

| Failure | Guardrail |
|---|---|
| Hallucinated inputs (target names that exist nowhere, data columns used as targets) | `error` on undeclared input; fuzzy "did you mean" hint; a column of a map is only valid in targets of that map. |
| Naming drift (`cs_sample`, `sample_cs`, `csSample` across calls) | Enforce snake_case ASCII; warn on near-duplicate names (edit distance); `fn` required. |
| Over-fragmentation (one target per protocol sentence) | Warnings: target with no downstream use and not marked `endpoint = TRUE`; function bodies that would be one-liners can't be detected, but a "targets per block" and "targets total vs protocol sections" summary helps the senior spot it. |
| Under-specified docs | `error` without title and `@return`; `warning` without refs when the spec declares protocol sections. |
| Stateful chain breaks mid-way | Idempotent verbs, no implicit "current block", `sc_write()` refuses with any `error`. |
| Writing over real work | Append-only, never touch existing items; `dry_run = TRUE` default; refuse a dirty git tree unless `force`. |
| Invented R code in `value` | Parse every code string; restrict `value` to a single expression; report its free symbols as inputs. |
| Function names colliding with packages (`filter`, `sample`) | `warning` when `fn` masks a function in base or in `tar_option_set(packages)`. |

---

## 5. Alternatives

**(a) Declarative spec file + `sc_from_spec()` / `sc_write()`.**
Strengths: one artefact, reviewable in a merge request, diffable, validated
by a JSON Schema, natural LLM output, easy to regenerate. Weakness: if the
spec file is *kept* in the repo it becomes a second source of truth next to
roxygen, which the QA design names as an anti-goal ("a second workflow …
that people must keep in sync by hand"). Resolution: the spec is input, not
state. `sc_spec(path)` regenerates it from code at any time, so nothing has
to be kept in sync. **Adopt, as the primary LLM path.**

**(b) Existing tooling.**
- `targets::tar_script()`: writes a whole `_targets.R`; knows nothing of
  blocks, roxygen or appending. Useful only for a brand-new project.
- `tarchetypes::tar_plan()`: nicer syntax, but its `name = command` entries
  are not recognised by pipeworks' source model, so it would break QA items.
- `usethis::use_template()` and golem's `add_module()`-style helpers: create
  whole files from templates; no merging into existing files and no checks.
  Good model for `sc_add_block()` only.
- {fusen}: flat Rmd inflated into R/, tests and vignette. Closest in spirit
  (literate, docs first, tests generated) but package-oriented, overwrites
  generated files on re-inflate, and would make the Rmd the source of truth.
- Quarto-first / Target Markdown (targets' own literate interface): protocol
  and code side by side is attractive for a study protocol, but it is a
  different layout from WIG2 blocks and its generated scripts are not the
  hand-edited `R/` files QA reviews.
None of them check a skeleton against an existing project; that check is
pipeworks' unique contribution.

**(c) LLM writes R files directly; pipeworks only validates.**
Cheapest to build (largely exists: static model, QA, roxygen checks) and
most flexible. Weaknesses: formatting/structure drift across files, no
idempotence, the LLM rewrites existing code, review of a big generated diff
is exactly the MR problem pipeworks was built to avoid. But the validator
half is needed anyway: `sc_check()` should be able to run on a project
without a scaffold (`sc_check(sc_spec(path))`), which gives (c) for free.

**Recommendation:** (a) + thin pipe verbs + the validator from (c), sharing
one internal object. Order of value: validator (needed by everyone) →
spec input → writer. The pipe API is a convenience over the same object, not
the core; an LLM should be pointed at the spec schema first.

---

## 6. Concrete recommendation

### Revised verbs

| Verb | Signature sketch | Purpose |
|---|---|---|
| `pipeline_scaffold()` | `(path = ".")` | Read project (static only) into a scaffold; empty project → empty scaffold. |
| `sc_from_spec()` | `(spec, path = ".")` spec = list, YAML/JSON path | Build/merge a scaffold from a declarative spec. |
| `sc_spec()` | `(x, file = NULL)` x = scaffold or path | Export the scaffold (or a project's code) as a spec; LLM read-back. |
| `sc_block()` | `(sc, name, title, description = NULL)` | Declare a block = `R/<name>.R` + `pipeline_<name>`. |
| `sc_function()` | `(sc, name, block, title, description, params = c(arg = "text"), returns, family = NULL, refs = NULL)` | Declare a function skeleton with roxygen. |
| `sc_target()` | `(sc, name, block, fn, inputs = c(arg = "target"), args = list(), title = NULL, description = NULL, map = NULL, pattern = NULL, format = NULL, refs = NULL, endpoint = FALSE)` | Declare a target calling `fn`; creates `fn` inline if not declared and roxygen fields are given. |
| `sc_input()` | `(sc, name, block, value, description, format = NULL)` | Constant/parameter/file target as expression target with `description =`. `value` is R code text. |
| `sc_map()` | `(sc, name, block, values, names = NULL)` | Static map, written as `name <- tar_map(values = …, names = …, <templates>)`. |
| `sc_combine()` | `(sc, name, block, map, template, fn, title, returns, refs = NULL)` | `tar_combine(name, map[["template"]], command = fn(list(!!!.x)))`. |
| `sc_drop()` | `(sc, name)` | Remove a not-yet-written declaration. |
| `sc_check()` | `(sc)` → findings df (`level`, `code`, `item`, `message`, `fix`) | Validate; also drift (`differs`) against existing code. |
| `sc_write()` | `(sc, dry_run = TRUE, force = FALSE)` | Append-only write; diff when dry; refuses on errors or dirty tree. |
| `print` / `as.data.frame` | | Tree by block / one row per declaration with `state` (`new`, `exists`, `differs`, `stub`). |
| later: `sc_report()` | `(sc, name, path, uses, block)` | tar_render/tar_quarto + stub `.Rmd`/`.qmd` with `tar_read()` per use. |
| later: `sc_tests()` | `(sc)` | testthat skeletons per function. |
| later: `sc_status()` | `(path)` | Placeholder progress per block, next function to implement in dependency order. |

### MVP vs later

MVP (one round): `pipeline_scaffold`, `sc_from_spec` (R list + JSON; YAML
if `yaml` is acceptable as a Suggests), `sc_spec`, `sc_block`,
`sc_function`, `sc_target`, `sc_input`, `sc_map`, `sc_combine`, `sc_drop`,
`sc_check`, `sc_write(dry_run = TRUE)`, print/`as.data.frame`; the agent
reference `inst/llm/scaffold-api.md` with the JSON Schema and one
end-to-end example (re-scaffolding `inst/examples/survey` from a spec is
the ideal test: write into an empty dir, `tar_manifest()` must match the
example's target names and edges). Placeholders fail `qa_check()`.

Later: `sc_report`, `sc_tests`, `sc_status` and the editor progress
overlay, data contracts, `update_docs`, protocol column in `qa_report()`,
standard block library, maps spanning blocks, git commit from `sc_write()`.

### Top 5 decisions for the user

1. **Map identity:** a map is a named object in its block
   (`map_regions <- tar_map(...)`), its name is the scaffold's map name.
   (Needed for idempotence and `tar_combine()`; E3/E4.)
2. **Primary interface:** spec (list/JSON/YAML) as the LLM contract with
   pipe verbs as sugar, or pipe-only as sketched. And confirm the spec is
   never stored as state.
3. **Function naming:** `fn` required (recommended), or a generated rule.
   Same-as-target is ruled out by E2.
4. **Placeholders in QA and four-eyes:** stub marker (`stop("Not
   implemented")` vs a `todo()` helper), stubs fail `qa_check()` regardless
   of verdict, and who reviews the target entries the scaffolder wrote.
5. **Drift policy:** for existing items, report differences only, or allow
   opt-in doc updates; and where protocol refs live (`@references`
   recommended over a custom tag, E8).
