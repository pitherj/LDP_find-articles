# get_ldp_publications.R
#
# Purpose: Takes a CSV of LDP author names and retrieves their first-author
#          articles from OpenAlex, applying filters to disambiguate authors
#          and exclude high-volume (non-student) profiles.
#
# Inputs:  data/raw_data/ldp_student_names_2020-2022.csv
#          data/raw_data/institution_names.csv
# Outputs: data/raw_data/LDP_author_publications.csv
#
# Author: Jason Pither, with help from Claude (Sonnet 4.6)
# Updated: 2026-02-19

# Load the requried packages
library(openalexR)
library(dplyr)
library(readr)
library(here)
library(purrr)

# Provide email to enter the "polite pool" in OpenAlex for better rate limits

options(openalexR.mailto = "jason.pither@ubc.ca")

# Publication date filter (only works from this date onwards)
min_pub_date <- "2020-01-01"

# Rate limit delay (seconds between API calls)
# OpenAlex limit is 10 requests/second; 0.15s = ~6.7 req/s (safe margin)
api_delay <- 0.15

# Maximum total works count for a candidate author; used to exclude high-volume
# researchers who are unlikely to be students
max_num_pubs <- 30


# -----------------------------------------------------------------------------
# Define which fields to retrieve (workaround for duplicate 'id' column bug)
# By explicitly selecting fields, we avoid the problematic 'ids' nested object
# See: https://docs.openalex.org/api-entities/works/work-object for all fields
# -----------------------------------------------------------------------------

works_fields <- c(
  "id",
  "display_name",
  "title",
  "publication_date",
  "publication_year", 
  "type",
  "doi",
  "cited_by_count",
  "is_oa",
  "oa_status"
)

author_fields <- c(
  "id",
  "display_name",
  "orcid",
  "works_count",
  "cited_by_count",
  "last_known_institutions",
  "topics"
)

# Fields/domains used to identify ecology/evolution/environment authors
# Matched against the 'field' and 'domain' labels in OpenAlex author topics
target_disciplines <- c(
  "Ecology",
  "Evolutionary Biology",
  "Environmental Science",
  "Earth and Planetary Sciences",
  "Agricultural and Biological Sciences"
)

# -----------------------------------------------------------------------------
# Function: Search for author and retrieve their works
# -----------------------------------------------------------------------------

get_author_works <- function(author_name, from_date = "2020-01-01", delay = api_delay,
                             max_num_pubs = 30) {
  
  cat("\n", strrep("-", 60), "\n", sep = "")
  cat("Searching for author:", author_name, "\n")
  
  # Step 1: Find author(s) matching the name
  # Using select to avoid the duplicate id column bug
  author_info <- tryCatch({
    oa_fetch(
      entity = "authors",
      search = author_name,
      options = list(select = author_fields),
      verbose = FALSE
    )
  }, error = function(e) {
    cat("  Error searching for author:", conditionMessage(e), "\n")
    return(NULL)
  })
  
  Sys.sleep(delay)
  
  if (is.null(author_info) || nrow(author_info) == 0) {
    cat("  No author found for:", author_name, "\n")
    return(NULL)
  }
  
  cat("  Found", nrow(author_info), "matching author(s)\n")
  
  # Step 2: Filter to plausible name matches
  # Require: last token of display_name matches searched last name (case-insensitive)
  #          and first token starts with the same letter as searched first name
  searched_first_initial <- tolower(substr(trimws(sub(" .*", "", author_name)), 1, 1))
  searched_last <- tolower(trimws(sub(".* ", "", author_name)))
  
  name_match <- map_lgl(author_info$display_name, function(dn) {
    tokens <- strsplit(trimws(dn), "\\s+")[[1]]
    if (length(tokens) < 2) return(FALSE)
    tolower(tokens[length(tokens)]) == searched_last &&
      tolower(substr(tokens[1], 1, 1)) == searched_first_initial
  })
  
  n_before <- nrow(author_info)
  author_info <- author_info[name_match, ]
  cat("  After name filtering:", nrow(author_info), "of", n_before, "candidates retained\n")
  
  if (nrow(author_info) == 0) {
    cat("  No candidates remain after name filtering for:", author_name, "\n")
    return(NULL)
  }
  
  # Step 3: Drop candidates with more works than expected for a student
  if (nrow(author_info) > 1) {
    n_before <- nrow(author_info)
    author_info <- author_info[author_info$works_count <= max_num_pubs, ]
    cat("  After publication count filter (max", max_num_pubs, "):",
        nrow(author_info), "of", n_before, "candidates retained\n")
    
    if (nrow(author_info) == 0) {
      cat("  No candidates remain after publication count filter for:", author_name, "\n")
      return(NULL)
    }
  }
  
  # Step 4: If >1 candidate, fetch all works per candidate and filter by institution
  if (nrow(author_info) > 1) {
    inst_names <- institution_names$institution_name
    
    has_inst_match <- map_lgl(author_info$id, function(aid) {
      candidate_works <- tryCatch({
        oa_fetch(
          entity = "works",
          author.id = aid,
          options = list(select = c("id", "authorships")),
          verbose = FALSE
        )
      }, error = function(e) NULL)
      
      Sys.sleep(delay)
      
      if (is.null(candidate_works) || nrow(candidate_works) == 0) return(FALSE)
      
      any(map_lgl(candidate_works$authorships, function(a) {
        if (is.null(a) || nrow(a) == 0) return(FALSE)
        focal_rows <- a[map_lgl(a$display_name, function(dn) {
          tokens <- strsplit(trimws(dn), "\\s+")[[1]]
          if (length(tokens) < 2) return(FALSE)
          tolower(tokens[length(tokens)]) == searched_last &&
            tolower(substr(tokens[1], 1, 1)) == searched_first_initial
        }), ]
        if (nrow(focal_rows) == 0) return(FALSE)
        any(map_lgl(focal_rows$affiliations, function(af) {
          if (is.null(af) || nrow(af) == 0) return(FALSE)
          any(af$display_name %in% inst_names, na.rm = TRUE)
        }))
      }))
    })
    
    n_before <- nrow(author_info)
    author_info <- author_info[has_inst_match, ]
    cat("  After institution filtering:", nrow(author_info), "of", n_before,
        "candidates retained\n")
    
    if (nrow(author_info) == 0) {
      cat("  No candidates remain after institution filtering for:", author_name, "\n")
      return(NULL)
    }
  }
  
  # Step 5: If >1 candidate remains, select by topic score
  if (nrow(author_info) > 1) {
    topic_scores <- map_int(author_info$topics, function(t) {
      if (is.null(t) || nrow(t) == 0) return(0L)
      sum(t$display_name[t$type %in% c("subfield", "field", "domain")] %in% target_disciplines,
          na.rm = TRUE)
    })
    
    best_idx <- which.max(topic_scores)
    
    if (topic_scores[best_idx] == 0) {
      cat("  Warning: no topic match found for any candidate; using first remaining match\n")
      best_idx <- 1L
    } else {
      cat("  Topic screening selected candidate", best_idx, "of", nrow(author_info),
          "(topic score:", topic_scores[best_idx], ")\n")
    }
    author_info <- author_info[best_idx, ]
  }
  
  author_id <- author_info$id[1]
  author_display <- author_info$display_name[1]
  works_count <- author_info$works_count[1]
  
  author_orcid <- if ("orcid" %in% names(author_info)) {
    author_info$orcid[1]
  } else {
    NA_character_
  }
  
  cat("  Using:", author_display, "\n")
  cat("  OpenAlex ID:", author_id, "\n")
  cat("  ORCID:", ifelse(is.na(author_orcid), "Not found", author_orcid), "\n")
  cat("  Total works in OpenAlex:", works_count, "\n")
  
  # Step 6: Fetch full works for selected author
  # Step 6a: Fetch content fields for works
  # Authorships fetched separately (Step 6b) to avoid URL length limits
  works_raw <- tryCatch({
    oa_fetch(
      entity = "works",
      author.id = author_id,
      from_publication_date = from_date,
      output = "list",
      verbose = FALSE
    )
  }, error = function(e) {
    cat("  Error fetching works:", conditionMessage(e), "\n")
    return(NULL)
  })
  
  works <- tibble(
    id              = map_chr(works_raw, "id", .default = NA_character_),
    display_name    = map_chr(works_raw, "display_name", .default = NA_character_),
    title           = map_chr(works_raw, "title", .default = NA_character_),
    publication_date = map_chr(works_raw, "publication_date", .default = NA_character_),
    publication_year = map_int(works_raw, "publication_year", .default = NA_integer_),
    type            = map_chr(works_raw, "type", .default = NA_character_),
    doi             = map_chr(works_raw, "doi", .default = NA_character_),
    cited_by_count  = map_int(works_raw, "cited_by_count", .default = NA_integer_),
    is_oa           = map_lgl(works_raw, c("open_access", "is_oa"), .default = NA),
    oa_status       = map_chr(works_raw, c("open_access", "oa_status"), .default = NA_character_)
  )
  
  # get first author articles only
  # Identify which works are articles with focal author in first position
  is_first_author_article <- map_lgl(works_raw, function(w) {
    if (!identical(w$type, "article")) return(FALSE)
    auths <- w$authorships
    if (is.null(auths) || length(auths) == 0) return(FALSE)
    any(map_lgl(auths, function(a) {
      identical(a$author_position, "first") &&
        identical(a$author$id, author_id)
    }))
  })
  
  works <- works[is_first_author_article, ]
  Sys.sleep(delay)
  
  if (is.null(works) || nrow(works) == 0) {
    cat("  No works found from", from_date, "onwards\n")
    return(NULL)
  }
  
  cat("  Found", nrow(works), "works from", from_date, "onwards\n")
  
  # Step 6b: Fetch authorships separately and join by id
  works_authorships <- tryCatch({
    oa_fetch(
      entity = "works",
      author.id = author_id,
      from_publication_date = from_date,
      options = list(select = c("id", "authorships")),
      verbose = FALSE
    )
  }, error = function(e) {
    cat("  Warning: authorships fetch failed:", conditionMessage(e), "\n")
    return(NULL)
  })
  
  Sys.sleep(delay)
  
  # Step 7: Filter works by focal author's institution match
  if (!is.null(works_authorships) && nrow(works_authorships) > 0) {
    inst_names <- institution_names$institution_name
    keep <- map_lgl(works_authorships$authorships, function(a) {
      if (is.null(a) || nrow(a) == 0) return(FALSE)
      focal_rows <- a[map_lgl(a$display_name, function(dn) {
        tokens <- strsplit(trimws(dn), "\\s+")[[1]]
        if (length(tokens) < 2) return(FALSE)
        tolower(tokens[length(tokens)]) == searched_last &&
          tolower(substr(tokens[1], 1, 1)) == searched_first_initial
      }), ]
      if (nrow(focal_rows) == 0) return(FALSE)
      any(map_lgl(focal_rows$affiliations, function(af) {
        if (is.null(af) || nrow(af) == 0) return(FALSE)
        any(af$display_name %in% inst_names, na.rm = TRUE)
      }))
    })
    
    works <- works %>%
      filter(id %in% works_authorships$id[keep])
    
    cat("  After works-level affiliation filtering:", nrow(works), "works retained\n")
    
    if (nrow(works) == 0) {
      cat("  No works remain after works-level affiliation filtering\n")
      return(NULL)
    }
  } else {
    cat("  Warning: authorships unavailable; works-level affiliation filtering skipped\n")
  }
  
  # Add metadata columns
  works <- works %>%
    mutate(
      searched_name = author_name,
      matched_author_id = author_id,
      matched_author_name = author_display,
      matched_author_orcid = author_orcid,
      .before = 1
    )
  
  return(works)
}

# -----------------------------------------------------------------------------
# Main execution
# -----------------------------------------------------------------------------

# import institution name info
institution_names <- readr::read_csv(here::here("data", "raw_data", "institution_names.csv"))

# read in CSV of author names (includes institutions and program for most)

author_names <- readr::read_csv(here::here("data", "raw_data", "ldp_student_names_2020-2022.csv"))

# Create new field of author names (Firstname Lastname format; we did not collect full names unfortunately)
author_names <- author_names %>%
  mutate(firstname_lastname = paste(Train_First_Name, Train_Last_Name, sep = " "))

# add institution information
author_names <- dplyr::left_join(author_names, institution_names, join_by(Institution_ID == institution_abbrev))

# Create vector of author names (Firstname Lastname format)
firstname_lastname <- as.vector(author_names$firstname_lastname)

# Start search

cat("\n=== OpenAlex Publication Search ===\n")
cat("Searching for", length(firstname_lastname), "author(s)\n")
cat("Publication date filter: >=", min_pub_date, "\n")

# Fetch works for all authors
results_list <- map(
  firstname_lastname,
  ~ get_author_works(.x, from_date = min_pub_date, delay = api_delay,
                     max_num_pubs = max_num_pubs)
)

names(results_list) <- firstname_lastname
results_list_compact <- purrr::compact(results_list) # eliminates NULL elements

# -----------------------------------------------------------------------------
# Combine and display results
# -----------------------------------------------------------------------------

if (length(results_list_compact) > 0) {
  
  combined_results <- bind_rows(results_list_compact)
  
  cat("\n=== Summary ===\n")
  cat("Total works found:", nrow(combined_results), "\n\n")
  
  # Show authors with their ORCIDs
  cat("Authors found:\n")
  combined_results %>%
    distinct(searched_name, matched_author_name, matched_author_orcid) %>%
    print()
  
  cat("\nWorks per author:\n")
  combined_results %>%
    count(searched_name, name = "n_works") %>%
    print()
  
  cat("\n=== Sample Output (first 10 works) ===\n")
  
  # Select columns that exist (handles both full and fallback data)
  available_cols <- intersect(
    c("searched_name", "matched_author_name", "matched_author_orcid",
      "publication_year", "display_name", "doi", "cited_by_count", "is_oa"),
    names(combined_results)
  )
  
  combined_results %>%
    select(all_of(available_cols)) %>%
    head(10) %>%
    print()
  
} else {
  cat("\nNo results found for any author.\n")
  combined_results <- tibble()
}

# join institution information

combined_results <- dplyr::left_join(combined_results, author_names %>% 
  select(Institution_ID, program, firstname_lastname, institution_name), 
  join_by(searched_name == firstname_lastname))

# -----------------------------------------------------------------------------
# Export to CSV
# -----------------------------------------------------------------------------

readr::write_csv(combined_results, here::here("data", "raw_data", "LDP_author_publications.csv"))
