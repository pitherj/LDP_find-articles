# LDP Find Articles

Retrieves first-author publications for Living Data Project (LDP) student cohorts and matched comparator authors via the OpenAlex API, as part of a quasi-experimental study assessing FAIR data compliance among LDP graduates.

**Authors**: Jason Pither, Mathew Vis-Dunbar, Sandra Emry, David Hunt, Diane Srivastava

**AI usage**: Claude Code (Sonnet 4.6) contributed to coding and ensuring computational reproducibility, with oversight by Jason Pither.

**Contact**: Jason Pither — jason.pither@ubc.ca | [ORCID](https://orcid.org/0000-0002-7490-6839) | UBC Okanagan

## Project Timeline

| Date | Activity |
|------|----------|
| 2025-10-10 | Project conceived |
| 2026-01-06 | Ethics approval (UBC BREB) |
| 2026-01-13 | [Pre-registration](https://github.com/pitherj/LDP_pre-registration/blob/main/LDP_preregistration_OSF.md) initiated |
| 2026-01-13 | README created |
| 2026-03-30 | README last updated |

---

## Background

The Living Data Project (LDP) trained Canadian graduate students in open science practices through four annual 1-credit modules (2020–2022). This project retrieves peer-reviewed, first-author publications for LDP student participants and institution-matched comparator students (identified by the companion [LDP_thesis_classification](https://github.com/pitherj/LDP_thesis_classification) pipeline) in preparation for FAIR compliance scoring.

The pre-registration for this study is available [here](https://github.com/pitherj/LDP_pre-registration/blob/main/LDP_preregistration_OSF.md).
---

## Quick Start

> **Prerequisites**: See [Prerequisites](#prerequisites) section. Private data files must be in place before running any script.

Run scripts in the following order:

```r
# Step 0 (private — restricted access)
source("scripts/private/extract_ldp_student_names.R")   # produces processed_data/private/ldp_student_names_2020-2022.csv
source("scripts/private/get_ldp_publications.R")         # produces processed_data/private/LDP_author_publications.csv

# Step 1 — derive LDP target artifacts
source("scripts/01_get_ldp_targets.R")

# Handoff: populate data/processed_data/classified/ from LDP_thesis_classification
# (output of 03_apply_classifier.R in that project)

# Step 2 — retrieve comparator author publications
source("scripts/02_get_comparator_authors.R")

# Step 3 — clean and filter publications
source("scripts/03_clean_filter_publications.R")

# Step 4 — create blinded rater files
source("scripts/04_create_rater_files.R")
```

---

## Pipeline Workflow

```mermaid
flowchart TD
    A["LDP-MODULES_ALL_2020-2022.csv\nPrivate LDP course roster"]
    B["Training_event_data.csv\nCourse year lookup"]
    C["extract_ldp_student_names.R\nFilters roster; retains ldp_year\nprivate"]
    D["private/ldp_student_names_2020-2022.csv\nUnique students + enrollment year"]
    E["get_ldp_publications.R\nOpenAlex search, per-student date cutoff\nprivate"]
    F["institution_names.csv\nInstitution name lookup"]
    G["private/LDP_author_publications.csv\nFirst-author publications for LDP students"]
    H["01_get_ldp_targets.R\nDerives exclusion list, N_target, EEE field IDs"]
    I["private/ldp_exclusion_names.csv\nAll enrolled LDP student names"]
    J["ldp_n_target.csv\nTarget N per institution"]
    K["ldp_eee_field_ids.rds\nOpenAlex field IDs for EEE"]
    L["classified/ CSVs\nInput from LDP_thesis_classification"]
    M["02_get_comparator_authors.R\nRetrieves comparator publications via OpenAlex"]
    N["comparator_author_publications.csv\nFirst-author publications for comparators"]
    O["03_clean_filter_publications.R\nDeduplicates titles; filters to primary research"]
    P["private/LDP_publications_filtered.csv\nCleaned LDP publications"]
    Q["comparator_publications_filtered.csv\nCleaned comparator publications"]
    R["private/filter_log.txt\nStep-by-step exclusion report"]
    S["04_create_rater_files.R\nRandom pairing; blinded pub codes"]
    T["rater_publications.csv\nBlinded publications for raters"]
    U["private/rater_key.csv\nLinks pub codes to group/author/pair"]

    A --> C
    B --> C
    C --> D --> E
    F --> E
    E --> G --> H
    D --> H
    H --> I
    H --> J
    H --> K
    I --> M
    J --> M
    K --> M
    L --> M
    F --> M
    M --> N
    G --> O
    N --> O
    O --> P
    O --> Q
    O --> R
    P --> S
    Q --> S
    S --> T
    S --> U
```

---

## Prerequisites

### R packages

Key packages (install individually or manage via `renv` if a lockfile is added):

| Package | Purpose |
|---|---|
| `openalexR` | OpenAlex API queries |
| `dplyr`, `tidyr`, `purrr` | Data wrangling |
| `readr` | CSV I/O |
| `here` | Portable file paths |
| `stringr` | String matching for keyword filters |

### Private data files

The following source files contain personally identifiable information and are not tracked in version control. Place them in `data/raw_data/` before running private scripts:

| File | Description |
|---|---|
| `LDP-MODULES_ALL_2020-2022.csv` | Full LDP course roster with student names, institutions, program, and course IDs |
| `Training_event_data.csv` | Course ID to year/title lookup table |

All derived files that contain student names are written to `data/processed_data/private/` and are git-ignored. See the [Privacy note](#privacy-note) below.

### External handoff

Before running `02_get_comparator_authors.R`, populate `data/processed_data/classified/` with the per-institution classified thesis CSVs produced by the [`LDP_thesis_classification`](https://github.com/pitherj/LDP_thesis_classification) project (`03_apply_classifier.R` output).

---

## Project Structure

```
LDP_find-articles/
├── README.md
├── scripts/
│   ├── 01_get_ldp_targets.R           # Derives exclusion list, N_target, EEE field IDs
│   ├── 02_get_comparator_authors.R    # Retrieves comparator author publications via OpenAlex
│   ├── 03_clean_filter_publications.R # Deduplicates titles; filters to primary research
│   ├── 04_create_rater_files.R        # Random year+institution pairing; blinded rater CSV
│   └── private/                       # Restricted-access scripts (private LDP roster data)
│       ├── extract_ldp_student_names.R  # Filters roster; adds ldp_year per student
│       └── get_ldp_publications.R       # OpenAlex search with per-student date cutoffs
└── data/
    ├── raw_data/                        # Private LDP source data + non-sensitive lookup files
    │   ├── LDP-MODULES_ALL_2020-2022.csv  # [private] Full course roster
    │   ├── Training_event_data.csv        # [private] Course year/title lookup
    │   ├── institution_names.csv          # Institution abbreviation → full name
    │   ├── ldp_n_target.csv               # Target comparator N per institution
    │   └── ldp_eee_field_ids.rds          # OpenAlex field IDs for EEE scope filter
    └── processed_data/
        ├── classified/                          # Input: *_classified.csv files from LDP_thesis_classification (03_apply_classifier.R output)
        ├── private/                             # [private] Derived files containing LDP student names
        │   ├── ldp_student_names_2020-2022.csv  # Unique students with ldp_year
        │   ├── LDP_author_publications.csv      # First-author pubs for LDP students
        │   ├── ldp_exclusion_names.csv          # All enrolled LDP student names (exclusion list)
        │   ├── LDP_publications_filtered.csv    # LDP pubs after deduplication + primary-research filter
        │   ├── filter_log.txt                   # Step-by-step exclusion report from script 03
        │   └── rater_key.csv                    # Links blinded pub codes to group/author/pair info
        ├── comparator_author_publications.csv   # First-author pubs for comparator students (raw)
        ├── comparator_checkpoint.rds            # Progress checkpoint for resumable comparator search
        ├── comparator_publications_filtered.csv # Comparator pubs after deduplication + primary-research filter
        └── rater_publications.csv               # Blinded publication list for FAIR compliance raters
```

### Privacy note

All derived files that contain LDP student names (personally identifiable information) are isolated in `data/processed_data/private/`. This directory is git-ignored. Files in `data/raw_data/` that do not contain student names (`institution_names.csv`, `ldp_n_target.csv`, `ldp_eee_field_ids.rds`) remain there.

---

## Key Outputs

| File | Description |
|---|---|
| `data/processed_data/private/ldp_student_names_2020-2022.csv` | Unique LDP students with institution, program, and `ldp_year` |
| `data/processed_data/private/LDP_author_publications.csv` | First-author articles for LDP student-authors (OpenAlex, raw) |
| `data/processed_data/private/ldp_exclusion_names.csv` | All enrolled LDP student names (used to exclude from comparator pool) |
| `data/processed_data/private/LDP_publications_filtered.csv` | LDP publications after deduplication and primary-research filtering |
| `data/processed_data/private/filter_log.txt` | Record of every record dropped at each filtering step |
| `data/processed_data/comparator_author_publications.csv` | First-author articles for comparator authors (raw) |
| `data/processed_data/comparator_publications_filtered.csv` | Comparator publications after deduplication and primary-research filtering |
| `data/processed_data/rater_publications.csv` | Blinded publication list (pub_id, title, doi, year, openalex_url) — shared with raters |
| `data/processed_data/private/rater_key.csv` | Links each blinded pub_id to its pair, group, author, and institution — not shared with raters |

---

## Documentation

| File | Contents |
|---|---|
| `DATA-DICTIONARY.md` | Column-level descriptions for all data files in `data/` |
| [LDP_pre-registration](https://github.com/pitherj/LDP_pre-registration/blob/main/LDP_preregistration_OSF.md) | Full study pre-registration including sampling, inclusion criteria, and analysis plan |
| [LDP_thesis_classification](https://github.com/pitherj/LDP_thesis_classification) | Companion repo: EEE thesis classifier used to identify comparator candidates |

---

## How to Cite

[TODO: add DOI once preprint and data archive are available]

---

## License

[TODO: specify license]

---

## Acknowledgments

This work is part of the Living Data Project, funded through NSERC CREATE. Ethics approval: UBC Behavioural Research Ethics Board (UBC BREB), 2026-01-06.
