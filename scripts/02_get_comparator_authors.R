# 02_get_comparator_authors.R
#
# Purpose: Identify EEE thesis authors (2022-2024) as comparator candidates and
# retrieve their first-author publications from OpenAlex using a two-phase approach:
#
#   Phase 1 (per institution): one batch works query filtered by institution,
#     EEE field, and date → name-match against the pre-screened candidate list →
#     resolve OpenAlex author IDs
#
#   Phase 2 (per confirmed match): single targeted works fetch by author ID →
#     complete first-author publication list, filtered by non-EEE keyword patterns
#
# Keyword filtering (title-based, verbatim patterns from v2 classification qmd):
#   LDP publications are filtered BEFORE N_target is calculated, so the target
#   sample size reflects LDP authors with ≥1 EEE publication. In Phase 2, a
#   comparator author is only counted toward N_target if ≥1 of their publications
#   survives the keyword filter, ensuring no comparator slots are wasted on authors
#   whose entire output is off-topic.
#
# Oversampling for year-matched pairing:
#   Comparator authors are collected at oversample_factor * N_target per institution
#   (default: 2x). This ensures the comparator pool contains publications from all
#   years represented by LDP students at each institution. Year-matched pairing —
#   requiring each LDP publication and its matched comparator publication to be from
#   the same calendar year — is performed at the analysis stage using the
#   publication_year column in the output. LDP students for whom no year-matched
#   comparator publication is available will be excluded.
#
# API efficiency:
#   Setup  : ~n_institutions calls (institution ID lookup)
#   Phase 1: ~n_institutions paginated calls (one works query per institution)
#   Phase 2: n_confirmed_matches calls (one per matched candidate; up to N_target * oversample_factor per institution)
#
# Inputs:  data/processed_data/classified/*.csv    (classified thesis CSVs from LDP_thesis_classification project)
#          data/raw_data/ldp_exclusion_names.csv   (output of 01_get_ldp_targets.R)
#          data/raw_data/ldp_n_target.csv          (output of 01_get_ldp_targets.R)
#          data/raw_data/ldp_eee_field_ids.rds     (output of 01_get_ldp_targets.R)
#          data/raw_data/institution_names.csv
# Outputs: data/processed_data/comparator_author_publications.csv
#          data/processed_data/comparator_checkpoint.rds
#
# Prerequisites: run scripts/01_get_ldp_targets.R first to generate the three
#   ldp_* input files above. Populate data/processed_data/classified/ with
#   classified thesis CSVs from the LDP_thesis_classification project.
#
# Author: Jason Pither, with help from Claude (Sonnet 4.6)
# Updated: 2026-03-29

library(openalexR)
library(dplyr)
library(readr)
library(here)
library(stringr)
library(purrr)
library(tidyr)  # used in Phase 1 author topic unnesting

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

options(openalexR.mailto = "jason.pither@ubc.ca")
mailto <- "jason.pither@ubc.ca"

# Comparator minimum publication date: January 1 of the year following the
# earliest LDP cohort year (2020 cohort → 2021 cutoff). All comparators share
# this single cutoff because the within-institution random pairing (done at
# analysis stage) does not target specific LDP cohort years.
min_pub_date         <- "2021-01-01"  # floor = year after earliest LDP cohort (2020 → 2021)
api_delay            <- 0.15
max_num_pubs         <- 30          # exclude authors with more works (likely not students)
thesis_years         <- 2022:2024   # thesis submission years covered by the scraped data
ldp_batch_size       <- 100         # author IDs per batch for author metadata fetch
min_prob_EEE         <- 0.75        # minimum classifier probability to include as EEE candidate

# Oversample factor: collect oversample_factor * N_target comparator authors per
# institution to ensure the comparator pool covers all publication years represented
# by LDP students at that institution. Year-matched pairing is performed at analysis
# time; excess comparators beyond N_target are not used in the primary analysis.
oversample_factor    <- 2

target_disciplines <- c(
  "Ecology",
  "Evolutionary Biology",
  "Environmental Science",
  "Earth and Planetary Sciences",
  "Agricultural and Biological Sciences"
)

# -----------------------------------------------------------------------------
# Non-EEE keyword patterns (verbatim from thesis_classification_model_training.qmd)
# Applied to lowercased publication titles to drop off-topic papers from both
# the LDP and comparator datasets.
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
  r"(\bperceive\b)",           # social science 
  r"(\bsocioeconomic\b)",           # social science
  r"(\bdiscourse\b)",           # social science
  r"(\bhuman safety\b)",           # social science
  r"(\bislamic\b)",           # social science
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

# Helper: vectorised; returns TRUE for each title matching any non-EEE pattern.
# NA titles are treated as non-matching (kept).
is_noneee_title <- function(titles) {
  stringr::str_detect(
    tolower(dplyr::coalesce(as.character(titles), "")),
    noneee_regex
  )
}

# -----------------------------------------------------------------------------
# Helper: name-match key  →  "firstinitial_lastname"  (lower-case)
# -----------------------------------------------------------------------------

name_key <- function(name) {
  name   <- stringr::str_trim(name)
  tokens <- stringr::str_split(name, "\\s+")[[1]]
  if (length(tokens) < 2) return(NA_character_)
  paste0(tolower(substr(tokens[1], 1, 1)), "_", tolower(tokens[length(tokens)]))
}

name_keys <- function(names) purrr::map_chr(names, name_key)

# -----------------------------------------------------------------------------
# Helper: fetch first-author articles for a confirmed OpenAlex author ID
# (Phase 2 — no disambiguation needed; author ID already confirmed in Phase 1)
# -----------------------------------------------------------------------------

get_works_by_author_id <- function(author_id, author_name,
                                   from_date = min_pub_date,
                                   delay     = api_delay) {
  cat("  Fetching works for:", author_name, "(", author_id, ")\n")

  works_raw <- tryCatch(
    oa_fetch(entity = "works", author.id = author_id,
             from_publication_date = from_date, output = "list", verbose = FALSE),
    error = function(e) { cat("  Error:", conditionMessage(e), "\n"); NULL }
  )
  Sys.sleep(delay)

  if (is.null(works_raw) || length(works_raw) == 0) {
    cat("  No works found.\n"); return(NULL)
  }

  # Retain first-author articles only
  is_fa <- purrr::map_lgl(works_raw, function(w) {
    if (!identical(w$type, "article")) return(FALSE)
    auths <- w$authorships
    if (is.null(auths) || length(auths) == 0) return(FALSE)
    any(purrr::map_lgl(auths, function(a)
      identical(a$author_position, "first") && identical(a$author$id, author_id)
    ))
  })

  works_raw <- works_raw[is_fa]
  if (length(works_raw) == 0) { cat("  No first-author articles.\n"); return(NULL) }

  works <- tibble(
    id               = purrr::map_chr(works_raw, "id",               .default = NA_character_),
    display_name     = purrr::map_chr(works_raw, "display_name",     .default = NA_character_),
    title            = purrr::map_chr(works_raw, "title",            .default = NA_character_),
    publication_date = purrr::map_chr(works_raw, "publication_date", .default = NA_character_),
    publication_year = purrr::map_int(works_raw, "publication_year", .default = NA_integer_),
    type             = purrr::map_chr(works_raw, "type",             .default = NA_character_),
    doi              = purrr::map_chr(works_raw, "doi",              .default = NA_character_),
    cited_by_count   = purrr::map_int(works_raw, "cited_by_count",   .default = NA_integer_),
    is_oa            = purrr::map_lgl(works_raw, c("open_access", "is_oa"),     .default = NA),
    oa_status        = purrr::map_chr(works_raw, c("open_access", "oa_status"), .default = NA_character_)
  )

  cat("  Found", nrow(works), "first-author articles from", from_date, "\n")
  works
}

# -----------------------------------------------------------------------------
# Load supporting data
# -----------------------------------------------------------------------------

institution_names <- readr::read_csv(
  here::here("data", "raw_data", "institution_names.csv"), show_col_types = FALSE
)

# LDP target artifacts — produced by data/raw_data/scripts/get_ldp_targets.R
ldp_exclusion <- readr::read_csv(
  here::here("data", "raw_data", "ldp_exclusion_names.csv"), show_col_types = FALSE
)
LDP_names <- ldp_exclusion$firstname_lastname

N_by_inst <- readr::read_csv(
  here::here("data", "raw_data", "ldp_n_target.csv"), show_col_types = FALSE
)

eee_field_ids <- readRDS(here::here("data", "raw_data", "ldp_eee_field_ids.rds"))

cat(sprintf("LDP exclusion list: %d names\n", length(LDP_names)))
cat("Target sample sizes by institution:\n")
print(N_by_inst)
cat(sprintf(
  "\nEEE field IDs loaded (%d fields):\n%s\n",
  length(eee_field_ids),
  paste(eee_field_ids, collapse = "\n")
))

# Normalize field IDs to bare numeric form (e.g. "23"), handling both full
# URLs like "https://openalex.org/fields/23" and bare integers.
# Cap at top 3 fields to limit Phase 1 result volume.
eee_field_filter <- paste(
  stringr::str_extract(head(eee_field_ids, 3), "[^/]+$"),
  collapse = "|"
)
cat(sprintf("Field filter string for API: %s\n", eee_field_filter))

# -----------------------------------------------------------------------------
# Step 1: Resolve institution names → OpenAlex institution IDs (one call each)
# -----------------------------------------------------------------------------

cat("\n--- Resolving institution OpenAlex IDs ---\n")

inst_id_map <- purrr::map_dfr(institution_names$institution_name, function(inst_name) {
  tryCatch({
    res <- oa_fetch(
      entity  = "institutions",
      search  = inst_name,
      options = list(select = c("id", "display_name")),
      verbose = FALSE
    )
    Sys.sleep(api_delay)
    if (is.null(res) || nrow(res) == 0) {
      cat(sprintf("  WARNING: No OpenAlex ID found for: %s\n", inst_name))
      return(tibble(institution_name = inst_name, openalex_id = NA_character_))
    }
    cat(sprintf("  %s → %s (%s)\n", inst_name, res$id[1], res$display_name[1]))
    tibble(institution_name = inst_name, openalex_id = res$id[1])
  }, error = function(e) {
    cat(sprintf("  ERROR for %s: %s\n", inst_name, conditionMessage(e)))
    tibble(institution_name = inst_name, openalex_id = NA_character_)
  })
})

# **NOTE** add U Montreal and U Quebec a Montreal codes manually:

inst_id_map[inst_id_map$institution_name == "Universite de Montreal", "openalex_id"] <- "https://openalex.org/I70931966"
inst_id_map[inst_id_map$institution_name == "Universite du Quebec a Montreal", "openalex_id"] <- "https://openalex.org/I159129438"

# Deduplicate: if institution_names.csv maps multiple abbreviations to the same
# full name (e.g. UBC and UBCO both → "University of British Columbia"), keep
# only the first row to avoid length > 1 in the openalex_id lookup below
inst_id_map <- inst_id_map %>%
  dplyr::distinct(institution_name, .keep_all = TRUE)


# -----------------------------------------------------------------------------
# Step 2: Build EEE candidate pool (thesis years 2020-2022, LDP names excluded)
# -----------------------------------------------------------------------------

classified_files <- list.files(
  here::here("data", "processed_data", "classified"),
  pattern = "\\.csv$", full.names = TRUE
)

EEE_theses <- purrr::map(classified_files, function(f) {
  tryCatch(
    readr::read_csv(f, show_col_types = FALSE) %>%
      dplyr::select(institution, institution_fullname, firstname_lastname,
                    year, program, Category, prob_EEE) %>%
      dplyr::filter(Category == "EEE", prob_EEE >= min_prob_EEE, year %in% thesis_years),
    error = function(e) {
      cat("  ERROR reading", basename(f), ":", e$message, "\n"); NULL
    }
  )
}) %>% purrr::compact()

# Guard: if no files loaded successfully, stop with an informative message rather
# than a cryptic size-mismatch error. The classified CSVs must be the post-classifier
# outputs of 03_apply_classifier.R from LDP_thesis_classification (containing
# Category and prob_EEE columns), not the pre-classification clean CSVs.
if (length(EEE_theses) == 0) {
  stop(
    "No classified thesis files loaded from data/processed_data/classified/.\n",
    "  Ensure this directory contains the classified CSV outputs of\n",
    "  03_apply_classifier.R from the LDP_thesis_classification project\n",
    "  (files must include Category and prob_EEE columns).\n",
    "  Found ", length(classified_files), " CSV file(s) but none had the required columns."
  )
}

all_EEE_candidates <- dplyr::bind_rows(EEE_theses) %>%
  dplyr::filter(!is.na(firstname_lastname), nchar(trimws(firstname_lastname)) > 0) %>%
  dplyr::distinct(institution_fullname, firstname_lastname, .keep_all = TRUE) %>%
  dplyr::filter(!(firstname_lastname %in% LDP_names)) %>%
  dplyr::mutate(name_key = name_keys(firstname_lastname))

cat(sprintf(
  "\nEEE candidate pool: %d authors across %d institutions (thesis years %s)\n",
  nrow(all_EEE_candidates),
  dplyr::n_distinct(all_EEE_candidates$institution_fullname),
  paste(range(thesis_years), collapse = "-")
))

# -----------------------------------------------------------------------------
# Step 3: Load checkpoint
# -----------------------------------------------------------------------------

checkpoint_file <- here::here("data", "processed_data", "comparator_checkpoint.rds")

if (file.exists(checkpoint_file)) {
  all_comparator_results <- readRDS(checkpoint_file)
  cat(sprintf("\nResuming from checkpoint: %d institution(s) already complete\n",
              length(all_comparator_results)))
} else {
  all_comparator_results <- list()
}

# -----------------------------------------------------------------------------
# Step 4: Per-institution loop
# -----------------------------------------------------------------------------

for (i in seq_len(nrow(N_by_inst))) {

  inst_name <- N_by_inst$institution_name[i]
  N_target  <- N_by_inst$N_target[i]

  if (inst_name %in% names(all_comparator_results)) {
    cat(sprintf("\nSkipping %s (already in checkpoint)\n", inst_name)); next
  }

  cat(sprintf(
    "\n%s\n=== %s | N_target = %d ===\n%s\n",
    strrep("=", 60), inst_name, N_target, strrep("=", 60)
  ))

  # Look up OpenAlex institution ID
  openalex_id <- inst_id_map$openalex_id[inst_id_map$institution_name == inst_name]
  if (length(openalex_id) == 0 || is.na(openalex_id)) {
    cat("  No OpenAlex institution ID; skipping.\n")
    all_comparator_results[[inst_name]] <- tibble()
    saveRDS(all_comparator_results, checkpoint_file)
    next
  }
  # OpenAlex filter accepts the short form (e.g. "I27837315")
  inst_short_id <- stringr::str_extract(openalex_id, "I\\d+")

  # Candidate pool for this institution
  inst_candidates <- all_EEE_candidates %>%
    dplyr::filter(institution_fullname == inst_name)

  if (nrow(inst_candidates) == 0) {
    cat("  No EEE candidates for this institution; skipping.\n")
    all_comparator_results[[inst_name]] <- tibble()
    saveRDS(all_comparator_results, checkpoint_file)
    next
  }
  cat(sprintf("  %d EEE candidates available\n", nrow(inst_candidates)))

  # ── Phase 1: institution-level batch works query ──────────────────────────
  cat("  Phase 1: institution works query...\n")

  phase1_url <- paste0(
    "https://api.openalex.org/works",
    "?filter=authorships.institutions.id:", inst_short_id,
    ",primary_topic.field.id:", eee_field_filter,
    ",from_publication_date:", min_pub_date,
    "&select=id,authorships",
    "&per-page=200",
    "&mailto=", mailto
  )
  cat(sprintf("  Phase 1 URL (%d chars): %s\n", nchar(phase1_url), phase1_url))

  phase1_raw <- tryCatch(
    oa_request(query_url = phase1_url),
    error = function(e) { cat("  Phase 1 error:", conditionMessage(e), "\n"); list() }
  )
  Sys.sleep(api_delay)

  if (length(phase1_raw) == 0) {
    cat("  Phase 1 returned no results; skipping institution.\n")
    all_comparator_results[[inst_name]] <- tibble()
    saveRDS(all_comparator_results, checkpoint_file)
    next
  }

  phase1_df <- oa2df(phase1_raw, entity = "works")
  cat(sprintf("  Phase 1: %d works returned\n", nrow(phase1_df)))

  # Extract unique first-author (display name, author ID) pairs from Phase 1.
  # author_position:first is NOT a valid OpenAlex API filter, so the full
  # authorships list is returned and filtered to first-authors here in R.
  # NOTE: oa2df authorships columns include au_id, au_display_name, author_position
  # (verify against your openalexR version if this step errors)
  first_authors <- tryCatch({
    # Drop outer `id` (work ID) before unnesting: the authorships tibble also
    # has an `id` column, which would cause a name conflict in tidyr::unnest().
    # After unnesting, normalise column names: openalexR versions may use
    # id/display_name instead of au_id/au_display_name — rename safely with
    # any_of() so either convention works.
    phase1_df %>%
      dplyr::select(authorships) %>%
      tidyr::unnest(authorships) %>%
      dplyr::rename(dplyr::any_of(c(au_id           = "id",
                                    au_display_name = "display_name"))) %>%
      dplyr::filter(author_position == "first") %>%
      dplyr::select(au_id, au_display_name) %>%
      dplyr::distinct() %>%
      dplyr::filter(!is.na(au_id), !is.na(au_display_name)) %>%
      dplyr::mutate(name_key = name_keys(au_display_name))
  }, error = function(e) {
    cat("  ERROR extracting first authors:", conditionMessage(e), "\n")
    cat("  Actual authorships columns:",
        paste(names(phase1_df$authorships[[1]]), collapse = ", "), "\n")
    tibble(au_id = character(), au_display_name = character(), name_key = character())
  })

  cat(sprintf("  Unique first authors in Phase 1 results: %d\n", nrow(first_authors)))

  # ── Fetch author metadata: works_count + topics for all Phase 1 authors ────
  # Used for: (1) works_count filter to exclude likely non-students,
  #           (2) topic-score tie-breaker when multiple au_ids share a name_key
  cat(sprintf("  Fetching author metadata for %d Phase 1 authors...\n", nrow(first_authors)))

  # Strip author IDs to short form (e.g. https://openalex.org/A123 → A123)
  author_ids <- unique(na.omit(stringr::str_extract(first_authors$au_id, "A\\d+")))

  if (length(author_ids) == 0) {
    cat("  No first-author IDs resolved from Phase 1; skipping institution.\n")
    all_comparator_results[[inst_name]] <- tibble()
    saveRDS(all_comparator_results, checkpoint_file)
    next
  }
  n_auth_batch     <- ceiling(length(author_ids) / ldp_batch_size)
  author_list      <- vector("list", n_auth_batch)

  for (b in seq_len(n_auth_batch)) {
    idx    <- ((b - 1) * ldp_batch_size + 1) : min(b * ldp_batch_size, length(author_ids))
    id_str <- paste(author_ids[idx], collapse = "|")

    auth_url <- paste0(
      "https://api.openalex.org/authors",
      "?filter=ids.openalex:", id_str,
      "&select=id,works_count,topics",
      "&per-page=200",
      "&mailto=", mailto
    )

    raw <- tryCatch(
      oa_request(query_url = auth_url),
      error = function(e) { cat("  Author batch", b, "error:", conditionMessage(e), "\n"); list() }
    )
    if (length(raw) > 0)
      author_list[[b]] <- oa2df(raw, entity = "authors")
    Sys.sleep(api_delay)
  }

  author_meta <- dplyr::bind_rows(purrr::compact(author_list))

  # Apply works_count filter
  author_meta_filtered <- author_meta %>%
    dplyr::filter(works_count <= max_num_pubs)

  cat(sprintf(
    "  Author metadata: %d fetched, %d pass works_count filter (<= %d)\n",
    nrow(author_meta), nrow(author_meta_filtered), max_num_pubs
  ))

  first_authors_filtered <- first_authors %>%
    dplyr::filter(au_id %in% author_meta_filtered$id)

  # ── Name-match with topic-score tie-breaker ───────────────────────────────
  # Where multiple au_ids map to the same candidate name_key, retain the one
  # with the highest count of target_disciplines matches in their topics.
  # The many-to-many relationship here is expected: multiple OpenAlex author
  # profiles can share the same name_key (same first initial + last name), and
  # multiple thesis candidates can share a name_key for the same reason.
  # slice_max below collapses each firstname_lastname to one best-match au_id.
  # NOTE: author topics from oa2df have columns field_display_name and
  # subfield_display_name; verify these names if this step errors.
  confirmed_matches <- inst_candidates %>%
    dplyr::inner_join(
      first_authors_filtered %>% dplyr::select(au_id, name_key),
      by = "name_key",
      relationship = "many-to-many"
    ) %>%
    dplyr::left_join(
      author_meta_filtered %>% dplyr::select(id, topics),
      by = c("au_id" = "id")
    ) %>%
    dplyr::mutate(
      topic_score = purrr::map_int(topics, function(t) {
        if (is.null(t) || nrow(t) == 0) return(0L)
        # type column distinguishes "field", "subfield", "topic", "domain"
        sum(
          t$display_name[t$type %in% c("field", "subfield")] %in% target_disciplines,
          na.rm = TRUE
        )
      })
    ) %>%
    dplyr::group_by(firstname_lastname) %>%
    dplyr::slice_max(order_by = topic_score, n = 1, with_ties = FALSE) %>%
    dplyr::ungroup() %>%
    dplyr::select(firstname_lastname, au_id, program)

  cat(sprintf("  Candidates matched after disambiguation: %d\n", nrow(confirmed_matches)))

  if (nrow(confirmed_matches) == 0) {
    cat("  No matches found; skipping institution.\n")
    all_comparator_results[[inst_name]] <- tibble()
    saveRDS(all_comparator_results, checkpoint_file)
    next
  }

  # ── Phase 2: per-match targeted works fetch ───────────────────────────────
  # Collect oversample_factor * N_target authors to ensure year-matched pairing
  # at analysis stage. Publication year is preserved in the output.
  n_collect <- N_target * oversample_factor
  cat(sprintf("  Phase 2: fetching publications for up to %d authors (N_target=%d × %dx oversample)...\n",
              n_collect, N_target, oversample_factor))

  inst_hits <- list()
  n_found   <- 0

  for (j in seq_len(nrow(confirmed_matches))) {

    if (n_found >= n_collect) break

    cand   <- confirmed_matches[j, ]
    result <- get_works_by_author_id(
      author_id   = cand$au_id,
      author_name = cand$firstname_lastname
    )

    if (!is.null(result) && nrow(result) > 0) {
      result <- result %>%
        dplyr::mutate(
          searched_name    = cand$firstname_lastname,
          institution_name = inst_name,
          program          = cand$program,
          .before = 1
        ) %>%
        dplyr::filter(!is_noneee_title(title))

      if (nrow(result) > 0) {
        inst_hits[[cand$firstname_lastname]] <- result
        n_found <- n_found + 1
        cat(sprintf("  >> Hit %d / %d for %s\n", n_found, n_collect, inst_name))
      } else {
        cat(sprintf("  >> %s: all publications filtered by keyword; not counted.\n",
                    cand$firstname_lastname))
      }
    }
  }

  inst_result <- if (length(inst_hits) > 0) dplyr::bind_rows(inst_hits) else tibble()

  cat(sprintf(
    "\n  %s complete: %d / %d authors collected (N_target=%d; oversample pool for year-matching)\n",
    inst_name, n_found, n_collect, N_target
  ))

  all_comparator_results[[inst_name]] <- inst_result
  saveRDS(all_comparator_results, checkpoint_file)
  cat("  Checkpoint saved.\n")
}

# -----------------------------------------------------------------------------
# Combine results and write output
# -----------------------------------------------------------------------------

comparator_pubs <- dplyr::bind_rows(
  purrr::keep(all_comparator_results, ~ nrow(.x) > 0)
)

readr::write_csv(
  comparator_pubs,
  here::here("data", "processed_data", "comparator_author_publications.csv")
)

cat("\n=== COMPLETE ===\n")
cat(sprintf("Output: data/processed_data/comparator_author_publications.csv\n"))
cat(sprintf("Total comparator authors with publications: %d\n",
            dplyr::n_distinct(comparator_pubs$searched_name)))
cat(sprintf("Total works: %d\n", nrow(comparator_pubs)))

cat("\nBy institution:\n")
comparator_pubs %>%
  dplyr::group_by(institution_name) %>%
  dplyr::summarise(
    n_found = dplyr::n_distinct(searched_name),
    n_works = dplyr::n(),
    .groups = "drop"
  ) %>%
  dplyr::left_join(N_by_inst, by = "institution_name") %>%
  dplyr::rename(n_target = N_target) %>%
  print()
