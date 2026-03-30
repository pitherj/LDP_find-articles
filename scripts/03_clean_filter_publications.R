# 03_clean_filter_publications.R
#
# Purpose: Clean and filter the LDP and comparator publication lists to retain
#          only deduplicated, primary research articles suitable for FAIR
#          compliance scoring. Four filtering layers are applied in order:
#
#   Layer 0 — Investigator co-authorship exclusion
#     Batch-fetches authorship records for every work ID already in the LDP and
#     comparator datasets (same pattern as the Layer 2b metadata re-fetch), then
#     checks whether any of the five study investigator ORCIDs appears among the
#     co-authors. Only papers already in the dataset are queried — no external
#     investigator work-lists are fetched. Applied first so that investigator
#     papers cannot appear in either group.
#
#   Layer 1 — Title deduplication
#     Within each group (LDP / comparator), deduplicate on a unicode-normalised
#     title (transliterated to ASCII, punctuation stripped, lowercased). This
#     catches both exact duplicates and encoding-artefact duplicates (e.g. an
#     em-dash stored as garbled ASCII bytes). For within-author duplicates (same
#     title appearing twice under one searched_name), the first occurrence is
#     kept. For cross-author duplicates (same paper retrieved for two different
#     searched_names), the alphabetically first searched_name is kept and the
#     others are dropped; affected authors are reported.
#
#   Layer 2 — OpenAlex type filter
#     Retains only records with type == "article" (defensive: retrieval scripts
#     already filter to this type). Also batch-fetches is_paratext and
#     type_crossref for all records via the OpenAlex work IDs; records with
#     is_paratext == TRUE or type_crossref %in% non_primary_crossref_types are
#     excluded.
#
#   Layer 3 — Title keyword screen
#     Excludes records whose title matches patterns associated with non-primary-
#     research content (reviews, perspectives, commentaries, editorials,
#     meta-analyses, corrections). Applied after type filtering.
#
# Inputs:  data/processed_data/private/LDP_author_publications.csv
#          data/processed_data/comparator_author_publications.csv
# Outputs: data/processed_data/private/LDP_publications_filtered.csv
#          data/processed_data/comparator_publications_filtered.csv
#          data/processed_data/private/filter_log.txt   (step-by-step exclusion report)
#
# Author:  Jason Pither, with help from Claude (Sonnet 4.6)
# Updated: 2026-03-30

library(openalexR)
library(dplyr)
library(readr)
library(here)
library(purrr)
library(stringr)
library(stringi)   # Unicode transliteration for title normalisation

options(openalexR.mailto = "jason.pither@ubc.ca")
mailto    <- "jason.pither@ubc.ca"
api_delay <- 0.15

# Batch size for OpenAlex work metadata re-fetch
batch_size <- 100

# Crossref types that indicate non-primary-research content.
# "journal-article" is the standard primary-research value; everything else
# in this list is explicitly non-primary.
non_primary_crossref_types <- c(
  "review-article",
  "editorial",
  "letter",
  "correction",
  "erratum",
  "retraction",
  "addendum",
  "expression-of-concern"
)

# Title keyword patterns for non-primary-research content.
# Applied case-insensitively to the lowercased title.
# Each pattern is anchored with \b (word boundary) to reduce false positives.
non_primary_title_patterns <- c(
  r"(\breview\b)",         # review articles of any kind (systematic, narrative, scoping, invited)
  r"(\bperspective\b)",    # perspective / viewpoint pieces
  r"(\bcommentary\b)",     # commentaries
  r"(\beditorial\b)",      # editorials
  r"(\bmeta-analysis\b)",  # quantitative evidence synthesis (not primary data collection)
  r"(\bresponse to\b)",    # responses / rebuttals to published papers
  r"(\bcorrigendum\b)",    # publisher corrections
  r"(\berratum\b)",        # publisher corrections
  r"(\bretraction\b)"      # retractions
)

non_primary_title_regex <- paste(non_primary_title_patterns, collapse = "|")

is_non_primary_title <- function(titles) {
  stringr::str_detect(
    tolower(dplyr::coalesce(as.character(titles), "")),
    non_primary_title_regex
  )
}

# Unicode-robust title normalisation used for deduplication comparison.
# Transliterates Unicode to nearest ASCII (handles en-dashes, em-dashes,
# curly quotes, accented letters, etc.), then strips any remaining non-ASCII
# bytes, replaces all non-alphanumeric characters with spaces, and lowercases.
# This catches encoding-artefact duplicates such as a hyphen stored as garbled
# multi-byte ASCII (e.g. ",Äê" for "-"). Applied for comparison only — the
# original title strings are preserved unchanged in the data.
normalise_title <- function(x) {
  x <- dplyr::coalesce(as.character(x), "")
  x <- stringi::stri_trans_general(x, "Any-Latin; Latin-ASCII")
  x <- iconv(x, to = "ASCII", sub = " ")
  x <- gsub("[^a-zA-Z0-9]+", " ", x)
  tolower(trimws(gsub("\\s+", " ", x)))
}

# Study investigators whose co-authored papers must be excluded from both the
# LDP and comparator lists. These names and ORCIDs are not personally sensitive.
investigator_orcids <- c(
  "Sandra Michelle Emry" = "https://orcid.org/0000-0001-6882-2105",
  "Jason Pither"         = "https://orcid.org/0000-0002-7490-6839",
  "David AGA Hunt"       = "https://orcid.org/0000-0002-7771-8569",
  "Diane Srivastava"     = "https://orcid.org/0000-0003-4541-5595",
  "Mathew Vis-Dunbar"    = "https://orcid.org/0000-0001-6541-9660"
)

# Batch-fetches authorship records for the supplied work IDs (same batching
# pattern as fetch_work_metadata in Layer 2b) and returns a tibble with one
# row per work ID indicating whether any investigator ORCID appears among its
# co-authors. Only works already in the dataset are queried — no external
# investigator publication lists are fetched.
fetch_authorship_flags <- function(work_ids, inv_orcids) {
  ids_short <- unique(na.omit(stringr::str_extract(work_ids, "W\\d+")))
  n_batches <- ceiling(length(ids_short) / batch_size)
  result_list <- vector("list", n_batches)

  for (b in seq_len(n_batches)) {
    idx    <- ((b - 1) * batch_size + 1) : min(b * batch_size, length(ids_short))
    id_str <- paste(ids_short[idx], collapse = "|")

    url <- paste0(
      "https://api.openalex.org/works",
      "?filter=ids.openalex:", id_str,
      "&select=id,authorships",
      "&per-page=200",
      "&mailto=", mailto
    )

    raw <- tryCatch(
      oa_request(query_url = url),
      error = function(e) { cat("  Batch", b, "error:", conditionMessage(e), "\n"); list() }
    )

    if (length(raw) > 0) {
      result_list[[b]] <- tibble(
        id = purrr::map_chr(raw, "id", .default = NA_character_),
        has_investigator_author = purrr::map_lgl(raw, function(w) {
          auths <- w$authorships
          if (is.null(auths) || length(auths) == 0) return(FALSE)
          any(purrr::map_lgl(auths, function(a) {
            orcid <- a$author$orcid
            !is.null(orcid) && !is.na(orcid) && orcid %in% inv_orcids
          }))
        })
      )
    }
    Sys.sleep(api_delay)
  }
  dplyr::bind_rows(purrr::compact(result_list))
}

# Open log file
log_path <- here::here("data", "processed_data", "private", "filter_log.txt")
log_con  <- file(log_path, open = "wt")

log <- function(...) {
  msg <- paste0(...)
  cat(msg, "\n")
  cat(msg, "\n", file = log_con)
}

log("=== 03_clean_filter_publications.R ===")
log("Run date: ", format(Sys.time(), "%Y-%m-%d %H:%M"))
log("")

# -----------------------------------------------------------------------------
# Load data
# -----------------------------------------------------------------------------

ldp  <- readr::read_csv(
  here::here("data", "processed_data", "private", "LDP_author_publications.csv"),
  show_col_types = FALSE
)
comp <- readr::read_csv(
  here::here("data", "processed_data", "comparator_author_publications.csv"),
  show_col_types = FALSE
)

log("--- Input row counts ---")
log("LDP publications:        ", nrow(ldp))
log("Comparator publications: ", nrow(comp))
log("")

# -----------------------------------------------------------------------------
# Layer 0: Investigator co-authorship exclusion
# -----------------------------------------------------------------------------

log("=== Layer 0: Investigator co-authorship exclusion ===")
log("Fetching authorship records for LDP publications...")
ldp_auth_flags  <- fetch_authorship_flags(ldp$id,  investigator_orcids)
log("Fetching authorship records for comparator publications...")
comp_auth_flags <- fetch_authorship_flags(comp$id, investigator_orcids)
log("")

ldp  <- dplyr::left_join(ldp,  ldp_auth_flags,  by = "id")
comp <- dplyr::left_join(comp, comp_auth_flags, by = "id")

exclude_investigator_works <- function(df, group_label) {
  flagged <- df %>% dplyr::filter(dplyr::coalesce(has_investigator_author, FALSE))
  df_out  <- df %>%
    dplyr::filter(!dplyr::coalesce(has_investigator_author, FALSE)) %>%
    dplyr::select(-has_investigator_author)

  if (nrow(flagged) > 0) {
    log(group_label, " | Dropped ", nrow(flagged),
        " record(s) co-authored by study investigators:")
    flagged %>%
      dplyr::mutate(msg = paste0("  ", searched_name, ": ", title)) %>%
      dplyr::pull(msg) %>% purrr::walk(log)
  } else {
    log(group_label, " | No investigator co-authored records found.")
  }
  log(group_label, " | Rows after investigator exclusion: ", nrow(df_out))
  df_out
}

ldp  <- exclude_investigator_works(ldp,  "LDP")
comp <- exclude_investigator_works(comp, "Comparator")
log("")

# -----------------------------------------------------------------------------
# Layer 1: Title deduplication
# -----------------------------------------------------------------------------

log("=== Layer 1: Title deduplication ===")

deduplicate_titles <- function(df, group_label) {

  df <- df %>%
    dplyr::mutate(title_norm = normalise_title(title))

  # 1a: Within-author duplicates (same searched_name, same normalised title)
  within_dups <- df %>%
    dplyr::group_by(searched_name, title_norm) %>%
    dplyr::filter(dplyr::n() > 1) %>%
    dplyr::ungroup()

  if (nrow(within_dups) > 0) {
    log(group_label, " | Within-author duplicates found (keeping first occurrence):")
    within_dups %>%
      dplyr::distinct(searched_name, title_norm) %>%
      dplyr::mutate(msg = paste0("  ", searched_name, ": ", title_norm)) %>%
      dplyr::pull(msg) %>%
      purrr::walk(log)
  } else {
    log(group_label, " | No within-author duplicate titles found.")
  }

  df <- df %>%
    dplyr::group_by(searched_name, title_norm) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup()

  # 1b: Cross-author duplicates (same normalised title, different searched_names)
  cross_dups <- df %>%
    dplyr::group_by(title_norm) %>%
    dplyr::filter(dplyr::n() > 1) %>%
    dplyr::arrange(title_norm, searched_name) %>%
    dplyr::ungroup()

  if (nrow(cross_dups) > 0) {
    log(group_label, " | Cross-author duplicate titles (same paper for multiple authors):")
    log(group_label, " | Keeping alphabetically first searched_name; others dropped.")
    cross_dups %>%
      dplyr::group_by(title_norm) %>%
      dplyr::summarise(
        authors  = paste(searched_name, collapse = "; "),
        kept     = searched_name[1],
        .groups  = "drop"
      ) %>%
      dplyr::mutate(msg = paste0("  Title: \"", title_norm, "\"\n    Authors: ", authors, "\n    Kept: ", kept)) %>%
      dplyr::pull(msg) %>%
      purrr::walk(log)
  } else {
    log(group_label, " | No cross-author duplicate titles found.")
  }

  df <- df %>%
    dplyr::group_by(title_norm) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup() %>%
    dplyr::select(-title_norm)

  log(group_label, " | Rows after deduplication: ", nrow(df))
  df
}

ldp  <- deduplicate_titles(ldp,  "LDP")
comp <- deduplicate_titles(comp, "Comparator")
log("")

# -----------------------------------------------------------------------------
# Layer 2a: Type filter (defensive)
# -----------------------------------------------------------------------------

log("=== Layer 2a: OpenAlex type filter (defensive) ===")

n_before <- nrow(ldp)
ldp <- dplyr::filter(ldp, type == "article")
log("LDP       | Dropped ", n_before - nrow(ldp), " non-article rows (type != 'article'). Remaining: ", nrow(ldp))

n_before <- nrow(comp)
comp <- dplyr::filter(comp, type == "article")
log("Comparator| Dropped ", n_before - nrow(comp), " non-article rows (type != 'article'). Remaining: ", nrow(comp))
log("")

# -----------------------------------------------------------------------------
# Layer 2b: Batch re-fetch is_paratext and type_crossref from OpenAlex
# -----------------------------------------------------------------------------

log("=== Layer 2b: Re-fetch is_paratext and type_crossref ===")

fetch_work_metadata <- function(work_ids) {
  # Accepts full OpenAlex work URLs or bare W-IDs; normalises to W-IDs
  ids_short <- unique(na.omit(stringr::str_extract(work_ids, "W\\d+")))
  n_batches <- ceiling(length(ids_short) / batch_size)
  result_list <- vector("list", n_batches)

  for (b in seq_len(n_batches)) {
    idx    <- ((b - 1) * batch_size + 1) : min(b * batch_size, length(ids_short))
    id_str <- paste(ids_short[idx], collapse = "|")

    url <- paste0(
      "https://api.openalex.org/works",
      "?filter=ids.openalex:", id_str,
      "&select=id,is_paratext,type_crossref",
      "&per-page=200",
      "&mailto=", mailto
    )

    raw <- tryCatch(
      oa_request(query_url = url),
      error = function(e) { cat("  Batch", b, "error:", conditionMessage(e), "\n"); list() }
    )

    if (length(raw) > 0) {
      result_list[[b]] <- tibble(
        id            = purrr::map_chr(raw, "id",           .default = NA_character_),
        is_paratext   = purrr::map_lgl(raw, "is_paratext",  .default = NA),
        type_crossref = purrr::map_chr(raw, "type_crossref",.default = NA_character_)
      )
    }
    Sys.sleep(api_delay)
  }
  dplyr::bind_rows(purrr::compact(result_list))
}

log("Fetching work metadata for LDP publications...")
ldp_meta  <- fetch_work_metadata(ldp$id)
log("Fetching work metadata for comparator publications...")
comp_meta <- fetch_work_metadata(comp$id)

# Join metadata back
ldp  <- ldp  %>% dplyr::left_join(ldp_meta,  by = "id")
comp <- comp %>% dplyr::left_join(comp_meta, by = "id")

# Report is_paratext and type_crossref distributions
log("")
log("LDP type_crossref distribution:")
print(table(ldp$type_crossref, useNA = "always"))
log("")
log("Comparator type_crossref distribution:")
print(table(comp$type_crossref, useNA = "always"))

# Exclude paratext
n_before <- nrow(ldp)
ldp_paratext_dropped <- ldp %>% dplyr::filter(is_paratext == TRUE)
ldp  <- ldp  %>% dplyr::filter(is.na(is_paratext) | is_paratext == FALSE)
if (nrow(ldp_paratext_dropped) > 0) {
  log("LDP       | Dropped ", nrow(ldp_paratext_dropped), " paratext records (is_paratext == TRUE):")
  ldp_paratext_dropped %>%
    dplyr::mutate(msg = paste0("  ", searched_name, ": ", title)) %>%
    dplyr::pull(msg) %>% purrr::walk(log)
} else {
  log("LDP       | No paratext records found.")
}

n_before <- nrow(comp)
comp_paratext_dropped <- comp %>% dplyr::filter(is_paratext == TRUE)
comp <- comp %>% dplyr::filter(is.na(is_paratext) | is_paratext == FALSE)
if (nrow(comp_paratext_dropped) > 0) {
  log("Comparator| Dropped ", nrow(comp_paratext_dropped), " paratext records (is_paratext == TRUE):")
  comp_paratext_dropped %>%
    dplyr::mutate(msg = paste0("  ", searched_name, ": ", title)) %>%
    dplyr::pull(msg) %>% purrr::walk(log)
} else {
  log("Comparator| No paratext records found.")
}

# Exclude non-primary Crossref types
n_before <- nrow(ldp)
ldp_crossref_dropped <- ldp %>%
  dplyr::filter(!is.na(type_crossref), type_crossref %in% non_primary_crossref_types)
ldp <- ldp %>%
  dplyr::filter(is.na(type_crossref) | !type_crossref %in% non_primary_crossref_types)
if (nrow(ldp_crossref_dropped) > 0) {
  log("LDP       | Dropped ", nrow(ldp_crossref_dropped), " non-primary Crossref type records:")
  ldp_crossref_dropped %>%
    dplyr::mutate(msg = paste0("  ", searched_name, " [", type_crossref, "]: ", title)) %>%
    dplyr::pull(msg) %>% purrr::walk(log)
} else {
  log("LDP       | No non-primary Crossref type records found.")
}

n_before <- nrow(comp)
comp_crossref_dropped <- comp %>%
  dplyr::filter(!is.na(type_crossref), type_crossref %in% non_primary_crossref_types)
comp <- comp %>%
  dplyr::filter(is.na(type_crossref) | !type_crossref %in% non_primary_crossref_types)
if (nrow(comp_crossref_dropped) > 0) {
  log("Comparator| Dropped ", nrow(comp_crossref_dropped), " non-primary Crossref type records:")
  comp_crossref_dropped %>%
    dplyr::mutate(msg = paste0("  ", searched_name, " [", type_crossref, "]: ", title)) %>%
    dplyr::pull(msg) %>% purrr::walk(log)
} else {
  log("Comparator| No non-primary Crossref type records found.")
}

log("")
log("After Layer 2 — LDP rows: ", nrow(ldp), " | Comparator rows: ", nrow(comp))
log("")

# -----------------------------------------------------------------------------
# Layer 3: Title keyword screen
# -----------------------------------------------------------------------------

log("=== Layer 3: Title keyword screen ===")
log("Patterns: ", non_primary_title_regex)
log("")

filter_titles <- function(df, group_label) {
  flagged <- df %>% dplyr::filter(is_non_primary_title(title))
  df_out  <- df %>% dplyr::filter(!is_non_primary_title(title))

  if (nrow(flagged) > 0) {
    log(group_label, " | Dropped ", nrow(flagged), " records matching non-primary title patterns:")
    flagged %>%
      dplyr::mutate(msg = paste0("  [", type_crossref, "] ", searched_name, ": ", title)) %>%
      dplyr::pull(msg) %>% purrr::walk(log)
  } else {
    log(group_label, " | No records matched non-primary title patterns.")
  }

  log(group_label, " | Rows after title screen: ", nrow(df_out))
  df_out
}

ldp  <- filter_titles(ldp,  "LDP")
comp <- filter_titles(comp, "Comparator")
log("")

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

log("=== Final summary ===")
log("LDP       | Final rows: ", nrow(ldp), " | Unique authors: ", dplyr::n_distinct(ldp$searched_name))
log("Comparator| Final rows: ", nrow(comp), " | Unique authors: ", dplyr::n_distinct(comp$searched_name))
log("")

# Authors with zero publications remaining after filtering
ldp_zero <- setdiff(
  readr::read_csv(here::here("data", "processed_data", "private", "LDP_author_publications.csv"),
                  show_col_types = FALSE)$searched_name,
  ldp$searched_name
)
if (length(ldp_zero) > 0) {
  log("LDP authors with no publications remaining after filtering (", length(ldp_zero), "):")
  purrr::walk(ldp_zero, ~ log("  ", .x))
} else {
  log("All LDP authors retain at least one qualifying publication.")
}

comp_orig_authors <- readr::read_csv(
  here::here("data", "processed_data", "comparator_author_publications.csv"),
  show_col_types = FALSE
)$searched_name
comp_zero <- setdiff(unique(comp_orig_authors), comp$searched_name)
if (length(comp_zero) > 0) {
  log("Comparator authors with no publications remaining after filtering (", length(comp_zero), "):")
  purrr::walk(comp_zero, ~ log("  ", .x))
} else {
  log("All comparator authors retain at least one qualifying publication.")
}

# -----------------------------------------------------------------------------
# Write outputs
# -----------------------------------------------------------------------------

readr::write_csv(ldp,  here::here("data", "processed_data", "private", "LDP_publications_filtered.csv"))
readr::write_csv(comp, here::here("data", "processed_data", "comparator_publications_filtered.csv"))

log("")
log("Outputs written:")
log("  data/processed_data/private/LDP_publications_filtered.csv")
log("  data/processed_data/comparator_publications_filtered.csv")
log("  data/processed_data/private/filter_log.txt")

close(log_con)
cat("\n=== COMPLETE. See data/processed_data/private/filter_log.txt for full report. ===\n")
