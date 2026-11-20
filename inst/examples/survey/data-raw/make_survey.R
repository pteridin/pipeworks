# Generates data/survey_2026.csv: a small, fake customer survey export.
# Run from the project root: Rscript data-raw/make_survey.R
#
# The data is deliberately messy so clean_survey() has something to do:
# test submissions, duplicate respondent IDs and legacy region codes.

set.seed(2026)
n <- 240

region_codes <- c("N", "NE", "S", "E", "W")
channel <- sample(c("web", "phone", "store"), n, replace = TRUE, prob = c(.6, .25, .15))
region <- sample(region_codes, n, replace = TRUE, prob = c(.25, .1, .25, .2, .2))
age <- sample(18:79, n, replace = TRUE)
tenure_years <- round(rexp(n, rate = 1 / 4), 1)

region_effect <- c(N = 0.4, NE = 0.4, S = -0.3, E = 0, W = 0.2)[region]
channel_effect <- c(web = 0, phone = -0.6, store = 0.5)[channel]
score <- 6 + region_effect + channel_effect + 0.08 * tenure_years - 0.01 * (age - 45) + rnorm(n, sd = 1.2)
score <- pmin(10, pmax(0, round(score)))

survey <- data.frame(
  respondent_id = sprintf("R%04d", seq_len(n)),
  submitted_at = format(as.POSIXct("2026-03-01", tz = "UTC") + sort(runif(n, 0, 60 * 60 * 24 * 60)), "%Y-%m-%dT%H:%M:%SZ"),
  region = region,
  channel = channel,
  age = age,
  tenure_years = tenure_years,
  score = score,
  is_test = FALSE
)

# Duplicate submissions (same respondent submitted twice).
dupes <- survey[sample(n, 12), ]
# Test submissions from the survey team.
tests <- survey[1:6, ]
tests$respondent_id <- sprintf("TEST%02d", 1:6)
tests$is_test <- TRUE

survey <- rbind(survey, dupes, tests)
survey <- survey[order(survey$submitted_at), ]

write.csv(survey, "data/survey_2026.csv", row.names = FALSE)
