# Text layer for writing code back to files: bytes in, bytes out, with the
# file's line endings, final newline and parse-data columns preserved.

# Lines of a file plus what is needed to write it back unchanged.
read_text <- function(file) {
  size <- file.size(file)
  raw <- readBin(file, "raw", n = size)
  text <- rawToChar(raw)
  Encoding(text) <- "UTF-8"
  # The first line break decides.
  first_lf <- regexpr("\n", text, fixed = TRUE)
  eol <- if (first_lf > 1L && substr(text, first_lf - 1L, first_lf - 1L) == "\r") "\r\n" else "\n"
  final_nl <- nzchar(text) && substr(text, nchar(text), nchar(text)) == "\n"
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  lines <- sub("\r$", "", lines)
  list(lines = lines, eol = eol, final_nl = final_nl)
}

# Atomic write: temp file next to the target, then rename.
write_text <- function(file, txt) {
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  body <- paste(txt$lines, collapse = txt$eol)
  if (length(txt$lines) && isTRUE(txt$final_nl)) body <- paste0(body, txt$eol)
  tmp <- tempfile(".pw-", tmpdir = dirname(file))
  on.exit(unlink(tmp), add = TRUE)
  writeBin(charToRaw(enc2utf8(body)), tmp)
  if (!file.rename(tmp, file)) stop("Could not write ", file, call. = FALSE)
  invisible(file)
}

# Character index in `line` of parse-data column `col`. R counts characters,
# and a tab advances to the next multiple of 8. Columns past the end continue
# one per character; a column inside a tab maps to the tab.
pd_char <- function(line, col) {
  if (col <= 0L) return(0L)
  chars <- strsplit(line, "", fixed = TRUE)[[1]]
  end <- 0L
  for (i in seq_along(chars)) {
    end <- if (chars[i] == "\t") (end %/% 8L + 1L) * 8L else end + 1L
    if (end >= col) return(i)
  }
  length(chars) + as.integer(col - end)
}

md5_lines <- function(lines) md5_text(paste(lines, collapse = "\n"))

# Replace inclusive ranges given in parse-data columns. `col2 == col1 - 1` on
# one line inserts before `col1`. Applied bottom-up.
splice_lines <- function(lines, edits) {
  if (!nrow(edits)) return(lines)
  edits <- edits[order(edits$line1, edits$col1), , drop = FALSE]
  n <- nrow(edits)
  if (n > 1L) {
    after_end <- edits$line1[-1] > edits$line2[-n] |
      (edits$line1[-1] == edits$line2[-n] & edits$col1[-1] > edits$col2[-n])
    if (!all(after_end)) stop("Overlapping edits", call. = FALSE)
  }
  for (i in rev(seq_len(n))) {
    e <- edits[i, ]
    l1 <- as.integer(e$line1)
    l2 <- as.integer(e$line2)
    c1 <- pd_char(lines[l1], as.integer(e$col1))
    c2 <- if (l1 == l2 && e$col2 == e$col1 - 1L) c1 - 1L else pd_char(lines[l2], as.integer(e$col2))
    new <- paste0(
      substr(lines[l1], 1L, c1 - 1L), e$text,
      substr(lines[l2], c2 + 1L, nchar(lines[l2]))
    )
    new <- strsplit(paste0(new, "\n"), "\n", fixed = TRUE)[[1]]
    lines <- c(lines[seq_len(l1 - 1L)], new, lines[seq_len(length(lines) - l2) + l2])
  }
  lines
}
