# 01_get_ldp_targets.R
#
# Purpose: Derives three artifacts from private LDP data that are consumed by
#          02_get_comparator_authors.R.
#
#   1. ldp_exclusion_names.csv  — full list of LDP student names (firstname_lastname)
#      to exclude from the comparator pool. Built from ldp_student_names_2020-2022.csv
#      so that ALL enrolled students are excluded, not just those with found publications.
#
#   2. ldp_n_target.csv         — target sample size per institution (N_target):
#      number of distinct LDP authors with ≥1 EEE publication after keyword filtering.
#      Built from LDP_author_publications.csv after applying the same non-EEE keyword
#      filter used in 02_get_comparator_authors.R.
#
#   3. ldp_eee_field_ids.rds    — character vector of OpenAlex field IDs that appear
#      in ≥10% of keyword-filtered LDP publications. Used in Phase 1 of
#      02_get_comparator_authors.R to restrict the institution-level works query to
#      EEE-relevant fields.
#
# Inputs:  data/processed_data/private/ldp_student_names_2020-2022.csv
#          data/processed_data/private/LDP_author_publications.csv
#          data/raw_data/institution_names.csv
# Outputs: data/processed_data/private/ldp_exclusion_names.csv
#          data/raw_data/ldp_n_target.csv
#          data/raw_data/ldp_eee_field_ids.rds
#
# Author: Jason Pither, with help from Claude (Sonnet 4.6)
# Updated: 2026-03-29

library(dplyr)
library(readr)
library(here)
library(stringr)
library(purrr)
library(tidyr)
library(httr)
library(jsonlite)

# -----------------------------------------------------------------------------
# Configuration (must match 02_get_comparator_authors.R)
# -----------------------------------------------------------------------------

options(openalexR.mailto = "jason.pither@ubc.ca")
mailto <- "jason.pither@ubc.ca"

api_delay            <- 0.5    # conservative; avoids 429s from the polite pool
field_freq_threshold <- 0.10   # include fields present in ≥10% of LDP works

# -----------------------------------------------------------------------------
# Non-EEE keyword patterns (verbatim from thesis_classification_model_training.qmd)
# Must be kept in sync with 02_get_comparator_authors.R.
# Applied to lowercased publication titles to identify off-topic papers.
# N_target is derived from LDP publications AFTER this filter so it reflects
# LDP authors with ≥1 EEE publication — the meaningful unit of comparison.
# -----------------------------------------------------------------------------

general_nonEEE_patterns <- c(
  r"(\bvitamin\b)",        # human/clinical nutrition; rarely relevant to EEE
  r"(\bsoftware\b)",       # computer science / engineering
  r"(\bbusiness\b)",       # business / management
  r"(\bsocial justice\b)", # social sciences
  r"(\bnarrative)",        # narrative/narratives: qualitative social science
  r"(\beducat)",           # education / educational (env. education is soc sci not EEE)
  r"(\blanguage\b)",       # linguistics / qualitative research
  r"(\bliteracy\b)",       # qualitative research
  r"(\bsexist\b)",         # social science
  r"(\blinguist\b)",       # social science
  r"(\bwriting\b)",        # social science
  r"(\bgender\b)",         # social science
  r"(\bpediat\b)",         # health science
  r"(\bgastro\b)",         # health science
  r"(\bglycem\b)",         # health science
  r"(\bpatient\b)",        # health science
  r"(\bserum\b)",          # health science
  r"(\bcase report\b)",    # health science
  r"(\burethr\b)",         # health science
  r"(\bpharma\b)",         # health science
  r"(\bcholine\b)",        # health science
  r"(\bneuro\b)",          # health science
  r"(\bwaste management\b)",
  r"(\bcheese\b)",         # food science
  r"(\bpsychol\b)",        # health science
  r"(\bmood\b)",           # health science
  r"(\bmoral\b)",          # social science
  r"(\bperceive\b)",       # social science
  r"(\bsocioeconomic\b)",  # social science
  r"(\bdiscourse\b)",      # social science
  r"(\bhuman safety\b)",   # social science
  r"(\bislamic\b)",        # social science
  r"(\bcovid\b)",          # health science
  r"(\breply to\b)",       # commentary
  r"(\bmatlab\b)",         # math
  r"(\bkinetochore\b)",
  r"(\bplasticizer\b)",
  r"(\bmotiv\b)",          # motivation: qualitative research
  r"(\bfairness\b)",       # social science
  r"(\bpolitical\b)"       # political science (incl. political ecology, which is soc sci)
)

geology_patterns <- c(
  r"(\btectonic)", r"(\bseismic\b)", r"(\bstratigraph)",
  r"(\blitholog)", r"(\bgeomorph)", r"(\bsedimentary\b)",
  r"(\bmetamorphic\b)", r"(\bvolcan)", r"(\bmagma\b)",
  r"(\bigneous\b)", r"(\bgeochemistry\b)", r"(\bgeochronolog)",
  r"(\bhydrogeolog)", r"(\bgeophysics\b)", r"(\bpaleontolog)",
  r"(\bore deposit)", r"(\bultramafic\b)",
  r"(\brare earth\b)",  # rare earth element mining/geochemistry
  r"(\blithium\b)",     # lithium mineral resources
  r"(\bcoal\b)"         # coal geology / combustion byproducts
)

env_soc_patterns <- c(
  r"(\benvironmental policy\b)", r"(\benvironmental governance\b)",
  r"(\benvironmental justice\b)", r"(\benvironmental management\b)",
  r"(\benvironmental law\b)", r"(\bclimate policy\b)",
  r"(\bclimate governance\b)", r"(\benergy policy\b)",
  r"(\bgreen economy\b)", r"(\bcarbon tax\b)"
)

all_noneee_patterns <- c(general_nonEEE_patterns, geology_patterns, env_soc_patterns)
noneee_regex        <- paste(all_noneee_patterns, collapse = "|")

is_noneee_title <- function(titles) {
  stringr::str_detect(
    tolower(dplyr::coalesce(as.character(titles), "")),
    noneee_regex
  )
}

# -----------------------------------------------------------------------------
# Load supporting data
# -----------------------------------------------------------------------------

institution_names <- readr::read_csv(
  here::here("data", "raw_data", "institution_names.csv"), show_col_types = FALSE
)

ldp_student_names <- readr::read_csv(
  here::here("data", "processed_data", "private", "ldp_student_names_2020-2022.csv"), show_col_types = FALSE
)

LDP_pubs_raw <- readr::read_csv(
  here::here("data", "processed_data", "private", "LDP_author_publications.csv"), show_col_types = FALSE
)

# -----------------------------------------------------------------------------
# Artifact 1: ldp_exclusion_names.csv
#
# Full list of enrolled LDP student names in firstname_lastname format.
# Derived from ldp_student_names_2020-2022.csv (all enrolled students) rather
# than LDP_author_publications.csv (only students with found publications) so
# no LDP participant can accidentally appear in the comparator pool.
# -----------------------------------------------------------------------------

ldp_exclusion_names <- ldp_student_names %>%
  dplyr::mutate(
    firstname_lastname = paste(Train_First_Name, Train_Last_Name, sep = " ")
  ) %>%
  dplyr::distinct(firstname_lastname)

cat(sprintf("LDP exclusion list: %d unique student names\n", nrow(ldp_exclusion_names)))

readr::write_csv(
  ldp_exclusion_names,
  here::here("data", "processed_data", "private", "ldp_exclusion_names.csv")
)
cat("Saved: data/processed_data/private/ldp_exclusion_names.csv\n")

# -----------------------------------------------------------------------------
# Artifact 2: ldp_n_target.csv
#
# Target sample size per institution: number of distinct LDP authors with ≥1
# EEE publication after keyword filtering.
# -----------------------------------------------------------------------------

n_ldp_before <- nrow(LDP_pubs_raw)
LDP_pubs <- LDP_pubs_raw %>%
  dplyr::filter(!is_noneee_title(title))

cat(sprintf(
  "\nLDP publications: %d total → %d after keyword filter (%d dropped)\n",
  n_ldp_before, nrow(LDP_pubs), n_ldp_before - nrow(LDP_pubs)
))

ldp_n_target <- LDP_pubs %>%
  dplyr::group_by(institution_name) %>%
  dplyr::summarise(N_target = dplyr::n_distinct(searched_name), .groups = "drop")

cat("\nTarget sample sizes by institution:\n")
print(ldp_n_target)

readr::write_csv(
  ldp_n_target,
  here::here("data", "raw_data", "ldp_n_target.csv")
)
cat("Saved: data/raw_data/ldp_n_target.csv\n")

# -----------------------------------------------------------------------------
# Artifact 3: ldp_eee_field_ids.rds
#
# OpenAlex field IDs appearing in ≥field_freq_threshold of keyword-filtered
# LDP publications. Derived by batch-fetching topics for all LDP work IDs.
# -----------------------------------------------------------------------------

cat("\n--- Fetching topics for LDP publications ---\n")

ldp_ids       <- unique(na.omit(LDP_pubs$id))
ldp_ids_short <- unique(na.omit(stringr::str_extract(ldp_ids, "W\\d+")))

cat(sprintf("Fetching topics for %d LDP works (one request per work)\n",
            length(ldp_ids_short)))

ldp_topic_list <- vector("list", length(ldp_ids_short))

# Zero-row typed prototype ensures map_dfr always returns the expected schema
# even when a work has no topic data (avoids 0-column tibble).
topic_proto <- tibble::tibble(
  work_id            = character(),
  field_id           = character(),
  field_display_name = character()
)

# Fetch each work individually via /works/{id}?select=id,topics.
# The multi-ID filter query (ids.openalex:W1|W2|...) triggers HTTP 429 from
# OpenAlex even at short URL lengths; direct per-work lookups are reliable.
for (i in seq_along(ldp_ids_short)) {
  wid <- ldp_ids_short[i]
  url <- paste0(
    "https://api.openalex.org/works/", wid,
    "?select=id,topics",
    "&mailto=", mailto
  )

  # Retry up to 3 times on HTTP 429, doubling the wait each time.
  max_retries <- 3
  retry_wait  <- 10
  resp        <- NULL

  for (attempt in seq_len(max_retries)) {
    resp <- tryCatch(
      httr::GET(url),
      error = function(e) { cat("  Work", wid, "HTTP error:", conditionMessage(e), "\n"); NULL }
    )
    if (is.null(resp)) break
    if (httr::status_code(resp) != 429) break
    wait_sec <- retry_wait * 2^(attempt - 1)
    cat(sprintf("  Work %s: HTTP 429 — waiting %ds before retry %d/%d\n",
                wid, wait_sec, attempt, max_retries))
    Sys.sleep(wait_sec)
  }

  if (!is.null(resp) && httr::status_code(resp) == 200) {
    w <- jsonlite::fromJSON(
      httr::content(resp, as = "text", encoding = "UTF-8"),
      simplifyVector = FALSE
    )
    topics <- w$topics
    if (!is.null(topics) && length(topics) > 0) {
      ldp_topic_list[[i]] <- purrr::map_dfr(topics, function(t) {
        field <- t$field
        if (is.null(field)) return(topic_proto)
        tibble::tibble(
          work_id            = wid,
          field_id           = field[["id"]],
          field_display_name = field[["display_name"]]
        )
      })
    }
  } else {
    cat(sprintf("  Work %s: HTTP %s after %d attempt(s) — skipping\n",
                wid, if (is.null(resp)) "error" else httr::status_code(resp), attempt))
  }

  if (i %% 10 == 0)
    cat(sprintf("  ... %d / %d works done\n", i, length(ldp_ids_short)))

  Sys.sleep(api_delay)
}

ldp_topics_df <- dplyr::bind_rows(purrr::compact(ldp_topic_list))

if (nrow(ldp_topics_df) == 0) {
  cat("\nWARNING: No field data retrieved from topics.\n")
  cat("         Check batch output above for HTTP errors.\n")
  cat("         eee_field_ids will be empty; review API structure and re-run.\n")
  field_counts  <- tibble::tibble(
    field_id           = character(),
    field_display_name = character(),
    n                  = integer(),
    pct                = numeric()
  )
} else {
  # Count distinct works per field. Using distinct(work_id, field_id) first
  # ensures a work that contributes multiple topics from the same field is
  # counted only once toward that field's frequency.
  field_counts <- ldp_topics_df %>%
    dplyr::distinct(work_id, field_id, field_display_name) %>%
    dplyr::count(field_id, field_display_name, sort = TRUE) %>%
    dplyr::mutate(pct = n / length(ldp_ids_short))
}

cat("\nField distribution in LDP publications:\n")
print(field_counts)

eee_field_ids <- field_counts %>%
  dplyr::filter(pct >= field_freq_threshold) %>%
  dplyr::pull(field_id)

cat(sprintf(
  "\nEEE fields selected (pct >= %.0f%%):\n%s\n",
  field_freq_threshold * 100,
  paste(eee_field_ids, collapse = "\n")
))

saveRDS(eee_field_ids, here::here("data", "raw_data", "ldp_eee_field_ids.rds"))
cat("Saved: data/raw_data/ldp_eee_field_ids.rds\n")

cat("\n=== COMPLETE ===\n")
cat("Run scripts/02_get_comparator_authors.R next.\n")
