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
# Inputs:  data/raw_data/ldp_student_names_2020-2022.csv
#          data/raw_data/LDP_author_publications.csv
#          data/raw_data/institution_names.csv
# Outputs: data/raw_data/ldp_exclusion_names.csv
#          data/raw_data/ldp_n_target.csv
#          data/raw_data/ldp_eee_field_ids.rds
#
# Author: Jason Pither, with help from Claude (Sonnet 4.6)
# Updated: 2026-03-22

library(openalexR)
library(dplyr)
library(readr)
library(here)
library(stringr)
library(purrr)
library(tidyr)

# -----------------------------------------------------------------------------
# Configuration (must match 02_get_comparator_authors.R)
# -----------------------------------------------------------------------------

options(openalexR.mailto = "jason.pither@ubc.ca")
mailto <- "jason.pither@ubc.ca"

api_delay            <- 0.15
field_freq_threshold <- 0.10   # include fields present in ≥10% of LDP works
ldp_batch_size       <- 100    # work IDs per batch for topic fetch

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
  here::here("data", "raw_data", "ldp_student_names_2020-2022.csv"), show_col_types = FALSE
)

LDP_pubs_raw <- readr::read_csv(
  here::here("data", "raw_data", "LDP_author_publications.csv"), show_col_types = FALSE
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
  here::here("data", "raw_data", "ldp_exclusion_names.csv")
)
cat("Saved: data/raw_data/ldp_exclusion_names.csv\n")

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

cat(sprintf("Fetching topics for %d LDP works in batches of %d\n",
            length(ldp_ids_short), ldp_batch_size))

n_batches      <- ceiling(length(ldp_ids_short) / ldp_batch_size)
ldp_topic_list <- vector("list", n_batches)

for (b in seq_len(n_batches)) {
  idx    <- ((b - 1) * ldp_batch_size + 1) : min(b * ldp_batch_size, length(ldp_ids_short))
  id_str <- paste(ldp_ids_short[idx], collapse = "|")

  query_url <- paste0(
    "https://api.openalex.org/works",
    "?filter=ids.openalex:", id_str,
    "&select=id,topics",
    "&per-page=200",
    "&mailto=", mailto
  )

  raw <- tryCatch(
    oa_request(query_url = query_url),
    error = function(e) { cat("  Batch", b, "error:", conditionMessage(e), "\n"); list() }
  )

  if (length(raw) > 0)
    ldp_topic_list[[b]] <- oa2df(raw, entity = "works")
  Sys.sleep(api_delay)
}

ldp_topics_df <- dplyr::bind_rows(purrr::compact(ldp_topic_list))

# Extract field-level frequency from LDP topics.
# NOTE: if this unnest fails, inspect ldp_topics_df$topics[[1]] to confirm
# column names — they vary slightly across openalexR versions.
# topics tibble columns: i, score, id, display_name, type
# type values: "topic", "subfield", "field", "domain"
field_counts <- ldp_topics_df %>%
  dplyr::select(topics) %>%
  tidyr::unnest(topics) %>%
  dplyr::filter(type == "field") %>%
  dplyr::count(id, display_name, sort = TRUE) %>%
  dplyr::rename(field_id = id, field_display_name = display_name) %>%
  dplyr::mutate(pct = n / nrow(ldp_topics_df))

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
