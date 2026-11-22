# INCUBYTE SKYPOINTS — DATA ENGINEER ASSESSMENT ETL PIPELINE

**Deliverable:** End-to-end member profile and redemption load process
**Platform:** SQL Server 2022
**Database:** `SkyPoints_DataEngineering`
**Schemas:** `raw`, `stg`, `curated`, `audit`
**Ingestion:** Python 3 (pandas + pyodbc) for raw load, T-SQL for all downstream transforms
**Updated:** November 2026 — revised for CSV source files

---

## 1. Project Overview

This pipeline loads member profile records from three country source files into a SQL Server warehouse, then loads partner airline redemption feeds against those members.

| Stage | Movement | Tool |
|-------|----------|------|
| 1. Raw load | Source files → `raw.Member_Profile_Raw` (one JSON row per source row) | Python notebook |
| 2. Staging load | `raw` JSON → parsed, date-converted, validated → `stg.Member_Profile_Stg` | T-SQL Step 3 |
| 3. Target load | `stg` → country MERGE ("latest record wins") → `curated.Table_IND/USA/AUS` | T-SQL Step 4 |
| 4. Redemption load | JSON redemption feed → `raw.Redemption_Raw` + `stg.Redemption_Stg` | Python notebook |
| 5. Audit | Rejected rows → `audit.Data_Validation_Errors` | T-SQL Step 3 |

**Design principle:** every source row is preserved in `raw` before any validation. Nothing is dropped at ingestion, so a rejected row is always traceable back to its original file, row number, and batch.

---

## 2. What Changed in This Revision

The source files for India and USA changed from Excel workbooks to CSV. The pipeline was updated accordingly.

### 2.1 Source format change

| Source | Before | After |
|--------|--------|-------|
| India | `IND.xlsx` | `IND.csv` |
| USA | `USA.xlsx` | `USA.csv` |
| Australia | `AUS.xlsx` | `AUS.xlsx` (unchanged) |

The notebook now selects its reader per file by extension, so a mixed CSV/Excel set loads in the same run. If Australia is later converted to CSV, changing `AUS.xlsx` to `AUS.csv` in the `FILES` dictionary is the only edit required.

### 2.2 CSV-specific hardening in the Python notebook

| Risk | Symptom if unhandled | Fix applied |
|------|----------------------|-------------|
| UTF-8 BOM written by Excel's "CSV UTF-8" save | First column name becomes `﻿ID`, so SQL path `$.ID` returns NULL and **every** Indian row is rejected | `pd.read_csv(..., encoding="utf-8-sig")` — strips the BOM if present, no-op if absent |
| Trailing spaces in CSV headers (`ID `, `Name `) | JSON keys do not match the SQL `JSON_VALUE` paths | Column names are stripped on read |
| Trailing spaces in values | IDs and names silently fail exact-match joins | Every string cell is stripped |
| Blank trailing lines at end of file | Empty records inserted into `raw` | Rows that are entirely null are dropped |
| Numeric ID parsed as float | `6152022.0` instead of `6152022`, breaking joins and IDs | Floats are re-stringified as integers where exact |

### 2.3 SQL fixes carried in this revision

| # | File | Issue in the original | Fix |
|---|------|----------------------|-----|
| 1 | Step 3 | `stg.Member_Profile_Stg.Member_ID` was `NOT NULL` — a blank ID aborted the whole transaction instead of rejecting one row | Column is nullable; the row is flagged `REJECTED` and audited |
| 2 | Step 3 | `Member_Name VARCHAR(100)` — longer names raised a truncation error | Widened to `VARCHAR(255)` |
| 3 | Step 4 | `MERGE` was fed every staging row, so two rows for one `Member_ID` raised *"attempted to UPDATE or DELETE the same row more than once"* | `ROW_NUMBER() ... = 1` reduces the source to exactly one row per member before `MERGE` |
| 4 | Step 4 | `MERGE` ran without a lock hint, allowing race conditions under concurrency | `WITH (HOLDLOCK)` |
| 5 | Step 3 | Audit rows were written without `Batch_ID`, and the join back to `raw` ignored batch — a previous batch could supply the `Invalid_Value` | `Batch_ID` is written and included in the join |
| 6 | Step 1 | `curated` columns were narrow (`Tier_Code VARCHAR(5)`, `State VARCHAR(5)`) — real data would truncate | Widened; DDL is idempotent and widens columns on existing databases |
| 7 | Step 3 | CTE was closed with a stray `}` — syntax error | Correct `)` |
| 8 | Step 3 | USA dates `MMDDYYYY` were reassembled in the wrong order, producing invalid dates → NULL → all USA rows filtered out | Correct 7- and 8-digit handling |
| 9 | Step 1 | No indexes on the hot join/filter paths | `IX_Member_Profile_Raw_Src`, `IX_Member_Profile_Stg_Country`, `IX_Redemption_Stg_Member_Txn` |

---

## 3. Folder Structure

Deliverables:

```
outputs/
├── README.md                         # this document
├── 1_DDL_Create_Tables.sql           # database, schemas, tables, indexes
├── 2_Python_Excel_To_SQL_ETL.ipynb   # raw load from IND.csv / USA.csv / AUS.xlsx
├── 3_staging_load.sql                # raw → staging, validation, audit
├── 4_target_tables_merge.sql         # staging → curated country tables
└── 6_Parse_Redemption_Feed.ipynb     # redemption feed → raw/stg redemption tables
```

Input files must sit alongside the notebook (see `SOURCE_PATH` in cell 2):

```
<source folder>/
├── IND.csv
├── USA.csv
└── AUS.xlsx
```

---

## 4. Source Data Reference

| Country | File | Date Format | SQL Style | Example |
|---------|------|-------------|-----------|---------|
| IND | `IND.csv` | `M/D/YYYY` | 101 | `1/1/2022` |
| USA | `USA.csv` | `MMDDYYYY` (7 or 8 digits) | 112 | `6152022` → `2022-06-15` |
| AUS | `AUS.xlsx` | `YYYY-MM-DD` | 23 | `2022-05-11` |

### 4.1 Column names the SQL expects

The notebook JSON-encodes each source row using the **file's own column headers**, and Step 3 reads those values with fixed `JSON_VALUE` paths. Header names must therefore match exactly (case and spacing included).

**IND / USA**

| SQL path | Field | Used by |
|----------|-------|---------|
| `$.ID` | Member ID | IND, USA |
| `$.Name` | Member name | IND, USA |
| `$.TierCode` | Tier | IND, USA |
| `$.EnrollmentDate` | Enrollment date | IND, USA |
| `$.FlightDate` | Last flight date | USA |
| `$.Flight Date` | Last flight date | IND (note the space) |
| `$.DOB` | Date of birth | IND only — USA has no DOB |
| `$.Individual or Corporate` | Member type | IND only |

**AUS**

`Unique ID`, `Member Name`, `Tier Type`, `Date of Birth`, `Date of Enrollment`, `Date of Flight`

> If a header differs, the corresponding field silently resolves to NULL, which surfaces as a rejected row with `Enrollment_Date` or `Member_ID` errors. Check section 9 before assuming the data is bad.

### 4.2 Mandatory fields for a VALID row

`Member_ID`, `Member_Name`, `Enrollment_Date`. Anything else may be null without rejecting the row.

---

## 5. Execution Order

Run strictly in this order. Each step must complete before the next.

| Step | File | Purpose |
|------|------|---------|
| 1 | `1_DDL_Create_Tables.sql` | Create database, schemas, all tables and indexes |
| 2 | `2_Python_Excel_To_SQL_ETL.ipynb` | Load `IND.csv`, `USA.csv`, `AUS.xlsx` → `raw.Member_Profile_Raw` |
| 3 | `3_staging_load.sql` | Parse raw JSON, convert dates, validate, load staging + audit |
| 4 | `4_target_tables_merge.sql` | MERGE validated rows → `curated.Table_India/USA/AUS` |
| 5 | `6_Parse_Redemption_Feed.ipynb` | Load redemption feed → `raw.Redemption_Raw` + `stg.Redemption_Stg`, then join |

Step 5 depends on Step 3 having run: its join reads `stg.Member_Profile_Stg`.

---

## 6. Step Details

### Step 1 — Database and Tables

**File:** `1_DDL_Create_Tables.sql` — run in SSMS or Azure Data Studio against `DESKTOP-ANIL`.

The script is idempotent. Re-running it on an existing database creates nothing and instead widens any column that an earlier revision created too narrow. Safe to run before every deployment.

Objects created:

- `raw.Member_Profile_Raw`, `raw.Redemption_Raw`
- `stg.Member_Profile_Stg`, `stg.Redemption_Stg`
- `curated.Table_India`, `curated.Table_USA`, `curated.Table_AUS`
- `audit.Data_Validation_Errors`, `audit.ETL_Batch_Log`, `audit.Data_Quality_Summary`

The final `SELECT` in the script lists every table with its row count, confirming the build.

### Step 2 — Raw Load

**File:** `2_Python_Excel_To_SQL_ETL.ipynb`
**Requires:** `pandas`, `pyodbc`, ODBC Driver 18 for SQL Server
**Connection:** Windows trusted authentication

Before running, confirm in cell 2:

```python
SOURCE_PATH = r"<folder containing IND.csv, USA.csv, AUS.xlsx>"
FILES = {"IND": "IND.csv", "USA": "USA.csv", "AUS": "AUS.xlsx"}
SQL_SERVER  = r"DESKTOP-ANIL"
SQL_DATABASE = "SkyPoints_DataEngineering"
```

Logic, in order: validate all three files exist → connect → check whether `raw.Member_Profile_Raw` already holds rows → clear it if `FORCE_RELOAD` is True, otherwise abort before writing anything → read each file with the reader matching its extension → insert one JSON document per source row.

`Source_Row_Number` is written as `index + 2`, i.e. the spreadsheet row number with the header as row 1, so an audit record points at the row a human would see in the file.

**Duplicate protection:** the pipeline refuses to load into a non-empty raw table. Set `FORCE_RELOAD = True` for a full refresh. Both notebooks import `sys` but do not read `--force` from the command line — this is a notebook constant, not a CLI flag.

**Running it:** open in VS Code or Jupyter and run the cells in order. Do not `python notebook.ipynb` — that fails with `NameError: name 'null' is not defined`, because the file is JSON, not Python.

### Step 3 — Staging Load, Validation, Audit

**File:** `3_staging_load.sql`

Recreates `stg.Member_Profile_Stg` from scratch each run and clears prior audit rows, so re-running it never duplicates. Wrapped in `TRY/CATCH` with an explicit rollback.

For each raw row it: extracts fields by country-specific JSON path → converts each date to `DATE` per that country's format → validates the three mandatory fields → sets `Validation_Status` to `VALID` or `REJECTED` with a human-readable reason → computes `Age` from DOB and `Stale_Member` (last flight more than 90 days ago).

Valid and rejected rows are both written to staging; rejected rows are additionally copied to `audit.Data_Validation_Errors`.

The script ends with three verification queries: counts by country, the rejected rows, and the audit entries.

### Step 4 — Target Load

**File:** `4_target_tables_merge.sql`

Three `MERGE` statements, one per country, inside a single transaction with `TRY/CATCH`.

Per country the source is filtered to `Validation_Status = 'VALID'` with non-blank `Member_ID` and `Member_Name` and a non-null `Enrollment_Date`, then reduced to exactly one row per member:

```sql
ROW_NUMBER() OVER (PARTITION BY s.Member_ID
                   ORDER BY s.Source_Updated_At DESC, s.Stg_ID DESC) AS rn
...
USING (SELECT * FROM src WHERE rn = 1) AS s
```

This is the "latest record wins" rule, with `Stg_ID` as a deterministic tiebreak so the same input always produces the same output. The `rn = 1` filter is mandatory: `MERGE` raises an error if a source has two rows matching one target row.

Rows are updated when the member already exists and inserted when new, so the step is safe to re-run.

### Step 5 — Redemption Feed

**File:** `6_Parse_Redemption_Feed.ipynb`

Parses a partner airline JSON redemption feed. For each redemption it writes the unmodified record to `raw.Redemption_Raw` and a flattened version to `stg.Redemption_Stg` (member, transaction, partner, miles, status). It then runs a join from `stg.Redemption_Stg` to `stg.Member_Profile_Stg` on `Member_ID` to show redemptions against member profiles.

The notebook ships with a hard-coded sample feed whose member is `MEM-001`. The sample join returns zero rows until member IDs in the feed match IDs in the profile data — this is expected for the sample, not a fault.

---

## 7. Verification

### 7.1 Curated counts

```sql
SELECT 'IND' AS Country, COUNT(*) AS Total_Records FROM curated.Table_India
UNION ALL SELECT 'USA', COUNT(*) FROM curated.Table_USA
UNION ALL SELECT 'AUS', COUNT(*) FROM curated.Table_AUS;
```

### 7.2 Staging validation summary

```sql
SELECT Source_Country,
       COUNT(*)                                                       AS Total,
       SUM(CASE WHEN Validation_Status = 'VALID'    THEN 1 ELSE 0 END) AS Valid,
       SUM(CASE WHEN Validation_Status = 'REJECTED' THEN 1 ELSE 0 END) AS Rejected
FROM stg.Member_Profile_Stg
GROUP BY Source_Country ORDER BY Source_Country;
```

### 7.3 Audit entries

```sql
SELECT Source_File, Source_Row_Number, Member_ID, Column_Name,
       Invalid_Value, Error_Description, Batch_ID
FROM audit.Data_Validation_Errors
ORDER BY Source_File, Source_Row_Number;
```

### 7.4 End-to-end trace of any single record

```sql
SELECT r.Source_Country, r.Source_File, r.Source_Row_Number,
       r.Raw_Record, r.Batch_ID
FROM raw.Member_Profile_Raw r
WHERE r.Source_File = 'IND.csv' AND r.Source_Row_Number = 2;
```

Change the file and row number to inspect any row from source through to target.

### 7.5 Expected results with the assessment sample data

| Country | Staging rows | Valid | Rejected | Curated |
|---------|--------------|-------|----------|---------|
| IND | 3 | 3 | 0 | 3 |
| USA | 3 | 3 | 0 | 3 |
| AUS | 3 | 2 | 1 | 2 |

The single rejection is the Australian row for Jonnathan, whose `Date of Enrollment` is `2021-13-13`. Month 13 does not exist, so the date cannot be parsed and the row is correctly rejected with the raw value preserved in the audit message.

Counts will differ if your source files contain different data — these figures describe the assessment sample only.

---

## 8. Operational Notes

**Refresh model.** Step 2 is a full refresh, not incremental. It clears `raw.Member_Profile_Raw` and reloads everything. Steps 3 and 4 derive from `raw`, so all three run together as a unit.

**Idempotency.** Safe to re-run: Step 1 creates nothing if it exists, Step 2 clears raw before loading, Step 3 drops and recreates staging and clears audit rows, Step 4 upserts by `Member_ID`.

**Batch traceability.** Each Step 2 run generates a new UUID `Batch_ID`, stamped on every `raw` row for that run and carried into staging and audit.

**Why staging is wider than curated.** Staging keeps rejected rows alongside valid ones, so `Member_ID` and `Member_Name` must tolerate bad values and be nullable. Curated holds only validated records, so both are `NOT NULL` there.

**Date conversion is country-driven, not file-driven.** Format selection keys on `Source_Country`, so it is unaffected by the file moving from Excel to CSV.

---

## 9. Troubleshooting

| Symptom | Likely cause | Resolution |
|---------|--------------|------------|
| `Source file not found` from Step 2 | `SOURCE_PATH` wrong, or file still named `.xlsx` | Fix the path or update `FILES` |
| All rows of one country rejected, `Member_ID` missing | CSV header differs from expected, or a UTF-8 BOM broke the first column | Compare headers against section 4.1; BOM is already handled by `utf-8-sig` |
| All rows of one country rejected, `Enrollment_Date` invalid | Date format differs from section 4 | Check the raw value in the audit message, then adjust Step 3 parsing |
| `RAW table already contains N records` | Duplicate protection fired | Set `FORCE_RELOAD = True` for a full refresh |
| `MERGE statement attempted to UPDATE or DELETE the same row more than once` | Step 4 without the `rn = 1` dedupe | Use the supplied `4_target_tables_merge.sql` |
| `String or binary data would be truncated` | A column narrower than the data | Re-run Step 1 — it widens columns on existing tables |
| `Incorrect syntax near '}'` | Old Step 3 file used `}` to close a CTE | Use the supplied `3_staging_load.sql` |
| `NameError: name 'null' is not defined` | Notebook run with `python file.ipynb` | Open in Jupyter or VS Code, or `jupyter nbconvert --to script` first |
| Step 5 join returns 0 rows | Feed member IDs do not exist in the profile data | Expected with the sample feed; use IDs present in `stg.Member_Profile_Stg` |
| `Login failed` / driver not found | Trusted connection or ODBC 18 not available | Confirm Windows auth to `DESKTOP-ANIL`; install ODBC Driver 18 for SQL Server |

---

## 10. Testing Checklist

- [ ] Step 1 completes; all 10 tables present with the expected columns
- [ ] Step 2 loads one raw row per source row, with `Source_Row_Number` matching the file
- [ ] Step 3 populates `Validation_Status` for every row; no row is silently dropped
- [ ] Step 4 merges all three countries; curated counts match the valid staging counts
- [ ] Rejected rows appear in `audit.Data_Validation_Errors` with a readable `Error_Description`
- [ ] Re-running Step 2 with `FORCE_RELOAD = True` reproduces identical raw counts, with no duplication
- [ ] Re-running Steps 3 and 4 produces no primary-key violations and unchanged curated counts
- [ ] Spot-check one member from raw JSON → staging → curated
- [ ] Step 5 loads the feed and the join runs without error

---

## 11. Assumptions

1. Source CSV and Excel files retain the column headers listed in section 4.1. Header changes require updating the `JSON_VALUE` paths in Step 3.
2. Date values follow the stated per-country formats. Values with mixed formats inside one file are rejected rather than guessed at.
3. One row per member is the desired grain in curated tables; additional rows are collapsed to the newest by `Source_Updated_At`.
4. Windows integrated authentication to the local SQL Server instance is available, per the supplied connection string.
5. `DESKTOP-ANIL` and the database name remain the deployment target; both are single-point constants in each file.

---

*End of README*
