#' Rescale a numeric vector to the unit interval
#'
#' Helper used inside [build_features()]. It is not a target itself.
#'
#' @param x A numeric vector.
#' @return `x` rescaled to `[0, 1]`.
#' @keywords internal
rescale01 <- function(x) {
  rng <- range(x, na.rm = TRUE)
  (x - rng[1]) / (rng[2] - rng[1])
}
