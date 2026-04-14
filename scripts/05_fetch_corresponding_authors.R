# 05_fetch_corresponding_authors.R
#
# Purpose: Enrich the filtered LDP and comparator publication files with
#          corresponding author information fetched from the OpenAlex API.
#
#   For each publication, the authorships field is retrieved and any author
#   flagged is_corresponding == TRUE is recorded. Where a paper has multiple
#   corresponding authors all are retained, separated by " | ".
#
#   The enriched files are used by script 07 to programmatically detect
#   corresponding-author conflicts before selecting replacement comparators
#   (i.e., to ensure no individual appears as corresponding author on more
#   than one paper in the rater set, whether LDP or comparator).
#
# Inputs:  data/processed_data/private/LDP_publications_filtered.csv
#          data/processed_data/comparator_publications_filtered.csv
# Outputs: data/processed_data/private/LDP_publications_filtered_with_ca.csv
#          data/processed_data/comparator_publications_filtered_with_ca.csv
#
# Author: Jason Pither, with help from Claude (Sonnet 4.6)
# Created: 2026-04-13

library(dplyr)
library(readr)
library(here)
library(purrr)
library(stringr)
library(openalexR)

mailto    <- "jason.pither@ubc.ca"
api_delay <- 0.15    # seconds between batch requests
batch_size <- 50     # works per API request (well within URL length limits)

options(openalexR.mailto = mailto)

# -----------------------------------------------------------------------------
# Load filtered publication files
# -----------------------------------------------------------------------------

ldp <- readr::read_csv(
  here::here("data", "processed_data", "private", "LDP_publications_filtered.csv"),
  show_col_types = FALSE
)

comp <- readr::read_csv(
  here::here("data", "processed_data", "comparator_publications_filtered.csv"),
  show_col_types = FALSE
)

cat(sprintf("LDP  filtered publications : %d\n", nrow(ldp)))
cat(sprintf("Comp filtered publications : %d\n", nrow(comp)))

# -----------------------------------------------------------------------------
# Helper: batch-fetch corresponding authors for a vector of OpenAlex work IDs.
#
# Returns a tibble with columns:
#   openalex_id           — full OpenAlex work URL (e.g. https://openalex.org/W...)
#   ca_display_names      — corresponding author display name(s), " | " separated
#   ca_openalex_ids       — corresponding author OpenAlex ID(s),  " | " separated
#
# Papers with no is_corresponding flag in OpenAlex (older records) receive NA
# in both ca columns; a warning is printed so they can be checked manually.
# -----------------------------------------------------------------------------

fetch_corresponding_authors <- function(work_ids) {

  ids_short <- unique(na.omit(stringr::str_extract(work_ids, "W\\d+")))
  n         <- length(ids_short)
  n_batches <- ceiling(n / batch_size)
  cat(sprintf("  Fetching corresponding authors for %d works in %d batch(es)...\n",
              n, n_batches))

  result_list <- vector("list", n_batches)

  for (b in seq_len(n_batches)) {

    idx    <- ((b - 1) * batch_size + 1) : min(b * batch_size, n)
    id_str <- paste(ids_short[idx], collapse = "|")

    url <- paste0(
      "https://api.openalex.org/works",
      "?filter=ids.openalex:", id_str,
      "&select=id,authorships",
      "&per-page=200",
      "&mailto=", mailto
    )

    raw <- tryCatch(
      openalexR::oa_request(query_url = url),
      error = function(e) {
        cat(sprintf("  Batch %d error: %s\n", b, conditionMessage(e)))
        list()
      }
    )

    if (length(raw) > 0) {
      result_list[[b]] <- purrr::map_dfr(raw, function(w) {
        auths <- w$authorships
        ca    <- purrr::keep(auths %||% list(),
                             function(a) isTRUE(a$is_corresponding))
        tibble::tibble(
          openalex_id      = w$id %||% NA_character_,
          ca_display_names = if (length(ca) == 0) NA_character_ else
            paste(purrr::map_chr(ca, ~ .x$author$display_name %||% NA_character_),
                  collapse = " | "),
          ca_openalex_ids  = if (length(ca) == 0) NA_character_ else
            paste(purrr::map_chr(ca, ~ .x$author$id %||% NA_character_),
                  collapse = " | ")
        )
      })
    }

    Sys.sleep(api_delay)
  }

  dplyr::bind_rows(purrr::compact(result_list))
}

# -----------------------------------------------------------------------------
# Fetch for LDP publications
# -----------------------------------------------------------------------------

cat("\nFetching corresponding authors — LDP publications:\n")
ca_ldp <- fetch_corresponding_authors(ldp$id)

n_missing_ldp <- sum(is.na(ca_ldp$ca_openalex_ids))
if (n_missing_ldp > 0) {
  cat(sprintf(
    "  WARNING: %d LDP publication(s) have no corresponding-author flag in ",
    n_missing_ldp
  ))
  cat("OpenAlex — verify manually:\n")
  ca_ldp %>%
    dplyr::filter(is.na(ca_openalex_ids)) %>%
    dplyr::pull(openalex_id) %>%
    purrr::walk(~ cat("   ", .x, "\n"))
}

# -----------------------------------------------------------------------------
# Fetch for comparator publications
# -----------------------------------------------------------------------------

cat("\nFetching corresponding authors — comparator publications:\n")
ca_comp <- fetch_corresponding_authors(comp$id)

n_missing_comp <- sum(is.na(ca_comp$ca_openalex_ids))
if (n_missing_comp > 0) {
  cat(sprintf(
    "  WARNING: %d comparator publication(s) have no corresponding-author flag ",
    n_missing_comp
  ))
  cat("in OpenAlex — verify manually:\n")
  ca_comp %>%
    dplyr::filter(is.na(ca_openalex_ids)) %>%
    dplyr::pull(openalex_id) %>%
    purrr::walk(~ cat("   ", .x, "\n"))
}

# -----------------------------------------------------------------------------
# Join CA data back to filtered publication files
# -----------------------------------------------------------------------------

ldp_with_ca <- ldp %>%
  dplyr::left_join(
    ca_ldp %>% dplyr::rename(id = openalex_id),
    by = "id"
  )

comp_with_ca <- comp %>%
  dplyr::left_join(
    ca_comp %>% dplyr::rename(id = openalex_id),
    by = "id"
  )

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

cat(sprintf("\nLDP  : %d / %d publications have corresponding author data\n",
            sum(!is.na(ldp_with_ca$ca_openalex_ids)), nrow(ldp_with_ca)))
cat(sprintf("Comp : %d / %d publications have corresponding author data\n",
            sum(!is.na(comp_with_ca$ca_openalex_ids)), nrow(comp_with_ca)))

# -----------------------------------------------------------------------------
# Write outputs (originals are not overwritten)
# -----------------------------------------------------------------------------

readr::write_csv(
  ldp_with_ca,
  here::here("data", "processed_data", "private",
             "LDP_publications_filtered_with_ca.csv")
)

readr::write_csv(
  comp_with_ca,
  here::here("data", "processed_data",
             "comparator_publications_filtered_with_ca.csv")
)

cat("\nOutputs written:\n")
cat("  data/processed_data/private/LDP_publications_filtered_with_ca.csv\n")
cat("  data/processed_data/comparator_publications_filtered_with_ca.csv\n")
