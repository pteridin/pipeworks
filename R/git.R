# Git layer: authorship for the QA engine. Everything goes through
# `system2("git", ...)`; nothing here runs pipeline code.

git_available <- function() nzchar(Sys.which("git"))

# Run git in `path`. Returns stdout lines; stops with git's message on failure.
git_run <- function(path, args) {
  if (!git_available()) stop("`git` was not found on the PATH.", call. = FALSE)
  res <- git_exec(path, args)
  if (res$status != 0) {
    msg <- trimws(paste(c(res$err, res$out), collapse = "\n"))
    stop("git ", paste(args, collapse = " "), " failed: ", msg, call. = FALSE)
  }
  res$out
}

git_exec <- function(path, args) {
  err <- tempfile("git-err-")
  on.exit(unlink(err), add = TRUE)
  out <- tryCatch(
    suppressWarnings(system2("git", c("-C", shQuote(path), shQuote(args)), stdout = TRUE, stderr = err)),
    error = function(e) structure(character(), status = 1L)
  )
  status <- attr(out, "status")
  # git writes UTF-8 (file contents as committed, metadata by default); mark
  # it so, whatever the session locale
  out <- as.character(out)
  Encoding(out) <- "UTF-8"
  list(
    out = out,
    err = if (file.exists(err)) readLines(err, warn = FALSE) else character(),
    status = if (is.null(status)) 0L else status
  )
}

# Like `git_run()`, but NULL instead of an error (also without git or repo).
git_try <- function(path, args) {
  if (!git_available() || !dir.exists(path)) return(NULL)
  res <- git_exec(path, args)
  if (res$status != 0) NULL else res$out
}

git_user <- function(path) {
  one <- function(key) {
    v <- git_try(path, c("config", key))
    if (length(v) && nzchar(v[1])) v[1] else NA_character_
  }
  list(name = one("user.name"), email = one("user.email"))
}

git_head <- function(path) {
  v <- git_try(path, c("rev-parse", "--verify", "--quiet", "HEAD"))
  if (length(v) && nzchar(v[1])) v[1] else NA_character_
}

# TRUE only if `file` is tracked and has no staged or unstaged change.
git_file_clean <- function(path, file) {
  if (is.null(git_try(path, c("ls-files", "--error-unmatch", "--", file)))) return(FALSE)
  st <- git_try(path, c("status", "--porcelain", "--", file))
  !is.null(st) && length(st) == 0
}

# Paths below `specs` (relative to `path`) that are modified, staged or
# untracked; `character()` when clean (or outside git).
git_dirty <- function(path, specs) {
  specs <- unique(specs[file.exists(file.path(path, specs))])
  if (!length(specs)) return(character())
  out <- git_try(path, c("status", "--porcelain", "--untracked-files=all", "--", specs))
  sub("^.. ", "", out)
}

# Uncommitted code files of the project: `R/`, `_targets.R` and the factory
# sources (`file` items) of `items`.
uncommitted_code <- function(path, items) {
  git_dirty(path, c("R", "_targets.R", items$file[items$kind == "file"]))
}

# Hash of every item (named by id) of the code tree at `commit`: all `R/**.R`,
# `_targets.R` and the factory source files `extra`, relative to `path` (which
# may be below the repo root). A version that does not parse counts as "no
# items". `cache` (an environment) keeps, across calls: the file versions
# (blob ids) and hashes per commit, the hashes per set of file versions
# (commits that leave the code alone reuse them), and the text and parse of
# every file version, so each version is read and parsed once however many
# commits contain it. Trees and blobs are read in bulk with `git cat-file`;
# `cache$order` (commits, e.g. the log) lets one call cover the next commits.
git_item_hashes <- function(path, commit, extra, cache) {
  if (!is.null(cache$commits[[commit]])) return(cache$commits[[commit]])
  if (is.null(cache$commits)) {
    for (k in c("commits", "files", "trees", "dirs", "blobs", "parsed")) assign(k, new.env(hash = TRUE), envir = cache)
  }
  if (is.null(cache$files[[commit]])) {
    at <- match(commit, cache$order)
    window <- if (is.na(at)) commit else cache$order[at:min(length(cache$order), at + 255L)]
    window <- unique(c(commit, window[!vapply(window, function(w) !is.null(cache$files[[w]]), logical(1))]))
    git_commit_files(path, window, extra, cache)
    blobs <- unique(unlist(lapply(window, function(w) cache$files[[w]]$blob), use.names = FALSE))
    git_read_blobs(path, setdiff(blobs, ls(cache$blobs, all.names = TRUE)), cache$blobs)
  }
  tree <- cache$files[[commit]]
  key <- paste(tree$path, tree$blob, sep = "\x1f", collapse = "\x1e")
  hashes <- cache$trees[[key]]
  if (is.null(hashes)) {
    hashes <- tree_item_hashes(tree, cache)
    cache$trees[[key]] <- hashes
  }
  cache$commits[[commit]] <- hashes
  hashes
}

# Items of one tree version from cached per-file parses plus the cross-file
# resolution (`resolve_source()`).
tree_item_hashes <- function(tree, cache) {
  text_of <- function(f) {
    blob <- tree$blob[tree$path == f]
    if (length(blob)) cache$blobs[[blob[1]]]
  }
  code <- tree$path[is_code_file(tree$path)]
  parsed <- lapply(code, function(f) {
    k <- paste(f, tree$blob[tree$path == f][1], sep = "\x1f")
    hit <- cache$parsed[[k]]
    if (is.null(hit)) {
      lines <- text_of(f)
      hit <- if (is.null(lines)) FALSE else tryCatch(parse_source_file(f, lines), error = function(e) FALSE)
      cache$parsed[[k]] <- hit
    }
    hit
  })
  if (any(vapply(parsed, isFALSE, logical(1)))) return(character())
  src <- tryCatch(resolve_source(parsed, code, text_of, links = FALSE), error = function(e) NULL)
  if (is.null(src) || !nrow(src$items)) character() else stats::setNames(src$items$hash, src$items$id)
}

# The code files (`R/**.R`, `_targets.R`) and `extra` files of each commit in
# `commits`, as data frames `path`, `blob` stored in `cache$files`. One
# `git cat-file --batch-check` call resolves the paths of all commits, and one
# `git cat-file --batch` call per folder depth reads the distinct `R/` trees.
git_commit_files <- function(path, commits, extra, cache) {
  if (is.null(cache$prefix)) {
    prefix <- git_run(path, c("rev-parse", "--show-prefix"))
    cache$prefix <- if (length(prefix)) prefix[1] else ""
  }
  wanted <- c("R", "_targets.R", extra)
  query <- as.vector(outer(paste0(wanted, ""), commits, function(w, c) paste0(c, ":", cache$prefix, w)))
  found <- git_batch_check(path, query)
  oid <- matrix(found$oid, nrow = length(wanted))
  type <- matrix(found$type, nrow = length(wanted))
  git_read_trees(path, unique(oid[1, type[1, ] == "tree"]), cache$dirs)
  for (j in seq_along(commits)) {
    r_files <- if (identical(type[1, j], "tree")) tree_listing(oid[1, j], cache$dirs) else NULL
    rows <- if (is.null(r_files)) data.frame(path = character(), blob = character(), stringsAsFactors = FALSE)
      else data.frame(path = paste0("R/", r_files$path), blob = r_files$blob, stringsAsFactors = FALSE)
    other <- which(type[-1, j] == "blob") + 1L
    rows <- rbind(rows, data.frame(path = wanted[other], blob = oid[other, j], stringsAsFactors = FALSE))
    rows <- rows[is_code_file(rows$path) | rows$path %in% extra, , drop = FALSE]
    rows <- rows[!duplicated(rows$path), , drop = FALSE]
    cache$files[[commits[j]]] <- rows[order(rows$path, method = "radix"), , drop = FALSE]
  }
  invisible()
}

# `git cat-file --batch-check` for object names: data frame `oid`, `type`
# (`NA` for missing objects), in the order of `names`.
git_batch_check <- function(path, names) {
  if (!git_available()) stop("`git` was not found on the PATH.", call. = FALSE)
  out <- suppressWarnings(system2("git", c("-C", shQuote(path), "cat-file", "--batch-check"),
                                  input = names, stdout = TRUE, stderr = FALSE))
  if (length(out) != length(names)) stop("git cat-file --batch-check failed in ", path, call. = FALSE)
  parts <- strsplit(out, " ", fixed = TRUE)
  ok <- !grepl(" missing$| ambiguous$", out)
  data.frame(
    oid = ifelse(ok, vapply(parts, `[`, "", 1), NA_character_),
    type = ifelse(ok, vapply(parts, function(p) if (length(p) >= 2) p[2] else NA_character_, ""), NA_character_),
    stringsAsFactors = FALSE
  )
}

# Read tree objects `ids` (and, level by level, their subtrees) into `into`:
# tree id -> data frame `name`, `type` ("blob"/"tree"), `oid`.
git_read_trees <- function(path, ids, into) {
  ids <- setdiff(ids, ls(into, all.names = TRUE))
  while (length(ids)) {
    objects <- git_cat_batch(path, ids)
    sub_trees <- character()
    for (id in names(objects)) {
      entries <- parse_tree_object(objects[[id]], nchar(id) / 2)
      assign(id, entries, envir = into)
      sub_trees <- c(sub_trees, entries$oid[entries$type == "tree"])
    }
    ids <- setdiff(unique(sub_trees), ls(into, all.names = TRUE))
  }
  invisible()
}

# Every blob below tree `id`: data frame `path` (relative to the tree), `blob`.
tree_listing <- function(id, dirs) {
  entries <- dirs[[id]]
  if (is.null(entries)) return(NULL)
  out <- list(data.frame(path = entries$name[entries$type == "blob"], blob = entries$oid[entries$type == "blob"],
                         stringsAsFactors = FALSE))
  for (k in which(entries$type == "tree")) {
    sub <- tree_listing(entries$oid[k], dirs)
    if (!is.null(sub) && nrow(sub)) out[[length(out) + 1L]] <- data.frame(
      path = paste0(entries$name[k], "/", sub$path), blob = sub$blob, stringsAsFactors = FALSE
    )
  }
  do.call(rbind, out)
}

# Binary git tree object -> entries (`<mode> <name>\0<raw id>` each).
parse_tree_object <- function(bytes, id_len) {
  name <- character()
  type <- character()
  oid <- character()
  pos <- 1L
  n <- length(bytes)
  while (pos <= n) {
    nul <- pos
    while (bytes[nul] != as.raw(0L)) nul <- nul + 1L
    head <- rawToChar(bytes[pos:(nul - 1L)])
    sp <- regexpr(" ", head, fixed = TRUE)
    mode <- substr(head, 1L, sp - 1L)
    nm <- substring(head, sp + 1L)
    Encoding(nm) <- "UTF-8"
    raw_id <- bytes[(nul + 1L):(nul + id_len)]
    pos <- nul + id_len + 1L
    kind <- if (mode == "40000") "tree" else if (mode %in% c("100644", "100755")) "blob" else NA_character_
    if (is.na(kind)) next  # symlinks and submodules hold no code
    name <- c(name, nm)
    type <- c(type, kind)
    oid <- c(oid, paste(as.character(raw_id), collapse = ""))
  }
  data.frame(name = name, type = type, oid = oid, stringsAsFactors = FALSE)
}

# Raw contents of the objects `ids`, one `git cat-file --batch` call.
git_cat_batch <- function(path, ids) {
  if (!git_available()) stop("`git` was not found on the PATH.", call. = FALSE)
  out <- tempfile("git-batch-")
  on.exit(unlink(out), add = TRUE)
  status <- suppressWarnings(system2("git", c("-C", shQuote(path), "cat-file", "--batch"),
                                     input = ids, stdout = out, stderr = FALSE))
  if (!identical(as.integer(status), 0L)) stop("git cat-file --batch failed in ", path, call. = FALSE)
  raw <- readBin(out, "raw", file.info(out)$size)
  res <- list()
  nl <- as.raw(10L)
  pos <- 1L
  while (pos <= length(raw)) {
    end <- pos
    while (raw[end] != nl) end <- end + 1L
    header <- strsplit(rawToChar(raw[pos:(end - 1L)]), " ", fixed = TRUE)[[1]]
    pos <- end + 1L
    if (length(header) < 3 || header[2] == "missing") next
    size <- as.integer(header[3])
    res[[header[1]]] <- if (size > 0) raw[pos:(pos + size - 1L)] else raw()
    pos <- pos + size + 1L  # content plus its trailing newline
  }
  res
}

# Read the blobs `ids` with one `git cat-file --batch` call into `into`
# (blob id -> lines, UTF-8; `NULL` content for a blob that is not text).
git_read_blobs <- function(path, ids, into) {
  if (!length(ids)) return(invisible())
  objects <- git_cat_batch(path, ids)
  for (id in names(objects)) assign(id, blob_lines(objects[[id]]), envir = into)
  invisible()
}

# Bytes of a text file -> lines, split like `readLines()` (\n, \r\n or \r).
blob_lines <- function(bytes) {
  if (!length(bytes)) return(character())
  if (any(bytes == as.raw(0L))) return(NULL)
  text <- rawToChar(bytes)
  Encoding(text) <- "UTF-8"
  lines <- strsplit(text, "\r\n|\n|\r")[[1]]
  lines
}

# Lines of the code files (and `extra` files) at `commit`, named by path.
git_tree_texts <- function(path, commit, extra = character()) {
  cache <- new.env()
  for (k in c("files", "dirs", "blobs")) assign(k, new.env(hash = TRUE), envir = cache)
  sha <- git_run(path, c("rev-parse", "--verify", paste0(commit, "^{commit}")))[1]
  git_commit_files(path, sha, extra, cache)
  tree <- cache$files[[sha]]
  git_read_blobs(path, unique(tree$blob), cache$blobs)
  texts <- list()
  for (i in seq_len(nrow(tree))) {
    lines <- cache$blobs[[tree$blob[i]]]
    if (!is.null(lines)) texts[[tree$path[i]]] <- lines
  }
  texts
}

#' Who last changed the hash of each item
#'
#' The author of an item is the author of its *introducing commit*: the most
#' recent commit (topological order) whose version of the item has the current
#' hash while none of its parents' versions has it. Reformatting and comment
#' edits do not change a hash, so they never count; a merge commit is credited
#' only when it itself produced the hash (e.g. a conflict resolution). Versions
#' are hashed from the whole code tree at each commit. An item whose
#' working-tree hash differs from `HEAD` has uncommitted changes and gets no
#' author. Outside git, or in a repo without commits, all fields are `NA`.
#'
#' @param path Root folder of the project (may be below the repo root).
#' @param items The `items` data frame of `read_source()`.
#' @return A data frame with `id`, `author_name`, `author_email`, `commit`.
#' @noRd
last_authors <- function(path, items) {
  out <- data.frame(
    id = items$id,
    author_name = rep(NA_character_, nrow(items)),
    author_email = rep(NA_character_, nrow(items)),
    commit = rep(NA_character_, nrow(items)),
    stringsAsFactors = FALSE
  )
  head <- git_head(path)
  if (is.na(head) || !nrow(items)) return(out)

  log <- git_run(path, c("-c", "log.showSignature=false", "log", "--topo-order", "--format=%H%x1f%an%x1f%ae%x1f%P", head))
  parts <- strsplit(log, "\x1f", fixed = TRUE)
  shas <- vapply(parts, `[`, character(1), 1)
  field <- function(i) vapply(parts, function(p) if (length(p) >= i) p[i] else "", character(1))
  email <- field(3)
  meta <- list(name = field(2), email = ifelse(nzchar(email), email, NA_character_),
               parents = strsplit(field(4), " ", fixed = TRUE))
  idx <- function(sha) match(sha, shas)

  extra <- items$file[items$kind == "file"]
  cache <- new.env()
  cache$order <- shas  # lets each bulk git read cover the next commits of the log
  has <- function(sha, id, hash) {
    h <- git_item_hashes(path, sha, extra, cache)
    id %in% names(h) && identical(h[[id]], hash)
  }

  for (i in seq_len(nrow(items))) {
    id <- items$id[i]
    hash <- items$hash[i]
    if (!has(head, id, hash)) next
    seen <- character()
    found <- integer()
    todo <- head
    while (length(todo)) {
      sha <- todo[1]
      todo <- todo[-1]
      if (sha %in% seen) next
      seen <- c(seen, sha)
      with_hash <- Filter(function(p) has(p, id, hash), meta$parents[[idx(sha)]])
      if (length(with_hash)) todo <- c(todo, with_hash) else found <- c(found, idx(sha))
    }
    k <- min(found)
    out$author_name[i] <- meta$name[k]
    out$author_email[i] <- meta$email[k]
    out$commit[i] <- shas[k]
  }
  out
}
