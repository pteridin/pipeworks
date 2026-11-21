# pipeworks

pipeworks shows a `{targets}` pipeline as a wiring diagram. Each file in `R/`
is a block on the canvas, and the roxygen comments of your functions explain
what happens in it. It also supports the second analyst who reviews the code:
verdicts are saved as small files in the repository, and a PDF report
documents the result.

RStudio stays your main editor. The visual editor stays connected to your R
session and records review verdicts. Edits of the pipeline made in it are not
yet written back to your files.

## Installation

pipeworks is not on CRAN. Install it from GitHub. The repository is private,
so you need a GitHub personal access token with read access to it, stored as
`GITHUB_PAT` (e.g. with `usethis::edit_r_environ()` or `gitcreds::gitcreds_set()`):

```r
remotes::install_github("pteridin/pipeworks")
```

For the PDF report you also need [Quarto](https://quarto.org) and `git`.

## Try it

```r
library(pipeworks)
p <- example_project(file.path(tempdir(), "survey"), git = TRUE)
pipeworks(p)
```

`example_project(git = TRUE)` creates a small project as a git repository. The
branch `main` is already reviewed. The branch `dev/sample-definition` has
changes that still wait for review.

`pipeworks()` starts a small server inside your R session. It opens the
editor in the RStudio Viewer, or in your browser outside RStudio. The console
stays free. The page stays connected to R and refreshes by itself when you
change code, `qa/` or the git branch. Call `pipeworks(p)` again to show it
again. `pipeworks_stop(p)` stops the server. It also stops when R ends.

## A QA round

You are the reviewer. The analyst has pushed a branch. In the project folder:

```r
pipeworks()
```

If open items were last changed by someone else, the editor opens in Review
mode. Click an item (a target, function or other block). The dialog shows its
status and has the buttons Correct, Questionable and Wrong. Questionable and
Wrong need a comment. Each click records the verdict and commits it. One
verdict is one commit named `qa: <verdict> <item>`, and it contains only that
entry file. The progress bar counts the open items down. When it is full,
`qa_check()` passes.

The same in the console, without the editor:

```r
st <- qa_status(base = "main")        # what changed, what is open
qa_review("clean_survey", "correct")  # one verdict per item, committed at once
qa_review("count_by_channel", "questionable", "Missing values are dropped silently")
qa_check()                            # fails until every open item has a verdict
qa_report()                           # writes qa-report.pdf
```

`qa_review()` commits each verdict by itself. Use `commit = FALSE` to only
write the file and commit it yourself. If the commit fails, the file stays.
The editor then offers to retry, and `qa_review()` tells you.

Verdict commits are local. Push them (`git push`) so they reach the merge
request. Verdicts need a branch: on a detached HEAD they are refused.

`qa_review()` and the editor only work on committed code: every file in
`R/`, `_targets.R` and the report sources must be committed. They also need a
git name and email (`git config user.name`, `git config user.email`) and
refuse while a merge, rebase, cherry-pick or revert is running. `qa_report(final =
TRUE)` refuses to render while the check fails, while code or review files
have uncommitted changes, and for a project without items.

The report's review history lists the merge commits that brought review
files in. After a squash merge there is no merge commit, so the history is
empty.

### Walk through in the console

`qa_walk()` goes through the open items one by one:

```r
qa_walk("path/to/project")
```

For each item it shows the status, who changed it last, the code and the
changes since the base branch (`main` by default). Answer `c` (correct), `q` (questionable), `w` (wrong),
`s` (skip) or `x` (quit). Questionable and wrong ask for a comment. Each
verdict is committed like with `qa_review()`. Use it for a quick review
without the editor. It needs an interactive R session.

### Review and Build mode

The editor has two modes. Review is for checking: the pipeline is read-only
and the verdict buttons are there. Build is for changing the pipeline in the
view and has no verdict buttons. `pipeworks()` picks the mode by your role:
Review when open items were last changed by someone other than you (the
current git user), else Build. Switch with the buttons in the top bar. You can
also force it: `pipeworks(p, mode = "review")`.

The button at the left of the top bar collapses the sidebar. The theme button
cycles through system, light and dark.

### RStudio Server

pipeworks works on RStudio Server and Posit Workbench through the RStudio
proxy. The address of the proxy is allowed automatically. If the page shows a
403 that names a host or origin, allow your server:

```r
# replace with the address of your RStudio Server, as named in the 403 message
options(pipeworks.allowed_origins = "https://rstudio.example.org")
```

Then call `pipeworks()` again. Please test this once on your server and tell
us what you see; it has not been tried on a real server yet.

## GitLab CI

This job fails the pipeline while reviews are missing. pipeworks is
installed from its private GitHub repository, so add a masked CI/CD variable
`GITHUB_PAT` (a GitHub token with read access to `pteridin/pipeworks`) in your
GitLab project under *Settings > CI/CD > Variables*. `rocker/r-ver` has no
`git`, so the job installs it.

```yaml
qa:
  image: rocker/r-ver:4.4
  before_script:
    - apt-get update && apt-get install -y git
  script:
    - Rscript -e 'install.packages("remotes")'
    - Rscript -e 'remotes::install_github("pteridin/pipeworks")'   # uses GITHUB_PAT
    - Rscript -e 'pipeworks::qa_check()'
```

`qa_check()` reads only the files of the checked-out commit, not the git
history.

`qa_report()` needs Quarto in the image. An optional step that keeps the PDF
as a job artifact:

```yaml
qa-report:
  image: rocker/verse:4.4   # R with Quarto and git
  variables:
    GIT_DEPTH: 0   # the review history comes from the merge commits
  script:
    - Rscript -e 'install.packages("remotes")'
    - Rscript -e 'remotes::install_github("pteridin/pipeworks")'   # uses GITHUB_PAT
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
until it is moved into `R/`. This includes indirect forms such as
`lapply(files, source)`.

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
- The editor is connected to R, but edits of the pipeline (roxygen, targets)
  stay in memory. Writing them back to your files is still to come. Only
  verdicts are written.
- The static page from `pipeworks_html()` has no connection to R. It opens in
  Build mode when nothing is open. In Review mode it shows the `qa_review()`
  call to copy instead of buttons.
