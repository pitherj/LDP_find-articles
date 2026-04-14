# 08_replace_inaccessible.R
#
# Purpose: Replace one comparator publication that is inaccessible to raters
#          (journal not available via UBC library subscription).
#
#   Flagged record:
#     N3V3VY  PAIR017  McGill  2022  — journal not accessible at UBC
#     (Kirsten Crandall; randomly selected in script 07 as replacement for
#      OZ2HY7, but subsequently found to be inaccessible)
#
#   Phase A — prints all eligible replacement candidates for transparency.
#             Corresponding-author conflicts are flagged automatically.
#             Read-only; safe to re-run.
#
#   Phase B — randomly selects one eligible (non-conflicted) candidate using
#             replacement_seed_v2 and writes updated output files.
#
# Inputs:  data/processed_data/rater_publications_final.csv
#          data/processed_data/private/rater_key_final.csv
#          data/processed_data/comparator_publications_filtered_with_ca.csv
#          data/processed_data/private/LDP_publications_filtered_with_ca.csv
# Outputs: data/processed_data/rater_publications_final_v2.csv
#          data/processed_data/private/rater_key_final_v2.csv
#
# Author: Jason Pither, with help from Claude (Sonnet 4.6)
# Created: 2026-04-13

library(dplyr)
library(readr)
library(here)
library(stringr)

# Supplementary seed for this correction round.
# Document alongside rng_seed = 20260329 (script 04) and
# replacement_seed = 20260413 (script 07).
replacement_seed_v2 <- 20260414
set.seed(replacement_seed_v2)
cat(sprintf("Replacement seed v2: %d\n", replacement_seed_v2))

# -----------------------------------------------------------------------------
# Load files
# -----------------------------------------------------------------------------

rater_pub <- readr::read_csv(
  here::here("data", "processed_data", "rater_publications_final.csv"),
  show_col_types = FALSE
)

rater_key <- readr::read_csv(
  here::here("data", "processed_data", "private", "rater_key_final.csv"),
  show_col_types = FALSE
)

comp_pool <- readr::read_csv(
  here::here("data", "processed_data",
             "comparator_publications_filtered_with_ca.csv"),
  show_col_types = FALSE
)

ldp_pool <- readr::read_csv(
  here::here("data", "processed_data", "private",
             "LDP_publications_filtered_with_ca.csv"),
  show_col_types = FALSE
)

cat(sprintf("Loaded rater_publications_final : %d rows\n", nrow(rater_pub)))
cat(sprintf("Loaded rater_key_final          : %d rows\n", nrow(rater_key)))
cat(sprintf("Loaded comparator pool (with CA): %d rows\n", nrow(comp_pool)))
cat(sprintf("Loaded LDP pool (with CA)       : %d rows\n", nrow(ldp_pool)))

# Record which pub_ids are in this input rater set so the final output can
# carry the `original` flag forward correctly.
original_pub_ids <- rater_pub$pub_id[rater_pub$original == "yes"]

# -----------------------------------------------------------------------------
# Helper: generate N unique random 6-character alphanumeric codes not already
# present in the current rater_key.
# -----------------------------------------------------------------------------

make_pub_ids <- function(n, existing = rater_key$pub_id) {
  chars <- c(LETTERS, as.character(0:9))
  codes <- character(0)
  while (length(codes) < n) {
    candidate <- paste(sample(chars, 6, replace = TRUE), collapse = "")
    if (!candidate %in% c(existing, codes)) codes <- c(codes, candidate)
  }
  codes
}

# -----------------------------------------------------------------------------
# Define the flagged record
# -----------------------------------------------------------------------------

flagged <- tibble::tribble(
  ~pub_id,   ~pair_id,   ~institution_name,   ~publication_year, ~reason,
  "N3V3VY",  "PAIR017",  "McGill University",  2022,  "journal not accessible at UBC"
)

# Authors already in use — candidates must not appear in this list
used_names <- unique(rater_key$searched_name)

# -----------------------------------------------------------------------------
# Build the set of corresponding author OpenAlex IDs already in the rater set
# -----------------------------------------------------------------------------

rater_ca_ids <-
  dplyr::bind_rows(
    rater_key %>%
      dplyr::select(openalex_id) %>%
      dplyr::inner_join(
        ldp_pool  %>% dplyr::select(id, ca_openalex_ids),
        by = c("openalex_id" = "id")
      ),
    rater_key %>%
      dplyr::select(openalex_id) %>%
      dplyr::inner_join(
        comp_pool %>% dplyr::select(id, ca_openalex_ids),
        by = c("openalex_id" = "id")
      )
  ) %>%
  dplyr::pull(ca_openalex_ids) %>%
  na.omit() %>%
  stringr::str_split(" \\| ") %>%
  unlist() %>%
  unique()

cat(sprintf("\nCorresponding author IDs already in rater set: %d\n",
            length(rater_ca_ids)))

# =============================================================================
# PHASE A — Print candidates for review (read-only)
# =============================================================================

cat("\n\n=== PHASE A: Candidate replacements (for transparency) ===\n")
cat("Candidates with a corresponding-author conflict are marked [CA CONFLICT].\n")
cat("Phase B will randomly select from eligible (non-conflicted) candidates.\n\n")

for (i in seq_len(nrow(flagged))) {

  slot <- flagged[i, ]

  candidates <- comp_pool %>%
    dplyr::filter(
      institution_name == slot$institution_name,
      publication_year == slot$publication_year,
      !searched_name   %in% used_names
    ) %>%
    dplyr::select(searched_name, publication_year, title, doi, id,
                  ca_display_names, ca_openalex_ids) %>%
    dplyr::arrange(searched_name)

  cat(sprintf("Slot %d | %s | %s | %d | Reason: %s\n",
              i, slot$pub_id, slot$institution_name,
              slot$publication_year, slot$reason))

  if (nrow(candidates) == 0) {
    cat("  *** NO CANDIDATES FOUND — check pool manually ***\n\n")
  } else {
    cat(sprintf("  %d candidate(s):\n", nrow(candidates)))
    for (j in seq_len(nrow(candidates))) {

      cand_ca_ids <- if (is.na(candidates$ca_openalex_ids[j])) character(0) else
        stringr::str_split(candidates$ca_openalex_ids[j], " \\| ")[[1]]
      ca_conflict  <- length(intersect(cand_ca_ids, rater_ca_ids)) > 0
      conflict_flag <- if (ca_conflict) "  *** [CA CONFLICT] ***" else ""

      cat(sprintf(
        "  [%d] %s%s\n      Title: %s\n      DOI:   %s\n      OA ID: %s\n      CA(s): %s\n\n",
        j,
        candidates$searched_name[j],
        conflict_flag,
        substr(candidates$title[j], 1, 90),
        candidates$doi[j],
        candidates$id[j],
        candidates$ca_display_names[j] %||% "not available in OpenAlex"
      ))
    }
  }
}

# =============================================================================
# PHASE B — Randomly select and apply replacement
# =============================================================================

cat("\n\n=== PHASE B: Randomly selecting and applying replacement ===\n")
cat(sprintf("(using replacement_seed_v2 = %d)\n\n", replacement_seed_v2))

new_ids    <- make_pub_ids(nrow(flagged))
new_id_idx <- 0L

for (i in seq_len(nrow(flagged))) {

  slot       <- flagged[i, ]
  old_pub_id <- slot$pub_id
  pair_id    <- slot$pair_id

  # Eligible candidates: same filters as Phase A, CA conflicts excluded
  eligible <- comp_pool %>%
    dplyr::filter(
      institution_name == slot$institution_name,
      publication_year == slot$publication_year,
      !searched_name   %in% used_names
    ) %>%
    dplyr::rowwise() %>%
    dplyr::filter({
      cand_ca_ids <- if (is.na(ca_openalex_ids)) character(0) else
        stringr::str_split(ca_openalex_ids, " \\| ")[[1]]
      length(intersect(cand_ca_ids, rater_ca_ids)) == 0
    }) %>%
    dplyr::ungroup()

  if (nrow(eligible) == 0) {
    cat(sprintf("Slot %s: no eligible candidates — dropping pair %s entirely.\n\n",
                old_pub_id, pair_id))
    partner_pub_id <- rater_key$pub_id[rater_key$pair_id == pair_id &
                                         rater_key$pub_id != old_pub_id]
    rater_key <- rater_key %>%
      dplyr::filter(!pub_id %in% c(old_pub_id, partner_pub_id))
    rater_pub <- rater_pub %>%
      dplyr::filter(!pub_id %in% c(old_pub_id, partner_pub_id))
    next
  }

  # Random draw
  new_comp   <- eligible %>% dplyr::slice_sample(n = 1)
  new_id_idx <- new_id_idx + 1L
  new_pub_id <- new_ids[new_id_idx]

  oa_url <- paste0("https://openalex.org/",
                   stringr::str_extract(new_comp$id, "W\\d+"))

  new_key_row <- tibble::tibble(
    pub_id           = new_pub_id,
    pair_id          = pair_id,
    group            = "Comparator",
    searched_name    = new_comp$searched_name,
    institution_name = new_comp$institution_name,
    publication_year = new_comp$publication_year,
    title            = new_comp$title,
    doi              = new_comp$doi,
    openalex_id      = new_comp$id,
    openalex_url     = oa_url
  )

  new_pub_row <- tibble::tibble(
    pub_id           = new_pub_id,
    title            = new_comp$title,
    doi              = new_comp$doi,
    publication_year = new_comp$publication_year,
    openalex_url     = oa_url,
    original         = "no"
  )

  rater_key <- rater_key %>% dplyr::filter(pub_id != old_pub_id)
  rater_pub  <- rater_pub  %>% dplyr::filter(pub_id != old_pub_id)

  rater_key <- dplyr::bind_rows(rater_key, new_key_row)
  rater_pub  <- dplyr::bind_rows(rater_pub,  new_pub_row)

  cat(sprintf("Slot %s (%s): randomly selected '%s'\n      %s\n      new pub_id: %s\n\n",
              old_pub_id, pair_id,
              new_comp$searched_name,
              substr(new_comp$title, 1, 80),
              new_pub_id))
}

# Carry forward `original` column for retained records, re-shuffle row order
rater_pub <- rater_pub %>%
  dplyr::mutate(original = dplyr::if_else(pub_id %in% original_pub_ids,
                                          "yes", original))

set.seed(replacement_seed_v2)
rater_pub <- rater_pub %>% dplyr::slice_sample(prop = 1)

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

n_pairs_final <- nrow(rater_key) / 2
cat(sprintf("=== Final summary ===\n"))
cat(sprintf("Pairs              : %d\n", n_pairs_final))
cat(sprintf("Total publications : %d\n", nrow(rater_pub)))
cat(sprintf("Original records   : %d\n", sum(rater_pub$original == "yes")))
cat(sprintf("Replacement records: %d\n", sum(rater_pub$original == "no")))

cat("\nPairs by institution (LDP side):\n")
rater_key %>%
  dplyr::filter(group == "LDP") %>%
  dplyr::count(institution_name, name = "n_pairs") %>%
  dplyr::arrange(dplyr::desc(n_pairs)) %>%
  print()

# -----------------------------------------------------------------------------
# Write outputs (rater_publications_final and rater_key_final not overwritten)
# -----------------------------------------------------------------------------

readr::write_csv(rater_pub,
  here::here("data", "processed_data", "rater_publications_final_v2.csv"))

readr::write_csv(rater_key,
  here::here("data", "processed_data", "private", "rater_key_final_v2.csv"))

cat("\nOutputs written:\n")
cat("  data/processed_data/rater_publications_final_v2.csv\n")
cat("  data/processed_data/private/rater_key_final_v2.csv\n")
