# pipeworks

pipeworks shows a `{targets}` pipeline as a wiring diagram. Each file in `R/`
is a block on the canvas, and the roxygen comments of your functions explain
what happens in it. It also supports the second analyst who reviews the code:
verdicts are saved as small files in the repository, and a PDF report
documents the result.

RStudio stays your main editor. The visual editor only reads your project.
Edits made in it are not yet written back to your files.

## Installation

pipeworks is not on CRAN. Install it from your GitLab:

```r
# <your GitLab URL> is a placeholder
remotes::install_git("<your GitLab URL>/pipeworks.git")
```

For the PDF report you also need [Quarto](https://quarto.org) and `git`.

## Try it

```r
library(pipeworks)
path <- example_project(file.path(tempdir(), "survey"), git = TRUE)
pipeworks(path)
```

`example_project(git = TRUE)` creates a small project as a git repository. The
branch `main` is already reviewed. The branch `dev/sample-definition` has
changes that still wait for review.

## A QA round

You are the reviewer. The analyst has pushed a branch. In the project folder:

```r
st <- qa_status(base = "main")        # what changed, what is open
qa_review("clean_survey", "correct")  # one verdict per item
qa_review("count_by_channel", "questionable", "Missing values are dropped silently")
# commit the new files in qa/reviews/ (RStudio Git pane or terminal)
qa_check()                            # fails until every open item has a verdict
qa_report()                           # writes qa-report.pdf
```

`qa_review()` only works on committed code: every file in `R/`, `_targets.R`
and the report sources must be committed. It writes one file per verdict to
`qa/reviews/`. Commit these files with the branch. `qa_report(final = TRUE)`
refuses to render while the check fails, while code or review files have
uncommitted changes, and for a project without items.

The report's review history lists the merge commits that brought review
files in. After a squash merge there is no merge commit, so the history is
empty.

## GitLab CI

This job fails the pipeline while reviews are missing. Replace `<host>` and
`<group>` with your GitLab host and group. `rocker/r-ver` has no `git`, so the
job installs it. The job token can clone pipeworks only if the pipeworks
project allows it: in pipeworks, *Settings > CI/CD > Job token permissions*,
add the projects that use it.

```yaml
qa:
  image: rocker/r-ver:4.4
  before_script:
    - apt-get update && apt-get install -y git
  script:
    - Rscript -e 'install.packages(c("remotes", "jsonlite", "roxygen2", "targets", "withr"))'
    - Rscript -e 'remotes::install_git("https://gitlab-ci-token:${CI_JOB_TOKEN}@<host>/<group>/pipeworks.git")'
    - Rscript -e 'pipeworks::qa_check()'
```

`qa_check()` reads only the files of the checked-out commit, not the git
history.

`qa_report()` needs Quarto in the image. An optional step that keeps the PDF
as a job artifact:

```yaml
qa-report:
  image: <an image with R, Quarto and git>
  variables:
    GIT_DEPTH: 0   # the review history comes from the merge commits
  script:
    - Rscript -e 'install.packages(c("remotes", "jsonlite", "roxygen2", "targets", "withr"))'
    - Rscript -e 'remotes::install_git("https://gitlab-ci-token:${CI_JOB_TOKEN}@<host>/<group>/pipeworks.git")'
    - Rscript -e 'pipeworks::qa_report(output = "qa-report.pdf")'
  artifacts:
    paths:
      - qa-report.pdf
```

## How reviews work

**Items.** The reviewer looks at one item at a time. pipeworks reads your
source files and never runs your code: every `.R` file below `R/` (subfolders
too, as `tar_source()` loads them), `_targets.R` and the report sources. An
item is one of:

| Kind       | What it is                                                  | Id example                     |
|------------|-------------------------------------------------------------|--------------------------------|
| `function` | a top-level function in `R/` (also helpers no target uses)  | `function:clean_survey`        |
| `target`   | one `tar_target()` as written, with all its arguments       | `target:clean_data`            |
| `map`      | the `values` and `names` of a `tar_map()`                   | `map:model_fit_base+model_fit_full` |
| `object`   | other top-level code: constants, tables, `tar_option_set()` | `object:R/import.R:channels`   |
| `object`   | the rest of a top-level block that holds targets: the list around them, other target factories, the blocks named in `_targets.R` | `object:R/report.R:pipeline_report` |
| `file`     | source of a factory, such as the `.Rmd` of `tar_render()`   | `file:report.Rmd`              |

Adding or deleting a target in a list, or a block in `_targets.R`, changes the
rest item of that list, so it needs a new verdict. Target factories that
pipeworks does not know (for example `tar_files_input()`) are reviewed as part
of that rest item.

Data files are not reviewed. Code loaded with `source()`, `sys.source()` or
`tar_source()` from another folder cannot be reviewed: `qa_check()` fails
until it is moved into `R/`.

**Verdicts.** `correct`, `questionable` or `wrong`. The last two need a
comment. Each verdict is a JSON file in `qa/reviews/`. Files are never
edited. A new verdict is a new file, and the latest one counts.

**Changes.** A verdict belongs to the exact code it was given for. pipeworks
compares a fingerprint of the code without comments and formatting. Changing
a comment, a roxygen line or the indentation keeps the verdict. Changing the
code makes the item `changed`, and it needs a new verdict.

**check_again.** If a function is `correct` but a function it calls has
changed since, the status is `check_again`. This is a hint. It does not fail
`qa_check()`.

**Four-eyes rule.** Nobody reviews code that they last changed. `qa_check()`
fails if the reviewer of an item is the person who last changed it. The entry
stores the author at the time of the review. So the check stays correct
after a squash or a rebase in the merge request. If the author cannot be told
from the git history, `qa_review()` refuses, and an entry without author or
reviewer email fails the check ("authorship unknown").

**Done.** An item is done when it passes `qa_check()`: `correct`,
`check_again` or `questionable` (unless `allow_questionable = FALSE`),
reviewed by someone else. The editor, `print(qa_status())` and the report
count the same way.

**People.** Reviewers and authors are matched by their git email, ignoring
upper and lower case. If one
person uses several emails (for example GitLab web commits), list them in
the file `qa/people`:

```
Name: Ann Analyst
Emails: ann@wig2.de, ann@users.noreply.gitlab.example
```

**Report.** While `qa_check()` fails, `qa_report()` makes a draft marked
"DRAFT – QA incomplete" that lists the open items. `qa_report(final = TRUE)`
refuses to render until the check passes. The report states its scope: all R
code in `R/` and `_targets.R` and the report sources; data files are not
reviewed. Use `signatures = TRUE` for
signature lines. Without them the report says it is valid without signature.
`options(pipeworks.organisation = "...")` adds your organisation to the cover.

## Limitations

- Going back to an earlier code version that was already reviewed counts as
  `changed`. The latest verdict wins, so the item needs a new verdict.
- A deleted item leaves no item behind. Its removal shows up as a change of
  the rest item around it (the list or `_targets.R`).
- Edits in the visual editor stay in memory.
- The live connection to RStudio comes later.
