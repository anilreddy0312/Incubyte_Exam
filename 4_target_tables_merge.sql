/*=============================================================
  STEP 4: Load Country-Specific Target Tables from Staging

  Logic:
    - Loads INTO curated.Table_India / Table_USA / Table_AUS
    - MERGE with "latest record wins": exactly ONE row per
      Member_ID is fed to MERGE (ROW_NUMBER ... = 1)
    - Filter: Validation_Status = 'VALID', Member_ID not null,
      Member_Name not blank, Enrollment_Date not null
    - Validation/audit logging happens in Step 3

  NOTE: MERGE requires at most one source row per target row.
  Feeding it several rows for the same Member_ID causes
  "The MERGE statement attempted to UPDATE or DELETE the same row
  more than once." Deduping with rn = 1 prevents that.
=============================================================*/

USE SkyPoints_DataEngineering;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    /* =========================================================================
       1. INDIA
       ========================================================================= */
    ;WITH src AS
    (
        SELECT
            s.Member_ID, s.Member_Name, s.Enrollment_Date,
            s.Last_Flight_Date, s.Tier_Code, s.Agent_Name,
            s.State, s.Source_Country, s.Post_Code, s.DOB,
            s.Is_Active, s.Member_Type, s.Age,
            s.Stale_Member, s.Source_Updated_At,
            ROW_NUMBER() OVER (
                PARTITION BY s.Member_ID
                ORDER BY s.Source_Updated_At DESC, s.Stg_ID DESC
            ) AS rn
        FROM stg.Member_Profile_Stg s
        WHERE s.Source_Country = 'IND'
          AND s.Validation_Status = 'VALID'
          AND NULLIF(LTRIM(RTRIM(s.Member_ID)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(s.Member_Name)), '') IS NOT NULL
          AND s.Enrollment_Date IS NOT NULL
    )
    MERGE INTO curated.Table_India WITH (HOLDLOCK) AS t
    USING (SELECT * FROM src WHERE rn = 1) AS s
        ON t.Member_ID = s.Member_ID
    WHEN NOT MATCHED BY TARGET THEN
        INSERT
        (
            Member_ID, Member_Name, Enrollment_Date,
            Last_Flight_Date, Tier_Code, Agent_Name,
            State, Country, Post_Code, DOB, Is_Active,
            Member_Type, Age, Stale_Member, Source_Updated_At,
            Last_Loaded_At
        )
        VALUES
        (
            s.Member_ID, s.Member_Name, s.Enrollment_Date,
            s.Last_Flight_Date, s.Tier_Code, s.Agent_Name,
            s.State, s.Source_Country, s.Post_Code, s.DOB,
            s.Is_Active, s.Member_Type, s.Age,
            s.Stale_Member, s.Source_Updated_At,
            GETDATE()
        )
    WHEN MATCHED THEN
        UPDATE SET
            t.Member_Name       = s.Member_Name,
            t.Enrollment_Date   = s.Enrollment_Date,
            t.Last_Flight_Date  = s.Last_Flight_Date,
            t.Tier_Code         = s.Tier_Code,
            t.Agent_Name        = s.Agent_Name,
            t.State             = s.State,
            t.Post_Code         = s.Post_Code,
            t.DOB               = s.DOB,
            t.Is_Active         = s.Is_Active,
            t.Member_Type       = s.Member_Type,
            t.Age               = s.Age,
            t.Stale_Member      = s.Stale_Member,
            t.Source_Updated_At = s.Source_Updated_At,
            t.Last_Loaded_At    = GETDATE();

    /* =========================================================================
       2. USA
       ========================================================================= */
    ;WITH src AS
    (
        SELECT
            s.Member_ID, s.Member_Name, s.Enrollment_Date,
            s.Last_Flight_Date, s.Tier_Code, s.Agent_Name,
            s.State, s.Source_Country, s.Post_Code, s.DOB,
            s.Is_Active, s.Member_Type, s.Age,
            s.Stale_Member, s.Source_Updated_At,
            ROW_NUMBER() OVER (
                PARTITION BY s.Member_ID
                ORDER BY s.Source_Updated_At DESC, s.Stg_ID DESC
            ) AS rn
        FROM stg.Member_Profile_Stg s
        WHERE s.Source_Country = 'USA'
          AND s.Validation_Status = 'VALID'
          AND NULLIF(LTRIM(RTRIM(s.Member_ID)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(s.Member_Name)), '') IS NOT NULL
          AND s.Enrollment_Date IS NOT NULL
    )
    MERGE INTO curated.Table_USA WITH (HOLDLOCK) AS t
    USING (SELECT * FROM src WHERE rn = 1) AS s
        ON t.Member_ID = s.Member_ID
    WHEN NOT MATCHED BY TARGET THEN
        INSERT
        (
            Member_ID, Member_Name, Enrollment_Date,
            Last_Flight_Date, Tier_Code, Agent_Name,
            State, Country, Post_Code, DOB, Is_Active,
            Member_Type, Age, Stale_Member, Source_Updated_At,
            Last_Loaded_At
        )
        VALUES
        (
            s.Member_ID, s.Member_Name, s.Enrollment_Date,
            s.Last_Flight_Date, s.Tier_Code, s.Agent_Name,
            s.State, s.Source_Country, s.Post_Code, s.DOB,
            s.Is_Active, s.Member_Type, s.Age,
            s.Stale_Member, s.Source_Updated_At,
            GETDATE()
        )
    WHEN MATCHED THEN
        UPDATE SET
            t.Member_Name       = s.Member_Name,
            t.Enrollment_Date   = s.Enrollment_Date,
            t.Last_Flight_Date  = s.Last_Flight_Date,
            t.Tier_Code         = s.Tier_Code,
            t.Agent_Name        = s.Agent_Name,
            t.State             = s.State,
            t.Post_Code         = s.Post_Code,
            t.DOB               = s.DOB,
            t.Is_Active         = s.Is_Active,
            t.Member_Type       = s.Member_Type,
            t.Age               = s.Age,
            t.Stale_Member      = s.Stale_Member,
            t.Source_Updated_At = s.Source_Updated_At,
            t.Last_Loaded_At    = GETDATE();

    /* =========================================================================
       3. AUSTRALIA
       ========================================================================= */
    ;WITH src AS
    (
        SELECT
            s.Member_ID, s.Member_Name, s.Enrollment_Date,
            s.Last_Flight_Date, s.Tier_Code, s.Agent_Name,
            s.State, s.Source_Country, s.Post_Code, s.DOB,
            s.Is_Active, s.Member_Type, s.Age,
            s.Stale_Member, s.Source_Updated_At,
            ROW_NUMBER() OVER (
                PARTITION BY s.Member_ID
                ORDER BY s.Source_Updated_At DESC, s.Stg_ID DESC
            ) AS rn
        FROM stg.Member_Profile_Stg s
        WHERE s.Source_Country = 'AUS'
          AND s.Validation_Status = 'VALID'
          AND NULLIF(LTRIM(RTRIM(s.Member_ID)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(s.Member_Name)), '') IS NOT NULL
          AND s.Enrollment_Date IS NOT NULL
    )
    MERGE INTO curated.Table_AUS WITH (HOLDLOCK) AS t
    USING (SELECT * FROM src WHERE rn = 1) AS s
        ON t.Member_ID = s.Member_ID
    WHEN NOT MATCHED BY TARGET THEN
        INSERT
        (
            Member_ID, Member_Name, Enrollment_Date,
            Last_Flight_Date, Tier_Code, Agent_Name,
            State, Country, Post_Code, DOB, Is_Active,
            Member_Type, Age, Stale_Member, Source_Updated_At,
            Last_Loaded_At
        )
        VALUES
        (
            s.Member_ID, s.Member_Name, s.Enrollment_Date,
            s.Last_Flight_Date, s.Tier_Code, s.Agent_Name,
            s.State, s.Source_Country, s.Post_Code, s.DOB,
            s.Is_Active, s.Member_Type, s.Age,
            s.Stale_Member, s.Source_Updated_At,
            GETDATE()
        )
    WHEN MATCHED THEN
        UPDATE SET
            t.Member_Name       = s.Member_Name,
            t.Enrollment_Date   = s.Enrollment_Date,
            t.Last_Flight_Date  = s.Last_Flight_Date,
            t.Tier_Code         = s.Tier_Code,
            t.Agent_Name        = s.Agent_Name,
            t.State             = s.State,
            t.Post_Code         = s.Post_Code,
            t.DOB               = s.DOB,
            t.Is_Active         = s.Is_Active,
            t.Member_Type       = s.Member_Type,
            t.Age               = s.Age,
            t.Stale_Member      = s.Stale_Member,
            t.Source_Updated_At = s.Source_Updated_At,
            t.Last_Loaded_At    = GETDATE();

    COMMIT TRANSACTION;
    PRINT 'Country-wise loading completed successfully.';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT 'Loading failed. Transaction rolled back.';
    THROW;

END CATCH;
GO

/* =========================================================================
   VERIFICATION 1: target record counts
   ========================================================================= */
SELECT 'IND' AS Country, COUNT(*) AS Total_Records
FROM curated.Table_India
UNION ALL
SELECT 'USA', COUNT(*) FROM curated.Table_USA
UNION ALL
SELECT 'AUS', COUNT(*) FROM curated.Table_AUS;
GO

/* =========================================================================
   VERIFICATION 2: duplicate Member_IDs in staging (should be 0 rows
   after dedupe -- if this returns rows, they were collapsed to rn=1)
   ========================================================================= */
SELECT
    Source_Country, Member_ID, COUNT(*) AS Stg_Rows
FROM stg.Member_Profile_Stg
WHERE Validation_Status = 'VALID'
GROUP BY Source_Country, Member_ID
HAVING COUNT(*) > 1;
GO

/* =========================================================================
   VERIFICATION 3: rejected records in audit
   ========================================================================= */
SELECT
    Source_File, Source_Row_Number, Member_ID,
    Column_Name, Invalid_Value, Error_Description, Batch_ID
FROM audit.Data_Validation_Errors
ORDER BY Source_File, Source_Row_Number;
GO