# pipeworks: scaffolding API (high-level design)

Status: idea, high-level · 2026-11-21 · not scheduled
Builds on: the block model, QA engine and live connection (2026-11-20, 2026-11-21 specs).

## Intent

Projects often start from a study protocol. Before a (junior) analyst
implements anything, someone (a senior analyst, or an LLM reading the
protocol) should lay out the pipeline: which targets exist, in which block
(file), what each one takes and returns, which analyses repeat over a
parameter table. pipeworks provides a **pipe-able R API** to declare that
skeleton, check it, and write it as files in the WIG2 convention.

**No LLM functionality in the package.** The API is designed so that any LLM
(or a human, or a script) can drive it reliably. The protocol-reading
happens outside; pipeworks only offers the verbs.

## The shape (from the user's sketch)

```r
scaffold <- pipeline_scaffold(".")            # loads the current _targets layout
scaffold <- scaffold |>
  sc_add_target("cs_sample",
    title       = "Generates the sample",
    description = "Defines a cross-sectional sample within the WIG2 Benchmark Database.",
    inputs      = c("obs_start", "obs_end"),
    outputs     = "A checksum of the sample definition") |>
  sc_add_static_map("df_map",
    name = "name",
    df   = data.frame(name = 1:3, input = c(4, 6, 8)))

scaffold |> sc_check()   # what is missing, what already exists
## Declarations: obs_start & obs_end are not declared
## Existing targets: cs_sample is already implemented; SKIP

scaffold |> sc_write()   # writes only what is new; same report
```

## Verbs (proposal)

| Verb | Does |
|---|---|
| `pipeline_scaffold(path = ".")` | Reads the existing project (static source model: blocks, targets as written, functions, maps) into a scaffold object. Empty project → empty scaffold. |
| `sc_add_block(name, description = NULL)` | Declares a block = a file `R/<name>.R` with `pipeline_<name> <- list()`. |
| `sc_add_target(name, title, description, inputs, outputs, block = NULL, fn = NULL, map = NULL, pattern = NULL, format = NULL, refs = NULL)` | Declares a target and its function skeleton. `inputs` are target or declaration names (they become arguments and wiring), `outputs` the `@return` text, `refs` free-text references (e.g. protocol section "6.2"). `block` defaults to the last added block; `fn` defaults to a naming rule (open question). `map` puts the target into a static map. |
| `sc_declare(name, value = NULL, description)` | Declares an input that is not computed by a function: a constant or parameter target (e.g. `obs_start = as.Date("2019-01-01")`), written as an expression target with `description =`. |
| `sc_add_static_map(name, df, name = <column for suffixes>)` | Declares a `tar_map()` over a values table; targets join it via `sc_add_target(..., map = "df_map")`. The map's column names become available as inputs. |
| `sc_combine(name, from, title, description, outputs)` | Declares a combination target after a map (`tar_combine()` with a function receiving the named list of variants). |
| `sc_check(scaffold)` | Validates without writing. Returns a data frame (one row per finding: `level`, `kind`, `item`, `message`) with a print method in the style of the sketch. |
| `sc_write(scaffold, dry_run = FALSE)` | Writes what is new, skips what exists, reports both. `dry_run = TRUE` shows the file changes as a diff. Commits optional (open question). |
| `print(scaffold)` / `as.data.frame(scaffold)` | Human-readable tree by block; tabular form for checks and for LLMs to read back. |

## Check rules

- **Undeclared inputs:** every input must be an existing target, a declared
  target, a declaration (`sc_declare`) or a column of the target's map.
- **Existing items:** a target or function that already exists in the
  project is reported and **skipped**, never overwritten (the sketch's
  "already implemented; SKIP"). Documentation-only differences are listed as
  a hint, not applied.
- Names are valid R symbols and unique; no cycles; every map has at least
  one target; combine targets refer to a map.
- Every declared target has a title and outputs (roxygen `@return`); missing
  descriptions are a warning.
- Levels: `error` blocks `sc_write()`; `warning` is reported; `info` lists
  skips.

## What `sc_write()` produces

- Per block `R/<block>.R`: function skeletons with full roxygen (title,
  description, one `@param` per input with the input's own title/description,
  `@return`, and the `refs` as a line such as `@section Protocol: 6.2`), body
  `stop("Not implemented: <fn>()")`, then `tar_target()` entries appended to
  `pipeline_<block> <- list(...)`.
- Declarations as expression targets with `description =`.
- Static maps as `tar_map(values = ..., names = ..., <templates>)`; combine
  targets as `tar_combine(..., command = <fn>(list(!!!.x)))`.
- `_targets.R` composition updated with new blocks.
- Placeholders are visible: the editor marks "not implemented" functions;
  `tar_make()` fails loudly on them; they enter QA as `unreviewed`.

## Designed for LLMs (without containing one)

- **Small, typed, idempotent verbs:** calling the same chain twice changes
  nothing the second time.
- **Explicit, machine-readable feedback:** `sc_check()` returns structured
  findings an LLM can act on in a loop ("declare obs_start", "fix cycle").
- **Read-back:** `as.data.frame(scaffold)` and `print()` let a model see the
  current state before adding more.
- **Dry run first:** `sc_write(dry_run = TRUE)` lets a human approve.
- **Documentation for agents:** a vignette plus a compact reference file
  shipped with the package (e.g. `inst/llm/scaffold-api.md`) describing the
  verbs, rules and an end-to-end example, so any LLM tool can be pointed at
  it.

## Non-goals

- Calling an LLM, reading protocols, generating analysis code.
- Overwriting or merging into existing implemented functions.

## Open questions (for a proper design round)

- Function naming rule when `fn` is not given: same as target, a verb prefix
  (`make_cs_sample()`), or required?
- Declarations: are `obs_start`/`obs_end` best as targets (tracked, visible
  in the pipeline) or as values in a config block?
- Should `sc_write()` commit (one commit "scaffold: …"), as verdicts do?
- Changed documentation for an existing item: report only, or offer
  `sc_write(update_docs = TRUE)`?
- A library of WIG2 standard blocks (e.g. continuous insurance, Charlson
  index) that `sc_add_target()` can reference instead of declaring anew?

## Suggested order (when scheduled)

1. Write-back engine (render blocks, functions, targets, maps into files;
   append-only, skip existing) — needed for Build mode anyway.
2. Scaffold object + `pipeline_scaffold()` + verbs + `sc_check()`.
3. `sc_write()` with `dry_run`, editor marking of placeholders.
4. Agent reference file + vignette with an end-to-end example.
