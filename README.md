# LDP Comparator Author Retrieval [PLACEHOLDER]

**Status**: Temporary staging folder. This material was carved out of `LDP_thesis_classification/` on 2026-03-22 and will be reorganized into a proper project repository.

---

## Purpose

This project takes classified thesis CSVs (output of the `LDP_thesis_classification` pipeline) and retrieves first-author publications for matched non-LDP comparator authors from OpenAlex. It also retrieves LDP participant publications for comparison.

---

## Pipeline

```
[private/extract_ldp_student_names.R]  →  ldp_student_names_2020-2022.csv
[private/get_ldp_publications.R]       →  LDP_author_publications.csv
01_get_ldp_targets.R                   →  ldp_exclusion_names.csv
                                           ldp_n_target.csv
                                           ldp_eee_field_ids.rds
02_get_comparator_authors.R            →  comparator_author_publications.csv
```

**Data handoff**: Populate `data/processed_data/classified/` with classified thesis CSVs from the `LDP_thesis_classification` project (`03_apply_classifier.R` output) before running `02_get_comparator_authors.R`.

---

## Directory Structure

```
new_project/
├── scripts/
│   ├── 01_get_ldp_targets.R        # Derives LDP exclusion list, N_target, EEE field IDs
│   ├── 02_get_comparator_authors.R # Retrieves comparator author publications via OpenAlex
│   └── private/                    # Private scripts (handle confidential LDP roster data)
│       ├── extract_ldp_student_names.R
│       └── get_ldp_publications.R
└── data/
    ├── raw_data/                   # Private LDP source data + derived lookup files
    └── processed_data/
        ├── classified/             # Input: classified thesis CSVs (from LDP_thesis_classification)
        ├── comparator_author_publications.csv
        └── comparator_checkpoint.rds
```

---

## TODO (before this becomes a real project)

- [ ] Initialize as a proper git repository
- [ ] Set up `.gitignore` to exclude `data/` (all data is private)
- [ ] Write full README with methodology, contributors, pipeline diagram
- [ ] Write data dictionary for `data/raw_data/` and `data/processed_data/`
- [ ] Set up `renv` for package management (copy `renv.lock` from `LDP_thesis_classification`)
- [ ] Rename project folder to something descriptive (e.g., `LDP_comparator_publications`)
