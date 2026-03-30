# 04_create_rater_files.R
#
# Purpose: Create blinded rater files for FAIR compliance scoring.
#
#   For each LDP author with qualifying publications, one publication is
#   randomly selected. A year- and institution-matched comparator publication
#   is then randomly drawn from the comparator pool (without replacement).
#   Each publication is assigned a unique blinded alphanumeric code; the
#   resulting table is shuffled so that group membership (LDP vs. comparator)
#   is not apparent from row order.
#
#   Two outputs are produced:
#     1. rater_publications.csv      — blinded: pub_id, title, doi, year,
#                                      openalex_url.  Shared with raters.
#     2. private/rater_key.csv       — linking pub_id → pair, group, author,
#                                      institution.  NOT shared with raters.
#
# Matching criteria:
#   Comparator publications must come from the same institution AND the same
#   calendar year (publication_year) as the selected LDP publication.
#   Comparators are sampled without replacement: once a comparator publication
#   is assigned to an LDP pair it is removed from the available pool.
#   LDP authors for whom no year+institution matched comparator is available
#   are excluded and reported.
#
# Inputs:  data/processed_data/private/LDP_publications_filtered.csv
#          data/processed_data/comparator_publications_filtered.csv
# Outputs: data/processed_data/rater_publications.csv
#          data/processed_data/private/rater_key.csv
#
# Author: Jason Pither, with help from Claude (Sonnet 4.6)
# Updated: 2026-03-29

library(dplyr)
library(readr)
library(here)
library(purrr)
library(stringr)

# -----------------------------------------------------------------------------
# Reproducible seed — record this value in the paper / pre-registration
# -----------------------------------------------------------------------------

rng_seed <- 20260329
set.seed(rng_seed)
cat(sprintf("Random seed: %d\n", rng_seed))

# -----------------------------------------------------------------------------
# Load filtered publications
# -----------------------------------------------------------------------------

ldp  <- readr::read_csv(
  here::here("data", "processed_data", "private", "LDP_publications_filtered.csv"),
  show_col_types = FALSE
)

comp <- readr::read_csv(
  here::here("data", "processed_data", "comparator_publications_filtered.csv"),
  show_col_types = FALSE
)

cat(sprintf("LDP  : %d publications from %d authors\n",
            nrow(ldp), dplyr::n_distinct(ldp$searched_name)))
cat(sprintf("Comp : %d publications from %d authors\n",
            nrow(comp), dplyr::n_distinct(comp$searched_name)))

# -----------------------------------------------------------------------------
# Helper: generate N unique random 6-character alphanumeric codes
# Codes draw from uppercase A-Z and digits 0-9 (36^6 ≈ 2.2 billion unique
# values), ensuring no two publications share the same code.
# -----------------------------------------------------------------------------

make_pub_ids <- function(n) {
  chars  <- c(LETTERS, as.character(0:9))
  codes  <- character(0)
  while (length(codes) < n) {
    candidate <- paste(sample(chars, 6, replace = TRUE), collapse = "")
    if (!candidate %in% codes) codes <- c(codes, candidate)
  }
  codes
}

# -----------------------------------------------------------------------------
# Matching and random sampling
#
# Algorithm:
#   For each LDP author (in randomised order):
#     1. From their filtered publications, identify those for which at least one
#        comparator is still available in the pool (same institution_name AND
#        same publication_year).
#     2. Randomly select one such LDP publication.
#     3. Randomly select one comparator from the matching pool.
#     4. Remove that comparator from the pool (no reuse).
#   Authors with no matchable publication are excluded and reported.
#
# Shuffling the author order before iteration ensures that pool depletion does
# not systematically favour authors who happen to appear first alphabetically.
# -----------------------------------------------------------------------------

comp_pool  <- comp
pairs_list <- list()
unmatched  <- character()

ldp_authors <- sample(unique(ldp$searched_name))   # random processing order
cat(sprintf("\nMatching %d LDP authors...\n", length(ldp_authors)))

for (auth in ldp_authors) {

  auth_pubs <- ldp %>% dplyr::filter(searched_name == auth)
  inst      <- auth_pubs$institution_name[1]   # consistent within author

  # Retain only publications for which ≥1 comparator is still in the pool
  matchable <- auth_pubs %>%
    dplyr::filter(purrr::map_lgl(publication_year, function(yr) {
      nrow(dplyr::filter(comp_pool,
                         institution_name == inst,
                         publication_year == yr)) > 0
    }))

  if (nrow(matchable) == 0) {
    unmatched <- c(unmatched, auth)
    cat(sprintf(
      "  UNMATCHED: %s  (inst: %s; pub years available: %s)\n",
      auth, inst,
      paste(sort(unique(auth_pubs$publication_year)), collapse = ", ")
    ))
    next
  }

  # Randomly select one LDP publication from those with available matches
  ldp_sel <- matchable %>% dplyr::slice_sample(n = 1)

  # Randomly select one comparator from the matching pool
  match_pool <- comp_pool %>%
    dplyr::filter(institution_name == inst,
                  publication_year == ldp_sel$publication_year)

  comp_sel <- match_pool %>% dplyr::slice_sample(n = 1)

  # Remove selected comparator so it cannot be reused
  comp_pool <- comp_pool %>% dplyr::filter(id != comp_sel$id)

  pairs_list[[auth]] <- list(ldp = ldp_sel, comp = comp_sel)
}

n_pairs <- length(pairs_list)
cat(sprintf("\nPairs formed   : %d\n", n_pairs))
cat(sprintf("Unmatched LDP  : %d\n", length(unmatched)))
if (length(unmatched) > 0)
  cat(paste0("  ", unmatched, collapse = "\n"), "\n")

if (n_pairs == 0)
  stop("No pairs could be formed. Check that institution and year columns match ",
       "between the LDP and comparator filtered files.")

# -----------------------------------------------------------------------------
# Assign pair IDs and blinded publication codes
# -----------------------------------------------------------------------------

pair_ids  <- sprintf("PAIR%03d", seq_len(n_pairs))
pub_codes <- make_pub_ids(n_pairs * 2)   # 2 per pair

# Build long-format table (one row per publication)
rater_full <- purrr::imap_dfr(pairs_list, function(pair, auth) {
  idx       <- which(names(pairs_list) == auth)
  pair_id   <- pair_ids[idx]
  code_ldp  <- pub_codes[(idx * 2) - 1]
  code_comp <- pub_codes[idx * 2]

  dplyr::bind_rows(
    dplyr::tibble(
      pub_id           = code_ldp,
      pair_id          = pair_id,
      group            = "LDP",
      searched_name    = auth,
      institution_name = pair$ldp$institution_name,
      publication_year = pair$ldp$publication_year,
      title            = pair$ldp$title,
      doi              = pair$ldp$doi,
      openalex_id      = pair$ldp$id
    ),
    dplyr::tibble(
      pub_id           = code_comp,
      pair_id          = pair_id,
      group            = "Comparator",
      searched_name    = pair$comp$searched_name,
      institution_name = pair$comp$institution_name,
      publication_year = pair$comp$publication_year,
      title            = pair$comp$title,
      doi              = pair$comp$doi,
      openalex_id      = pair$comp$id
    )
  )
})

# Add OpenAlex URL as fallback access route for papers without a DOI
rater_full <- rater_full %>%
  dplyr::mutate(
    openalex_url = paste0(
      "https://openalex.org/",
      stringr::str_extract(openalex_id, "W\\d+")
    )
  )

# Shuffle rows: raters see publications in random order with no group signal
rater_full <- rater_full %>% dplyr::slice_sample(prop = 1)

# -----------------------------------------------------------------------------
# Output 1: Blinded rater file
# Contains only the fields raters need to locate and score each paper.
# Group identity, author name, and institution are deliberately excluded.
# -----------------------------------------------------------------------------

rater_blinded <- rater_full %>%
  dplyr::select(pub_id, title, doi, publication_year, openalex_url)

# -----------------------------------------------------------------------------
# Output 2: Private key file
# Full linking table. Must NOT be shared with raters until scoring is complete.
# -----------------------------------------------------------------------------

rater_key <- rater_full %>%
  dplyr::select(pub_id, pair_id, group, searched_name,
                institution_name, publication_year,
                title, doi, openalex_id, openalex_url)

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

cat("\n=== Summary ===\n")
cat(sprintf("Pairs              : %d\n", n_pairs))
cat(sprintf("Total publications : %d (2 per pair)\n", nrow(rater_blinded)))
cat(sprintf("Publication years  : %d–%d\n",
            min(rater_full$publication_year, na.rm = TRUE),
            max(rater_full$publication_year, na.rm = TRUE)))
cat(sprintf("Publications with DOI : %d / %d\n",
            sum(!is.na(rater_full$doi) & rater_full$doi != ""),
            nrow(rater_full)))

cat("\nPairs by institution (LDP side):\n")
rater_key %>%
  dplyr::filter(group == "LDP") %>%
  dplyr::count(institution_name, name = "n_pairs") %>%
  print()

cat("\nPairs by publication year (LDP side):\n")
rater_key %>%
  dplyr::filter(group == "LDP") %>%
  dplyr::count(publication_year, name = "n_pairs") %>%
  dplyr::arrange(publication_year) %>%
  print()

# -----------------------------------------------------------------------------
# Write outputs
# -----------------------------------------------------------------------------

readr::write_csv(
  rater_blinded,
  here::here("data", "processed_data", "rater_publications.csv")
)
cat("\nSaved: data/processed_data/rater_publications.csv\n")

readr::write_csv(
  rater_key,
  here::here("data", "processed_data", "private", "rater_key.csv")
)
cat("Saved: data/processed_data/private/rater_key.csv\n")

cat("\n=== COMPLETE ===\n")
cat("Share rater_publications.csv with raters.\n")
cat("rater_key.csv is private — do not share until scoring is complete.\n")
