# 05_drop_ineligible_pairs.R
#
# Purpose: Remove two complete pairs whose LDP publications are ineligible,
#          with no suitable replacement LDP publication available.
#
#   Pairs dropped:
#     PAIR006  (McGill, 2024) — LDP pub was not a primary research article
#     PAIR020  (UBC, 2024)   — LDP pub was a conference abstract
#
# Inputs:  data/processed_data/rater_publications.csv
#          data/processed_data/private/rater_key.csv
# Outputs: data/processed_data/rater_publications_pairs_dropped.csv
#          data/processed_data/private/rater_key_pairs_dropped.csv
#
# Author: Jason Pither, with help from Claude (Sonnet 4.6)
# Created: 2026-04-13

library(dplyr)
library(readr)
library(here)

# -----------------------------------------------------------------------------
# Load files
# -----------------------------------------------------------------------------

rater_pub <- readr::read_csv(
  here::here("data", "processed_data", "rater_publications.csv"),
  show_col_types = FALSE
)

rater_key <- readr::read_csv(
  here::here("data", "processed_data", "private", "rater_key.csv"),
  show_col_types = FALSE
)

cat(sprintf("Loaded rater_publications : %d rows\n", nrow(rater_pub)))
cat(sprintf("Loaded rater_key          : %d rows\n", nrow(rater_key)))

# -----------------------------------------------------------------------------
# Drop ineligible pairs
# -----------------------------------------------------------------------------

pairs_to_drop  <- c("PAIR006", "PAIR020")
pub_ids_to_drop <- rater_key$pub_id[rater_key$pair_id %in% pairs_to_drop]

cat(sprintf("\nDropping %d pair(s) (%d publications):\n",
            length(pairs_to_drop), length(pub_ids_to_drop)))

rater_key %>%
  dplyr::filter(pair_id %in% pairs_to_drop) %>%
  dplyr::select(pub_id, pair_id, group, institution_name, publication_year, reason = title) %>%
  { cat(capture.output(print(
      dplyr::select(dplyr::filter(rater_key, pair_id %in% pairs_to_drop),
                    pub_id, pair_id, group, institution_name, publication_year)
    ), sep = "\n")); . }

rater_key <- rater_key %>% dplyr::filter(!pair_id  %in% pairs_to_drop)
rater_pub  <- rater_pub  %>% dplyr::filter(!pub_id %in% pub_ids_to_drop)

n_pairs_remaining <- nrow(rater_key) / 2
cat(sprintf("\nRows remaining — rater_key: %d (%d pairs) | rater_publications: %d\n",
            nrow(rater_key), n_pairs_remaining, nrow(rater_pub)))

cat("\nPairs by institution (LDP side):\n")
rater_key %>%
  dplyr::filter(group == "LDP") %>%
  dplyr::count(institution_name, name = "n_pairs") %>%
  dplyr::arrange(dplyr::desc(n_pairs)) %>%
  print()

# -----------------------------------------------------------------------------
# Write outputs (originals are not overwritten)
# -----------------------------------------------------------------------------

readr::write_csv(rater_pub,
  here::here("data", "processed_data", "rater_publications_pairs_dropped.csv"))

readr::write_csv(rater_key,
  here::here("data", "processed_data", "private", "rater_key_pairs_dropped.csv"))

cat("\nOutputs written:\n")
cat("  data/processed_data/rater_publications_pairs_dropped.csv\n")
cat("  data/processed_data/private/rater_key_pairs_dropped.csv\n")
