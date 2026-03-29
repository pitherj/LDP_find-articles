# LDP Find Articles

Retrieves first-author publications for Living Data Project (LDP) student cohorts and matched comparator authors via the OpenAlex API, as part of a quasi-experimental study assessing FAIR data compliance among LDP graduates.

**Authors**: Jason Pither, Mathew Vis-Dunbar, Sandra Emry, David Hunt, Diane Srivastava

**Contact**: Jason Pither — jason.pither@ubc.ca | [ORCID](https://orcid.org/0000-0002-7490-6839) | UBC Okanagan

---

## Background

The Living Data Project (LDP) trained Canadian graduate students in open science practices through four annual 1-credit modules (2020–2022). This project retrieves peer-reviewed, first-author publications for LDP student participants and institution-matched comparator students (identified by the companion [LDP_thesis_classification](https://github.com/pitherj/LDP_thesis_classification) pipeline) in preparation for FAIR compliance scoring.

The publication search applies a per-student minimum date: because LDP courses were offered each fall, a student who completed the course in year *Y* is only expected to have applied the training to work begun afterward. Qualifying publications therefore start on January 1 of year *Y* + 1 (e.g., 2021-01-01 for 2020 cohort students).

---

## Quick Start

> **Prerequisites**: See [Prerequisites](#prerequisites) section. Private data files must be in place before running any script.

Run scripts in the following order:

```r
# Step 0 (private — restricted access)
source("scripts/private/extract_ldp_student_names.R")   # produces ldp_student_names_2020-2022.csv
source("scripts/private/get_ldp_publications.R")         # produces LDP_author_publications.csv

# Step 1 — derive LDP target artifacts
source("scripts/01_get_ldp_targets.R")

# Handoff: populate data/processed_data/classified/ from LDP_thesis_classification
# (output of 03_apply_classifier.R in that project)

# Step 2 — retrieve comparator author publications
source("scripts/02_get_comparator_authors.R")
```

---

## Pipeline Workflow

```mermaid
flowchart TD
    A["LDP-MODULES_ALL_2020-2022.csv\nPrivate LDP course roster"]
    B["Training_event_data.csv\nCourse year lookup"]
    C["extract_ldp_student_names.R\nFilters roster; retains ldp_year\nprivate"]
    D["ldp_student_names_2020-2022.csv\nUnique students + enrollment year"]
    E["get_ldp_publications.R\nOpenAlex search, per-student date cutoff\nprivate"]
    F["institution_names.csv\nInstitution name lookup"]
    G["LDP_author_publications.csv\nFirst-author publications for LDP students"]
    H["01_get_ldp_targets.R\nDerives exclusion list, N_target, EEE field IDs"]
    I["ldp_exclusion_names.csv\nAll enrolled LDP student names"]
    J["ldp_n_target.csv\nTarget N per institution"]
    K["ldp_eee_field_ids.rds\nOpenAlex field IDs for EEE"]
    L["classified/ CSVs\nInput from LDP_thesis_classification"]
    M["02_get_comparator_authors.R\nRetrieves comparator publications via OpenAlex"]
    N["comparator_author_publications.csv\nFirst-author publications for comparators"]

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
│   └── private/                       # Restricted-access scripts (private LDP roster data)
│       ├── extract_ldp_student_names.R  # Filters roster; adds ldp_year per student
│       └── get_ldp_publications.R       # OpenAlex search with per-student date cutoffs
└── data/
    ├── raw_data/                        # Private LDP source data + derived lookup files
    │   ├── LDP-MODULES_ALL_2020-2022.csv  # [private] Full course roster
    │   ├── Training_event_data.csv        # [private] Course year/title lookup
    │   ├── institution_names.csv          # Institution abbreviation → full name
    │   ├── ldp_student_names_2020-2022.csv  # Unique students with ldp_year
    │   ├── LDP_author_publications.csv    # First-author pubs for LDP students
    │   ├── ldp_exclusion_names.csv        # All enrolled LDP student names (exclusion list)
    │   ├── ldp_n_target.csv               # Target comparator N per institution
    │   └── ldp_eee_field_ids.rds          # OpenAlex field IDs for EEE scope filter
    └── processed_data/
        ├── classified/                  # Input: classified thesis CSVs (from LDP_thesis_classification)
        ├── comparator_author_publications.csv   # First-author pubs for comparator students
        └── comparator_checkpoint.rds    # Progress checkpoint for resumable comparator search
```

---

## Key Outputs

| File | Description |
|---|---|
| `data/raw_data/ldp_student_names_2020-2022.csv` | Unique LDP students with institution, program, and `ldp_year` |
| `data/raw_data/LDP_author_publications.csv` | First-author articles for LDP student-authors (OpenAlex) |
| `data/processed_data/comparator_author_publications.csv` | First-author articles for matched comparator authors |

---

## Documentation

| File | Contents |
|---|---|
| `DATA-DICTIONARY.md` | Column-level descriptions for all data files in `data/` |
| [LDP_pre-registration](../LDP_pre-registration/LDP_preregistration_OSF.md) | Full study pre-registration including sampling, inclusion criteria, and analysis plan |
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
