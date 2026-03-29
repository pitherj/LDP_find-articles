# extract_ldp_student_names.R
#
# Purpose: Filters the private LDP course roster to produce a table of unique
#          student names enrolled in the "Productivity and Reproducibility in EEB"
#          or "Scientific Data Management in EEB" modules during 2020–2022.
#          Each student's LDP enrollment year is retained so that downstream
#          publication retrieval can apply a per-student minimum publication date
#          (year of enrollment + 1).
#          Exports the result for use in downstream publication retrieval.
#
# Note:    This script processes private data and is stored in data/raw_data/scripts/
#          rather than the main scripts/ folder. Access restricted to
#          Jason Pither and Diane Srivastava.
#
# Inputs:  data/raw_data/LDP-MODULES_ALL_2020-2022.csv
#          data/raw_data/Training_event_data.csv
# Outputs: data/raw_data/ldp_student_names_2020-2022.csv
#
# Author:  Jason Pither
# Updated: 2026-03-29

library(tidyverse)
library(here)

lookup_table <- readr::read_csv(here::here("data", "raw_data", "Training_event_data.csv"))

roster <- readr::read_csv(here::here("data", "raw_data", "LDP-MODULES_ALL_2020-2022.csv"))

# rename program field
roster <- dplyr::rename(roster, program = "MSc/PhD")

focal_codes <- lookup_table %>%
  filter(year %in% c(2020, 2021, 2022)) %>%
  filter(grepl("Productivity|data", Train_title)) %>%
  select(Train_ID, year)

# now get rosters corresponding to records with focal codes, retaining the
# enrollment year for each student. Where a student appears in multiple course
# offerings (e.g. two qualifying modules or across multiple years), keep the
# earliest year (ldp_year) as the relevant cutoff anchor.

ldp_student_names <- roster %>%
  filter(Train_ID %in% focal_codes$Train_ID) %>%
  dplyr::left_join(focal_codes %>% select(Train_ID, year), by = "Train_ID") %>%
  dplyr::group_by(Train_Last_Name, Train_First_Name, Institution_ID, program) %>%
  dplyr::summarise(ldp_year = min(year), .groups = "drop")

# write file

# NOTE: the data will be written to the protected and hidden "raw_data" directory
# so as to keep it accessible to only those with permissions

readr::write_csv(ldp_student_names, here::here("data", "raw_data", "ldp_student_names_2020-2022.csv"))
