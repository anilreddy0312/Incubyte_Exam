/*=============================================================
  STEP 3: Load Staging Table from Raw Records

  Source date formats (unchanged):
    IND  -> M/D/YYYY      (style 101)      e.g. 1/1/2022
    USA  -> MMDDYYYY      (style 112)      e.g. 6152022 -> 2022-06-15
    AUS  -> YYYY-MM-DD    (style 23)       e.g. 2022-05-11

  Mandatory for VALID: Member_ID, Member_Name, Enrollment_Date.
  Rows failing validation stay in staging with Validation_Status =
  'REJECTED' and are logged to audit.Data_Validation_Errors.
=============================================================*/

USE SkyPoints_DataEngineering;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

GO

/* -----------------------------------------------------------
   Recreate staging table idempotently; clear stale audit rows.
   ----------------------------------------------------------- */
IF OBJECT_ID('stg.Member_Profile_Stg', 'U') IS NOT NULL
BEGIN
    DROP TABLE stg.Member_Profile_Stg;
    PRINT 'Dropped existing stg.Member_Profile_Stg table';
END;
GO

CREATE TABLE stg.Member_Profile_Stg
(
    Stg_ID              BIGINT IDENTITY(1,1) PRIMARY KEY,

    Member_ID           VARCHAR(50)  NULL,
    Member_Name         VARCHAR(255) NULL,

    Enrollment_Date     DATE,
    Last_Flight_Date    DATE,

    Tier_Code           VARCHAR(20),
    Agent_Name          VARCHAR(255),

    State               VARCHAR(50),
    Country             VARCHAR(20),
    Post_Code           VARCHAR(20),

    DOB                 DATE,
    Is_Active           CHAR(1),

    Member_Type         VARCHAR(30),

    Age                 INT,
    Stale_Member        BIT,

    Source_Country      VARCHAR(5),
    Source_File         VARCHAR(255),
    Source_Row_Number   INT,

    Source_Updated_At   DATETIME2(0),
    File_Date           DATE,
    Batch_ID            VARCHAR(100),

    Validation_Status   VARCHAR(20) DEFAULT 'PENDING',
    Validation_Errors   NVARCHAR(MAX)
);
GO

BEGIN TRY
    BEGIN TRANSACTION;

    DELETE FROM audit.Data_Validation_Errors;

    /* =========================================================
       MAPPED: pull JSON fields from raw. A blank/crashing cell
       in CSV returns an empty string, never an error.
       ========================================================= */
    ;WITH Mapped AS
    (
        SELECT
            R.Raw_ID,
            R.Source_Country,
            R.Source_File,
            R.Source_Row_Number,
            R.File_Date,
            R.Batch_ID,

            CASE R.Source_Country
                WHEN 'AUS' THEN JSON_VALUE(R.Raw_Record, '$."Unique ID"')
                ELSE NULLIF(JSON_VALUE(R.Raw_Record, '$.ID'), '')
            END AS Member_ID,

            CASE R.Source_Country
                WHEN 'AUS' THEN NULLIF(JSON_VALUE(R.Raw_Record, '$."Member Name"'), '')
                ELSE NULLIF(JSON_VALUE(R.Raw_Record, '$.Name'), '')
            END AS Member_Name,

            CASE R.Source_Country
                WHEN 'AUS' THEN NULLIF(JSON_VALUE(R.Raw_Record, '$."Tier Type"'), '')
                ELSE NULLIF(JSON_VALUE(R.Raw_Record, '$.TierCode'), '')
            END AS Tier_Code,

            /* DOB: USA file has no DOB column -> NULL */
            CASE R.Source_Country
                WHEN 'AUS' THEN NULLIF(JSON_VALUE(R.Raw_Record, '$."Date of Birth"'), 'NULL')
                WHEN 'IND' THEN NULLIF(JSON_VALUE(R.Raw_Record, '$.DOB'), 'NULL')
                ELSE NULL
            END AS DOB_Raw,

            CASE R.Source_Country
                WHEN 'AUS' THEN NULLIF(JSON_VALUE(R.Raw_Record, '$."Date of Enrollment"'), '')
                ELSE NULLIF(JSON_VALUE(R.Raw_Record, '$.EnrollmentDate'), '')
            END AS Enrollment_Raw,

            CASE R.Source_Country
                WHEN 'AUS' THEN NULLIF(JSON_VALUE(R.Raw_Record, '$."Date of Flight"'), '')
                WHEN 'IND' THEN NULLIF(JSON_VALUE(R.Raw_Record, '$."Flight Date"'), '')
                ELSE NULLIF(JSON_VALUE(R.Raw_Record, '$.FlightDate'), '')
            END AS Flight_Raw,

            CASE
                WHEN R.Source_Country = 'IND'
                THEN NULLIF(JSON_VALUE(R.Raw_Record, '$."Individual or Corporate"'), '')
                ELSE NULL
            END AS Member_Type
        FROM raw.Member_Profile_Raw R
    ),
    /* =========================================================
       PARSED: convert raw strings to dates.
       ========================================================= */
    Parsed AS
    (
        SELECT
            M.*,

            COALESCE(
                TRY_CONVERT(DATE, LEFT(M.DOB_Raw, 10), 23),
                TRY_CONVERT(DATE, LEFT(M.DOB_Raw, 10), 101)
            ) AS DOB_Date,

            CASE
                WHEN M.Source_Country = 'USA'
                THEN TRY_CONVERT(
                        DATE,
                        CASE
                            WHEN LEN(M.Enrollment_Raw) = 7
                            THEN RIGHT(M.Enrollment_Raw, 4)
                               + RIGHT('0' + LEFT(M.Enrollment_Raw, 1), 2)
                               + SUBSTRING(M.Enrollment_Raw, 2, 2)
                            WHEN LEN(M.Enrollment_Raw) = 8
                            THEN RIGHT(M.Enrollment_Raw, 4)
                               + LEFT(M.Enrollment_Raw, 2)
                               + SUBSTRING(M.Enrollment_Raw, 3, 2)
                            ELSE LEFT(M.Enrollment_Raw, 10)
                        END,
                        112
                     )
                ELSE COALESCE(
                        TRY_CONVERT(DATE, LEFT(M.Enrollment_Raw, 10), 23),
                        TRY_CONVERT(DATE, LEFT(M.Enrollment_Raw, 10), 101)
                     )
            END AS Enrollment_Date,

            CASE
                WHEN M.Source_Country = 'USA'
                THEN TRY_CONVERT(
                        DATE,
                        CASE
                            WHEN LEN(M.Flight_Raw) = 7
                            THEN RIGHT(M.Flight_Raw, 4)
                               + RIGHT('0' + LEFT(M.Flight_Raw, 1), 2)
                               + SUBSTRING(M.Flight_Raw, 2, 2)
                            WHEN LEN(M.Flight_Raw) = 8
                            THEN RIGHT(M.Flight_Raw, 4)
                               + LEFT(M.Flight_Raw, 2)
                               + SUBSTRING(M.Flight_Raw, 3, 2)
                            ELSE LEFT(M.Flight_Raw, 10)
                        END,
                        112
                     )
                ELSE COALESCE(
                        TRY_CONVERT(DATE, LEFT(M.Flight_Raw, 10), 23),
                        TRY_CONVERT(DATE, LEFT(M.Flight_Raw, 10), 101)
                     )
            END AS Last_Flight_Date
        FROM Mapped M
    ),
    /* =========================================================
       FINAL: validate mandatory fields.
       ========================================================= */
    Final AS
    (
        SELECT
            P.*,

            CASE
                WHEN NULLIF(LTRIM(RTRIM(P.Member_ID)), '') IS NULL
                  AND P.Enrollment_Date IS NULL
                    THEN 'REJECTED'
                WHEN P.Enrollment_Date IS NULL
                    THEN 'REJECTED'
                WHEN NULLIF(LTRIM(RTRIM(P.Member_Name)), '') IS NULL
                    THEN 'REJECTED'
                ELSE 'VALID'
            END AS Validation_Status,

            CASE
                WHEN NULLIF(LTRIM(RTRIM(P.Member_ID)), '') IS NULL
                  AND P.Enrollment_Date IS NULL
                    THEN N'Member_ID is missing; Enrollment_Date is missing or not a valid date. Raw Enrollment value: '
                         + ISNULL(P.Enrollment_Raw, N'<null>')
                WHEN P.Enrollment_Date IS NULL
                    THEN N'Enrollment_Date is missing or not a valid date. Raw Enrollment value: '
                         + ISNULL(P.Enrollment_Raw, N'<null>')
                WHEN NULLIF(LTRIM(RTRIM(P.Member_Name)), '') IS NULL
                    THEN N'Member_Name is missing'
                ELSE NULL
            END AS Validation_Errors

        FROM Parsed P
    )
    INSERT INTO stg.Member_Profile_Stg
    (
        Member_ID, Member_Name, Enrollment_Date, Last_Flight_Date,
        Tier_Code, Agent_Name, State, Country, Post_Code, DOB,
        Is_Active, Member_Type, Age, Stale_Member,
        Source_Country, Source_File, Source_Row_Number,
        Source_Updated_At, File_Date, Batch_ID,
        Validation_Status, Validation_Errors
    )
    SELECT
        F.Member_ID,
        ISNULL(F.Member_Name, '')          AS Member_Name,
        F.Enrollment_Date,
        F.Last_Flight_Date,
        F.Tier_Code,
        NULL                               AS Agent_Name,
        NULL                               AS State,
        F.Source_Country                   AS Country,
        NULL                               AS Post_Code,
        F.DOB_Date,
        NULL                               AS Is_Active,
        F.Member_Type,

        CASE
            WHEN F.DOB_Date IS NULL THEN NULL
            ELSE
                DATEDIFF(YEAR, F.DOB_Date, CAST(GETDATE() AS DATE))
                - CASE
                    WHEN DATEADD(YEAR,
                               DATEDIFF(YEAR, F.DOB_Date, CAST(GETDATE() AS DATE)),
                               F.DOB_Date) > CAST(GETDATE() AS DATE)
                    THEN 1 ELSE 0
                  END
        END                                AS Age,

        CASE
            WHEN F.Last_Flight_Date IS NOT NULL
             AND DATEADD(DAY, 90, F.Last_Flight_Date) < CAST(GETDATE() AS DATE)
            THEN 1 ELSE 0
        END                                AS Stale_Member,

        F.Source_Country,
        F.Source_File,
        F.Source_Row_Number,
        GETDATE()                          AS Source_Updated_At,
        F.File_Date,
        F.Batch_ID,
        F.Validation_Status,
        F.Validation_Errors
    FROM Final F;

    DECLARE @InsertedRows INT = @@ROWCOUNT;

    /* =========================================================
       LOG REJECTED ROWS TO AUDIT TABLE.
       Includes Batch_ID now. Joins raw using Source_File +
       Source_Row_Number + Batch_ID so an old batch cannot
       masquerade as a new one.
       ========================================================= */
    INSERT INTO audit.Data_Validation_Errors
    (
        Source_File, Source_Row_Number, Member_ID,
        Column_Name, Invalid_Value, Error_Description,
        Batch_ID
    )
    SELECT
        s.Source_File,
        s.Source_Row_Number,
        ISNULL(NULLIF(LTRIM(RTRIM(s.Member_ID)), ''), '<missing>'),

        CASE
            WHEN NULLIF(LTRIM(RTRIM(s.Member_ID)), '') IS NULL AND s.Enrollment_Date IS NULL
                THEN 'Multiple_Columns'
            WHEN NULLIF(LTRIM(RTRIM(s.Member_ID)), '') IS NULL
                THEN 'Member_ID'
            WHEN s.Enrollment_Date IS NULL
                THEN 'Enrollment_Date'
            ELSE 'Member_Name'
        END,

        CASE
            WHEN s.Enrollment_Date IS NULL
                THEN ISNULL(
                        CASE s.Source_Country
                            WHEN 'AUS' THEN JSON_VALUE(r.Raw_Record, '$."Date of Enrollment"')
                            ELSE JSON_VALUE(r.Raw_Record, '$.EnrollmentDate')
                        END,
                        N'<null>'
                     )
            ELSE N'<blank>'
        END,

        s.Validation_Errors,

        s.Batch_ID

    FROM stg.Member_Profile_Stg s
    LEFT JOIN raw.Member_Profile_Raw r
      ON r.Source_File       = s.Source_File
     AND r.Source_Row_Number = s.Source_Row_Number
     AND r.Batch_ID          = s.Batch_ID
    WHERE s.Validation_Status = 'REJECTED';

    COMMIT TRANSACTION;

    PRINT 'STAGING LOAD COMPLETED SUCCESSFULLY';
    PRINT 'Records inserted: ' + CAST(@InsertedRows AS VARCHAR(20));

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT 'STAGING LOAD FAILED';
    PRINT ERROR_MESSAGE();
    THROW;
END CATCH;
GO

/* =========================================================================
   VERIFICATION 1: staging counts by country
   ========================================================================= */
SELECT
    Source_Country,
    COUNT(*)                                                        AS Total_Records,
    SUM(CASE WHEN Validation_Status = 'VALID'    THEN 1 ELSE 0 END) AS Valid_Records,
    SUM(CASE WHEN Validation_Status = 'REJECTED' THEN 1 ELSE 0 END) AS Rejected_Records
FROM stg.Member_Profile_Stg
GROUP BY Source_Country
ORDER BY Source_Country;
GO

/* =========================================================================
   VERIFICATION 2: rejected rows
   ========================================================================= */
SELECT
    Source_Country, Source_File, Source_Row_Number,
    Member_ID, Member_Name, Enrollment_Date,
    Validation_Status, Validation_Errors
FROM stg.Member_Profile_Stg
WHERE Validation_Status = 'REJECTED'
ORDER BY Source_Country, Source_Row_Number;
GO

/* =========================================================================
   VERIFICATION 3: audit entries
   ========================================================================= */
SELECT
    Source_File, Source_Row_Number, Member_ID,
    Column_Name, Invalid_Value, Error_Description,
    Batch_ID, Error_Date
FROM audit.Data_Validation_Errors
ORDER BY Source_File, Source_Row_Number;
GO
