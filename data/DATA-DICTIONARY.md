# Data Directory — Data Dictionary

- **Directory**: `data/`
- **Dictionary type**: Mixed (input data, derived lookup files, pipeline outputs)
- **Last updated**: 2026-03-30
- **Maintained by**: Jason Pither (jason.pither@ubc.ca)

This directory contains all inputs and outputs for the LDP Find Articles pipeline. Derived files that contain personally identifiable information (LDP student names) are stored in `processed_data/private/` and are git-ignored. Non-sensitive lookup files (`institution_names.csv`, `ldp_n_target.csv`, `ldp_eee_field_ids.rds`) remain in `raw_data/`. All data — both raw and processed — are excluded from version control.

---

## Directory Structure

```
data/
├── DATA-DICTIONARY.md
├── raw_data/                                     # Private source data + non-sensitive lookup files
│   ├── LDP-MODULES_ALL_2020-2022.csv             # [PRIVATE] Full LDP course roster
│   ├── Training_event_data.csv                   # [PRIVATE] Course ID → year/title lookup
│   ├── institution_names.csv                     # Institution abbreviation → full name + OpenAlex ID
│   ├── ldp_n_target.csv                          # Derived: target comparator N per institution
│   └── ldp_eee_field_ids.rds                     # Derived: OpenAlex field IDs for EEE scope filter
└── processed_data/
    ├── classified/                               # Input: classified thesis CSVs (from LDP_thesis_classification, 03_apply_classifier.R output)
    │   ├── Alberta_classified.csv
    │   ├── Guelph_classified.csv
    │   ├── Manitoba_classified.csv
    │   ├── McGill_classified.csv
    │   ├── Regina_classified.csv
    │   ├── Toronto_classified.csv
    │   ├── UBC_classified.csv
    │   └── WLU_classified.csv
    ├── private/                                  # [PRIVATE] Derived files containing LDP student names
    │   ├── ldp_student_names_2020-2022.csv       # Derived: unique LDP students + ldp_year
    │   ├── LDP_author_publications.csv           # Derived: first-author pubs for LDP students
    │   ├── ldp_exclusion_names.csv               # Derived: all enrolled LDP names (exclusion list)
    │   ├── LDP_publications_filtered.csv         # Output of 03: LDP pubs after deduplication + primary-research filter
    │   ├── filter_log.txt                        # Output of 03: step-by-step exclusion report
    │   └── rater_key.csv                         # Output of 04: links blinded pub codes to group/author/pair
    ├── comparator_author_publications.csv        # Output of 02: first-author pubs for comparator students (raw)
    ├── comparator_checkpoint.rds                 # Checkpoint: resumable progress for comparator search
    ├── comparator_publications_filtered.csv      # Output of 03: comparator pubs after deduplication + primary-research filter
    └── rater_publications.csv                    # Output of 04: blinded publication list for FAIR compliance raters
```

---

## `raw_data/` — Source and Non-Sensitive Lookup Files

### LDP-MODULES_ALL_2020-2022.csv

- **Path**: `raw_data/LDP-MODULES_ALL_2020-2022.csv`
- **Type**: Input — private
- **Source**: LDP administrative records (internal)
- **Access**: Restricted to Jason Pither and Diane Srivastava
- **Git-ignored**: Yes — contains personally identifiable information (student names)

Complete enrollment roster for all LDP training events 2020–2022. Each row is one student enrollment record in one course offering. A student who enrolled in two qualifying modules will appear in two rows.

**Used by**: `scripts/private/extract_ldp_student_names.R`

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `Train_ID` | character | — | Course offering identifier (e.g., `2020_3`); joins to `Training_event_data.csv` | No |
| `Train_Last_Name` | character | — | Student last name | No |
| `Train_First_Name` | character | — | Student first name | No |
| `Institution_ID` | character | — | Institution abbreviation; joins to `institution_names.csv` | No |
| `MSc/PhD` | character | — | Degree program level: `MSc`, `PhD`, or blank if unknown | Yes |

---

### Training_event_data.csv

- **Path**: `raw_data/Training_event_data.csv`
- **Type**: Input — private
- **Source**: LDP administrative records (internal)
- **Access**: Restricted to Jason Pither and Diane Srivastava
- **Git-ignored**: Yes — accompanies private roster data

Lookup table mapping each course offering ID to its year and full title. Used by `extract_ldp_student_names.R` to identify qualifying modules (Productivity/Reproducibility and Scientific Data Management) and to associate each enrollment record with an LDP cohort year.

**Used by**: `scripts/private/extract_ldp_student_names.R`

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `Train_ID` | character | — | Course offering identifier (e.g., `2020_3`); primary key | No |
| `year` | integer | year | Calendar year in which the course was offered (2020–2023) | No |
| `Train_title` | character | — | Full course title (e.g., `LDP course - Productivity and reproducibility in ecology and evolution`) | No |

**Note**: Courses offered in 2023 are present in this file but are outside the 2020–2022 focal window filtered by the pipeline.

---

### institution_names.csv

- **Path**: `raw_data/institution_names.csv`
- **Type**: Input — non-sensitive
- **Source**: Manually compiled
- **Git-ignored**: No

Lookup table mapping institution abbreviations (used in roster data) to full institution names (used in OpenAlex queries and output files).

**Used by**: `scripts/private/get_ldp_publications.R`, `scripts/01_get_ldp_targets.R`, `scripts/02_get_comparator_authors.R`

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `institution_abbrev` | character | — | Short institution code matching `Institution_ID` in roster files (e.g., `UBC`, `McGill`) | No |
| `institution_name` | character | — | Full institution name as used in OpenAlex (e.g., `University of British Columbia`) | No |
| `openalex_id` | character | — | OpenAlex institution entity URL (e.g., `https://openalex.org/I141945490`); used by `02_get_comparator_authors.R` to avoid API institution-lookup calls | No |

**Note**: Some institutions have two rows (e.g., `UBCO` and `UBC` both map to `University of British Columbia`; `Toronto` and `UofT` both map to `University of Toronto`). This reflects how different cohorts recorded the same institution. The `openalex_id` is identical for both rows of any such pair.

---

## `processed_data/private/` — Private Derived Files (LDP Student Names)

All files in this subdirectory contain LDP student names (personally identifiable information). The directory is git-ignored.

---

### ldp_student_names_2020-2022.csv

- **Path**: `processed_data/private/ldp_student_names_2020-2022.csv`
- **Type**: Derived — private
- **Generated by**: `scripts/private/extract_ldp_student_names.R`
- **Git-ignored**: Yes — derived from private roster; contains student names

One row per unique student (deduplicated across course offerings and years). Students who appear in more than one qualifying course offering are collapsed to a single row retaining their earliest enrollment year as `ldp_year`.

**Used by**: `scripts/private/get_ldp_publications.R`, `scripts/01_get_ldp_targets.R`

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `Train_Last_Name` | character | — | Student last name | No |
| `Train_First_Name` | character | — | Student first name | No |
| `Institution_ID` | character | — | Institution abbreviation; joins to `institution_names.csv` | No |
| `program` | character | — | Degree program: `MSc`, `PhD`, or `NA` if not recorded | Yes |
| `ldp_year` | integer | year | Year of LDP course enrollment (2020, 2021, or 2022); determines per-student publication search cutoff (cutoff = `ldp_year + 1`, January 1) | No |

**Filters applied by generating script**: Retains only students enrolled in qualifying modules (titles matching `Productivity` or `data` in 2020–2022).

---

### LDP_author_publications.csv

- **Path**: `processed_data/private/LDP_author_publications.csv`
- **Type**: Derived — private
- **Generated by**: `scripts/private/get_ldp_publications.R`
- **Git-ignored**: Yes — derived from private roster; contains student names

First-author peer-reviewed articles retrieved from OpenAlex for LDP student-authors. Each row is one publication for one student-author. Students who authored multiple qualifying publications will have multiple rows. The search applies a per-student minimum publication date of January 1 of `ldp_year + 1`.

**Used by**: `scripts/01_get_ldp_targets.R`, `scripts/03_clean_filter_publications.R`

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `searched_name` | character | — | Name string submitted to OpenAlex (`Firstname Lastname`) | No |
| `matched_author_id` | character | — | OpenAlex author entity URL (e.g., `https://openalex.org/A5030652486`) | No |
| `matched_author_name` | character | — | Display name returned by OpenAlex for the matched author | No |
| `matched_author_orcid` | character | — | ORCID URL for the matched author; `NA` if not recorded in OpenAlex | Yes |
| `id` | character | — | OpenAlex work entity URL | No |
| `display_name` | character | — | Full article title as returned by OpenAlex | No |
| `title` | character | — | Full article title (duplicate of `display_name`) | No |
| `publication_date` | character | — | ISO 8601 date string (e.g., `2021-03-23`) | No |
| `publication_year` | integer | year | Four-digit publication year | No |
| `type` | character | — | OpenAlex work type; all rows are `article` | No |
| `doi` | character | — | DOI URL (e.g., `https://doi.org/10.1234/...`); `NA` if not available | Yes |
| `cited_by_count` | integer | count | Number of times cited according to OpenAlex at time of retrieval | No |
| `is_oa` | logical | — | `TRUE` if the work has any open-access version | No |
| `oa_status` | character | — | Open-access status: `gold`, `green`, `hybrid`, `bronze`, or `closed` | No |
| `Institution_ID` | character | — | Institution abbreviation from author roster; joins to `institution_names.csv` | No |
| `program` | character | — | Degree program: `MSc`, `PhD`, or `NA` | Yes |
| `institution_name` | character | — | Full institution name (joined from `institution_names.csv`) | No |

---

### ldp_exclusion_names.csv

- **Path**: `processed_data/private/ldp_exclusion_names.csv`
- **Type**: Derived — private
- **Generated by**: `scripts/01_get_ldp_targets.R`
- **Git-ignored**: Yes — contains student names

Complete list of enrolled LDP student names in `Firstname Lastname` format. Used by `02_get_comparator_authors.R` to exclude any LDP participant from the comparator candidate pool, regardless of whether they had a publication found in OpenAlex.

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `firstname_lastname` | character | — | Student name in `Firstname Lastname` format, as submitted to OpenAlex | No |

---

## `raw_data/` — Non-Sensitive Derived Files (continued)

### ldp_n_target.csv

- **Path**: `raw_data/ldp_n_target.csv`
- **Type**: Derived
- **Generated by**: `scripts/01_get_ldp_targets.R`
- **Git-ignored**: No (no PII; small file)

Target comparator sample size per institution, defined as the number of distinct LDP student-authors with at least one EEE-scope publication (after applying the non-EEE keyword filter). Used by `02_get_comparator_authors.R` to determine how many comparator authors to recruit per institution.

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `institution_name` | character | — | Full institution name | No |
| `N_target` | integer | count | Number of LDP student-authors with ≥1 qualifying EEE publication at this institution | No |

**Record count**: One row per institution with at least one qualifying LDP publication (8 institutions as of last run).

---

### ldp_eee_field_ids.rds

- **Path**: `raw_data/ldp_eee_field_ids.rds`
- **Type**: Derived
- **Generated by**: `scripts/01_get_ldp_targets.R`
- **Format**: R binary (RDS) — character vector
- **Git-ignored**: No

Character vector of OpenAlex field-level entity IDs (e.g., `https://openalex.org/fields/27`) that appear in at least 10% of keyword-filtered LDP publications. Used in Phase 1 of `02_get_comparator_authors.R` to restrict the institution-level works query to EEE-relevant fields, improving API efficiency.

Load with: `readRDS(here::here("data", "raw_data", "ldp_eee_field_ids.rds"))`

---

## `processed_data/classified/` — Input Thesis CSVs

- **Path**: `processed_data/classified/`
- **Type**: Input — handoff from companion project
- **Source**: [`LDP_thesis_classification`](https://github.com/pitherj/LDP_thesis_classification) — output of `03_apply_classifier.R`
- **Git-ignored**: Yes (data not version-controlled in this repo)

One CSV per LDP-affiliated institution containing EEE-classified thesis records for graduate students with thesis deposit years 2022–2024. These are the candidate comparator authors. Files must be the **post-classifier outputs** of `03_apply_classifier.R` (containing `Category` and `prob_EEE` columns) and placed here manually before running `02_get_comparator_authors.R`.

**Files**: `Alberta_classified.csv`, `Guelph_classified.csv`, `Manitoba_classified.csv`, `McGill_classified.csv`, `Regina_classified.csv`, `Toronto_classified.csv`, `UBC_classified.csv`, `WLU_classified.csv`

#### Column schema (all `*_classified.csv` files share this schema)

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `institution` | character | — | Institution abbreviation | No |
| `institution_fullname` | character | — | Full institution name | No |
| `title` | character | — | Thesis title | No |
| `abstract` | character | — | Thesis abstract text | Yes |
| `author` | character | — | Author name as recorded in the thesis registry (`Last, First.` format) | No |
| `firstname_lastname` | character | — | Author name in `Firstname Lastname` format (parsed from `author`) | No |
| `year` | integer | year | Thesis deposit year | No |
| `program` | character | — | Degree program: `MSc`, `PhD`, or `NA` | Yes |
| `Category` | character | — | Classifier output: `EEE` (ecology/evolution/environment) or `other` | No |
| `prob_EEE` | numeric | probability (0–1) | Classifier probability of EEE classification; used as confidence threshold | No |

**Filters applied by pipeline** (`02_get_comparator_authors.R`): Retains candidates with `Category == "EEE"` and `prob_EEE >= 0.75`, and thesis deposit year in 2022–2024. LDP enrolled students (listed in `ldp_exclusion_names.csv`) are removed before comparator selection.

---

## `processed_data/comparator_author_publications.csv`

- **Path**: `processed_data/comparator_author_publications.csv`
- **Type**: Output
- **Generated by**: `scripts/02_get_comparator_authors.R`
- **Git-ignored**: Yes (data not version-controlled)

First-author peer-reviewed articles retrieved from OpenAlex for matched comparator student-authors (non-LDP EEE graduate students). Each row is one publication for one comparator student-author. Comparator authors are collected at 2 × N_target per institution (oversampled) to ensure year-coverage across all publication years represented by LDP students at each institution. Year-matched pairing (LDP publication year = comparator publication year) is performed at analysis time using the `publication_year` column.

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `searched_name` | character | — | Comparator author name submitted to OpenAlex (`Firstname Lastname`) | No |
| `institution_name` | character | — | Full institution name | No |
| `program` | character | — | Degree program: `MSc`, `PhD`, or `NA` | Yes |
| `id` | character | — | OpenAlex work entity URL | No |
| `display_name` | character | — | Full article title as returned by OpenAlex | No |
| `title` | character | — | Full article title (duplicate of `display_name`) | No |
| `publication_date` | character | — | ISO 8601 date string | No |
| `publication_year` | integer | year | Four-digit publication year | No |
| `type` | character | — | OpenAlex work type; all rows are `article` | No |
| `doi` | character | — | DOI URL; `NA` if not available | Yes |
| `cited_by_count` | integer | count | Number of times cited according to OpenAlex at time of retrieval | No |
| `is_oa` | logical | — | `TRUE` if the work has any open-access version | No |
| `oa_status` | character | — | Open-access status: `gold`, `green`, `hybrid`, `bronze`, or `closed` | No |

---

## `processed_data/private/LDP_publications_filtered.csv`

- **Path**: `processed_data/private/LDP_publications_filtered.csv`
- **Type**: Output — private
- **Generated by**: `scripts/03_clean_filter_publications.R`
- **Git-ignored**: Yes — contains LDP student names

LDP student-author publications after four filtering layers: (0) investigator co-authorship exclusion; (1) title deduplication within and across authors; (2) OpenAlex type and paratext filtering (`is_paratext`, `type_crossref`); (3) title keyword screen for non-primary-research content. All columns from `processed_data/private/LDP_author_publications.csv` are retained, plus two additional columns added during metadata re-fetch.

#### Column schema

All columns from `processed_data/private/LDP_author_publications.csv` are present, plus:

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `is_paratext` | logical | — | OpenAlex flag; `TRUE` if the work is editorial, front-matter, or other paratext. Records with `TRUE` are excluded. | Yes |
| `type_crossref` | character | — | Crossref work type string (e.g., `journal-article`, `review-article`). Records with non-primary types are excluded. | Yes |

---

## `processed_data/comparator_publications_filtered.csv`

- **Path**: `processed_data/comparator_publications_filtered.csv`
- **Type**: Output
- **Generated by**: `scripts/03_clean_filter_publications.R`
- **Git-ignored**: Yes (data not version-controlled)

Comparator author publications after the same four filtering layers applied to the LDP publications. All columns from `processed_data/comparator_author_publications.csv` are retained, plus `is_paratext` and `type_crossref`.

#### Column schema

All columns from `processed_data/comparator_author_publications.csv` are present, plus `is_paratext` and `type_crossref` as described above for `LDP_publications_filtered.csv`.

---

## `processed_data/private/filter_log.txt`

- **Path**: `processed_data/private/filter_log.txt`
- **Type**: Output — plain text log — private
- **Generated by**: `scripts/03_clean_filter_publications.R`
- **Git-ignored**: Yes — may contain LDP student names in exclusion records

Human-readable record of every exclusion decision made during `03_clean_filter_publications.R`: duplicate titles removed, paratext flags triggered, non-primary Crossref types excluded, title keyword matches, and final row counts per group. Useful for auditing and reporting exclusion numbers in the manuscript.

---

## `processed_data/comparator_checkpoint.rds`

- **Path**: `processed_data/comparator_checkpoint.rds`
- **Type**: Checkpoint — intermediate output
- **Generated by**: `scripts/02_get_comparator_authors.R`
- **Format**: R binary (RDS)
- **Git-ignored**: Yes

Progress checkpoint written incrementally by `02_get_comparator_authors.R`. Allows the comparator author search to be resumed without restarting from scratch if the script is interrupted. Delete this file to force a full re-run.

Load with: `readRDS(here::here("data", "processed_data", "comparator_checkpoint.rds"))`

---

## `processed_data/rater_publications.csv`

- **Path**: `processed_data/rater_publications.csv`
- **Type**: Output
- **Generated by**: `scripts/04_create_rater_files.R`
- **Git-ignored**: Yes (data not version-controlled)

Blinded publication list for FAIR compliance raters. Each row is one publication (LDP or comparator) identified only by a random alphanumeric code. Group membership, author name, and institution are deliberately omitted. The rows are shuffled so that group identity cannot be inferred from position. This file is shared with raters; `private/rater_key.csv` must not be shared until scoring is complete.

**Record count**: 2 × number of matched LDP–comparator pairs.

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `pub_id` | character | — | Unique 6-character alphanumeric blinded code (e.g., `K4MX2P`); links to `rater_key.csv` | No |
| `title` | character | — | Article title | Yes |
| `doi` | character | — | DOI URL (e.g., `https://doi.org/10.1234/...`); `NA` if not available | Yes |
| `publication_year` | integer | year | Four-digit publication year | No |
| `openalex_url` | character | — | OpenAlex work page URL (e.g., `https://openalex.org/W4312270662`); alternative access route when DOI is absent | No |

---

## `processed_data/private/rater_key.csv`

- **Path**: `processed_data/private/rater_key.csv`
- **Type**: Output — private
- **Generated by**: `scripts/04_create_rater_files.R`
- **Git-ignored**: Yes — contains LDP student names and reveals group assignments

Full linking table connecting each blinded `pub_id` in `rater_publications.csv` back to its pair, group, author, and institution. Must not be shared with raters until all FAIR compliance scoring is complete.

#### Column schema

| Column | Type | Units | Description | Nullable |
|---|---|---|---|---|
| `pub_id` | character | — | Blinded publication code; primary key linking to `rater_publications.csv` | No |
| `pair_id` | character | — | Pair identifier (e.g., `PAIR001`); links one LDP publication to its matched comparator publication | No |
| `group` | character | — | `LDP` or `Comparator` | No |
| `searched_name` | character | — | Author name submitted to OpenAlex (`Firstname Lastname`) | No |
| `institution_name` | character | — | Full institution name | No |
| `publication_year` | integer | year | Four-digit publication year | No |
| `title` | character | — | Article title | Yes |
| `doi` | character | — | DOI URL; `NA` if not available | Yes |
| `openalex_id` | character | — | OpenAlex work entity URL | No |
| `openalex_url` | character | — | OpenAlex work page URL | No |

---

## File Summary

| File | Private | Git-ignored | Generated by |
|---|---|---|---|
| `raw_data/LDP-MODULES_ALL_2020-2022.csv` | Yes | Yes | Manual (LDP admin records) |
| `raw_data/Training_event_data.csv` | Yes | Yes | Manual (LDP admin records) |
| `raw_data/institution_names.csv` | No | No | Manual lookup table |
| `raw_data/ldp_n_target.csv` | No | No | `scripts/01_get_ldp_targets.R` |
| `raw_data/ldp_eee_field_ids.rds` | No | No | `scripts/01_get_ldp_targets.R` |
| `processed_data/private/ldp_student_names_2020-2022.csv` | Yes | Yes | `scripts/private/extract_ldp_student_names.R` |
| `processed_data/private/LDP_author_publications.csv` | Yes | Yes | `scripts/private/get_ldp_publications.R` |
| `processed_data/private/ldp_exclusion_names.csv` | Yes | Yes | `scripts/01_get_ldp_targets.R` |
| `processed_data/private/LDP_publications_filtered.csv` | Yes | Yes | `scripts/03_clean_filter_publications.R` |
| `processed_data/private/filter_log.txt` | Yes | Yes | `scripts/03_clean_filter_publications.R` |
| `processed_data/classified/*.csv` | No | Yes | `LDP_thesis_classification` project |
| `processed_data/comparator_author_publications.csv` | No | Yes | `scripts/02_get_comparator_authors.R` |
| `processed_data/comparator_checkpoint.rds` | No | Yes | `scripts/02_get_comparator_authors.R` |
| `processed_data/comparator_publications_filtered.csv` | No | Yes | `scripts/03_clean_filter_publications.R` |
| `processed_data/rater_publications.csv` | No | Yes | `scripts/04_create_rater_files.R` |
| `processed_data/private/rater_key.csv` | Yes | Yes | `scripts/04_create_rater_files.R` |
