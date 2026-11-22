/*=============================================================
  STEP 1: SkyPoints - Database, Schemas, Tables, Indexes

  Idempotent. Safe to re-run.
  Also widens columns on tables created by earlier revisions so an
  existing database picks up the new (roomier) definitions.
=============================================================*/

USE master;
GO

IF DB_ID('SkyPoints_DataEngineering') IS NULL
BEGIN
    CREATE DATABASE SkyPoints_DataEngineering;
    PRINT 'Database SkyPoints_DataEngineering created.';
END
ELSE
    PRINT 'Database SkyPoints_DataEngineering already exists.';
GO

USE SkyPoints_DataEngineering;
GO

-- -------------------------------------------------------
-- STEP 2: Schemas
-- -------------------------------------------------------
IF SCHEMA_ID('raw')     IS NULL EXEC('CREATE SCHEMA raw     AUTHORIZATION dbo');
IF SCHEMA_ID('stg')     IS NULL EXEC('CREATE SCHEMA stg     AUTHORIZATION dbo');
IF SCHEMA_ID('curated') IS NULL EXEC('CREATE SCHEMA curated AUTHORIZATION dbo');
IF SCHEMA_ID('audit')   IS NULL EXEC('CREATE SCHEMA audit   AUTHORIZATION dbo');
GO

-- -------------------------------------------------------
-- STEP 3: RAW member profile landing table
-- -------------------------------------------------------
IF OBJECT_ID('raw.Member_Profile_Raw', 'U') IS NULL
BEGIN
    CREATE TABLE raw.Member_Profile_Raw
    (
        Raw_ID              BIGINT IDENTITY(1,1) PRIMARY KEY,
        Source_Country      VARCHAR(5)    NOT NULL,
        Source_File         VARCHAR(255)  NOT NULL,
        Source_Row_Number   INT           NOT NULL,
        Raw_Record          NVARCHAR(MAX) NOT NULL,
        File_Date           DATE          NULL,
        Batch_ID            VARCHAR(100)  NOT NULL,
        Ingested_At         DATETIME2(0)  CONSTRAINT DF_Member_Profile_Raw_Ingested DEFAULT SYSDATETIME()
    );
    PRINT 'Table raw.Member_Profile_Raw created.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Member_Profile_Raw_Src'
                 AND object_id = OBJECT_ID('raw.Member_Profile_Raw'))
    CREATE INDEX IX_Member_Profile_Raw_Src
        ON raw.Member_Profile_Raw (Source_File, Source_Row_Number, Batch_ID);
GO

-- -------------------------------------------------------
-- STEP 4: RAW redemption table
-- -------------------------------------------------------
IF OBJECT_ID('raw.Redemption_Raw', 'U') IS NULL
BEGIN
    CREATE TABLE raw.Redemption_Raw
    (
        Raw_ID              BIGINT IDENTITY(1,1) PRIMARY KEY,
        Source_File         VARCHAR(255)  NOT NULL,
        Raw_Payload         NVARCHAR(MAX) NOT NULL,
        File_Date           DATE          NULL,
        Batch_ID            VARCHAR(100)  NOT NULL,
        Ingested_At         DATETIME2(0)  CONSTRAINT DF_Redemption_Raw_Ingested DEFAULT SYSDATETIME()
    );
    PRINT 'Table raw.Redemption_Raw created.';
END
GO

-- -------------------------------------------------------
-- STEP 5: STAGING redemption table
-- -------------------------------------------------------
IF OBJECT_ID('stg.Redemption_Stg', 'U') IS NULL
BEGIN
    CREATE TABLE stg.Redemption_Stg
    (
        Redemption_ID       BIGINT IDENTITY(1,1) PRIMARY KEY,
        Member_ID           VARCHAR(50),
        Feed_Date           DATE,
        Transaction_ID      VARCHAR(50),
        Transaction_Date    DATE,
        Partner             VARCHAR(100),
        Miles_Redeemed      BIGINT,
        Status              VARCHAR(30),

        Source_File         VARCHAR(255),
        Batch_ID            VARCHAR(100),
        Created_At          DATETIME2(0) CONSTRAINT DF_Redemption_Stg_Created DEFAULT SYSDATETIME()
    );
    PRINT 'Table stg.Redemption_Stg created.';
END
GO

-- widen if an older revision created narrower columns
IF COL_LENGTH('stg.Redemption_Stg', 'Member_ID') < 50
    ALTER TABLE stg.Redemption_Stg ALTER COLUMN Member_ID VARCHAR(50);
IF COL_LENGTH('stg.Redemption_Stg', 'Transaction_ID') < 50
    ALTER TABLE stg.Redemption_Stg ALTER COLUMN Transaction_ID VARCHAR(50);
IF COL_LENGTH('stg.Redemption_Stg', 'Partner') < 100
    ALTER TABLE stg.Redemption_Stg ALTER COLUMN Partner VARCHAR(100);
IF COL_LENGTH('stg.Redemption_Stg', 'Source_File') < 255
    ALTER TABLE stg.Redemption_Stg ALTER COLUMN Source_File VARCHAR(255);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Redemption_Stg_Member_Txn'
                 AND object_id = OBJECT_ID('stg.Redemption_Stg'))
    CREATE INDEX IX_Redemption_Stg_Member_Txn
        ON stg.Redemption_Stg (Member_ID, Transaction_ID);
GO

-- -------------------------------------------------------
-- STEP 6: STAGING member profile table
--   Member_ID is NULLABLE on purpose: rows that fail validation
--   must still land in staging so they can be rejected + audited
--   instead of aborting the load.
-- -------------------------------------------------------
IF OBJECT_ID('stg.Member_Profile_Stg', 'U') IS NULL
BEGIN
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
    PRINT 'Table stg.Member_Profile_Stg created.';
END
GO

-- widen / relax if an older revision created a stricter version
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('stg.Member_Profile_Stg')
             AND name = 'Member_ID' AND (max_length < 50 OR is_nullable = 0))
    ALTER TABLE stg.Member_Profile_Stg ALTER COLUMN Member_ID VARCHAR(50) NULL;
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('stg.Member_Profile_Stg')
             AND name = 'Member_Name' AND max_length < 255)
    ALTER TABLE stg.Member_Profile_Stg ALTER COLUMN Member_Name VARCHAR(255) NULL;
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('stg.Member_Profile_Stg')
             AND name = 'Tier_Code' AND max_length < 20)
    ALTER TABLE stg.Member_Profile_Stg ALTER COLUMN Tier_Code VARCHAR(20);
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('stg.Member_Profile_Stg')
             AND name = 'State' AND max_length < 50)
    ALTER TABLE stg.Member_Profile_Stg ALTER COLUMN State VARCHAR(50);
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('stg.Member_Profile_Stg')
             AND name = 'Country' AND max_length < 20)
    ALTER TABLE stg.Member_Profile_Stg ALTER COLUMN Country VARCHAR(20);
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('stg.Member_Profile_Stg')
             AND name = 'Source_File' AND max_length < 255)
    ALTER TABLE stg.Member_Profile_Stg ALTER COLUMN Source_File VARCHAR(255);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Member_Profile_Stg_Country'
                 AND object_id = OBJECT_ID('stg.Member_Profile_Stg'))
    CREATE INDEX IX_Member_Profile_Stg_Country
        ON stg.Member_Profile_Stg (Source_Country, Member_ID, Validation_Status);
GO

-- -------------------------------------------------------
-- STEP 7-9: CURATED target tables (one per country)
-- -------------------------------------------------------
IF OBJECT_ID('curated.Table_India', 'U') IS NULL
BEGIN
    CREATE TABLE curated.Table_India
    (
        Member_ID           VARCHAR(50)  PRIMARY KEY,
        Member_Name         VARCHAR(255) NOT NULL,
        Enrollment_Date     DATE NOT NULL,
        Last_Flight_Date    DATE,
        Tier_Code           VARCHAR(20),
        Agent_Name          VARCHAR(255),
        State               VARCHAR(50),
        Country             VARCHAR(20) NOT NULL,
        Post_Code           VARCHAR(20),
        DOB                 DATE,
        Is_Active           CHAR(1),
        Member_Type         VARCHAR(30),
        Age                 INT,
        Stale_Member        BIT,
        Source_Updated_At   DATETIME2(0),
        Last_Loaded_At      DATETIME2(0) CONSTRAINT DF_Table_India_Loaded DEFAULT SYSDATETIME()
    );
    PRINT 'Table curated.Table_India created.';
END
GO

IF OBJECT_ID('curated.Table_USA', 'U') IS NULL
BEGIN
    CREATE TABLE curated.Table_USA
    (
        Member_ID           VARCHAR(50)  PRIMARY KEY,
        Member_Name         VARCHAR(255) NOT NULL,
        Enrollment_Date     DATE NOT NULL,
        Last_Flight_Date    DATE,
        Tier_Code           VARCHAR(20),
        Agent_Name          VARCHAR(255),
        State               VARCHAR(50),
        Country             VARCHAR(20) NOT NULL,
        Post_Code           VARCHAR(20),
        DOB                 DATE,
        Is_Active           CHAR(1),
        Member_Type         VARCHAR(30),
        Age                 INT,
        Stale_Member        BIT,
        Source_Updated_At   DATETIME2(0),
        Last_Loaded_At      DATETIME2(0) CONSTRAINT DF_Table_USA_Loaded DEFAULT SYSDATETIME()
    );
    PRINT 'Table curated.Table_USA created.';
END
GO

IF OBJECT_ID('curated.Table_AUS', 'U') IS NULL
BEGIN
    CREATE TABLE curated.Table_AUS
    (
        Member_ID           VARCHAR(50)  PRIMARY KEY,
        Member_Name         VARCHAR(255) NOT NULL,
        Enrollment_Date     DATE NOT NULL,
        Last_Flight_Date    DATE,
        Tier_Code           VARCHAR(20),
        Agent_Name          VARCHAR(255),
        State               VARCHAR(50),
        Country             VARCHAR(20) NOT NULL,
        Post_Code           VARCHAR(20),
        DOB                 DATE,
        Is_Active           CHAR(1),
        Member_Type         VARCHAR(30),
        Age                 INT,
        Stale_Member        BIT,
        Source_Updated_At   DATETIME2(0),
        Last_Loaded_At      DATETIME2(0) CONSTRAINT DF_Table_AUS_Loaded DEFAULT SYSDATETIME()
    );
    PRINT 'Table curated.Table_AUS created.';
END
GO

-- -------------------------------------------------------
-- STEP 9b: widen CURATED columns created by earlier revisions
--          (loop keeps this in one place for all three tables)
-- -------------------------------------------------------
DECLARE @tbl SYSNAME, @fix NVARCHAR(MAX);

DECLARE widen CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.tables
    WHERE schema_id = SCHEMA_ID('curated')
      AND name IN ('Table_India', 'Table_USA', 'Table_AUS');

OPEN widen;
FETCH NEXT FROM widen INTO @tbl;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @fix = N'';

    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('curated.' + @tbl)
                 AND name = 'Member_ID' AND max_length < 50)
        SET @fix += N'ALTER TABLE curated.' + QUOTENAME(@tbl) + N' ALTER COLUMN Member_ID VARCHAR(50) NOT NULL;';

    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('curated.' + @tbl)
                 AND name = 'Tier_Code' AND max_length < 20)
        SET @fix += N'ALTER TABLE curated.' + QUOTENAME(@tbl) + N' ALTER COLUMN Tier_Code VARCHAR(20);';

    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('curated.' + @tbl)
                 AND name = 'State' AND max_length < 50)
        SET @fix += N'ALTER TABLE curated.' + QUOTENAME(@tbl) + N' ALTER COLUMN State VARCHAR(50);';

    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('curated.' + @tbl)
                 AND name = 'Country' AND max_length < 20)
        SET @fix += N'ALTER TABLE curated.' + QUOTENAME(@tbl) + N' ALTER COLUMN Country VARCHAR(20) NOT NULL;';

    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('curated.' + @tbl)
                 AND name = 'Member_Type' AND max_length < 30)
        SET @fix += N'ALTER TABLE curated.' + QUOTENAME(@tbl) + N' ALTER COLUMN Member_Type VARCHAR(30);';

    IF LEN(@fix) > 0
    BEGIN
        PRINT 'Widening curated.' + @tbl;
        EXEC sp_executesql @fix;
    END

    FETCH NEXT FROM widen INTO @tbl;
END

CLOSE widen;
DEALLOCATE widen;
GO

-- -------------------------------------------------------
-- STEP 10: AUDIT validation error table
-- -------------------------------------------------------
IF OBJECT_ID('audit.Data_Validation_Errors', 'U') IS NULL
BEGIN
    CREATE TABLE audit.Data_Validation_Errors
    (
        Error_ID            BIGINT IDENTITY(1,1) PRIMARY KEY,
        Source_File         VARCHAR(255),
        Source_Row_Number   INT,
        Member_ID           VARCHAR(50),
        Column_Name         VARCHAR(100),
        Invalid_Value       NVARCHAR(500),
        Error_Description   NVARCHAR(1000),
        Batch_ID            VARCHAR(100),
        Error_Date          DATETIME2(0) CONSTRAINT DF_Validation_Errors_Date DEFAULT SYSDATETIME()
    );
    PRINT 'Table audit.Data_Validation_Errors created.';
END
GO

IF COL_LENGTH('audit.Data_Validation_Errors', 'Member_ID') < 50
    ALTER TABLE audit.Data_Validation_Errors ALTER COLUMN Member_ID VARCHAR(50);
GO

-- -------------------------------------------------------
-- STEP 11: AUDIT ETL batch log table
-- -------------------------------------------------------
IF OBJECT_ID('audit.ETL_Batch_Log', 'U') IS NULL
BEGIN
    CREATE TABLE audit.ETL_Batch_Log
    (
        Batch_Log_ID        BIGINT IDENTITY(1,1) PRIMARY KEY,
        Batch_ID            VARCHAR(100),
        Source_File         VARCHAR(255),
        Process_Name        VARCHAR(100),
        Start_Time          DATETIME2(0),
        End_Time            DATETIME2(0),
        Total_Records       BIGINT DEFAULT 0,
        Successful_Records  BIGINT DEFAULT 0,
        Failed_Records      BIGINT DEFAULT 0,
        Batch_Status        VARCHAR(30),
        Error_Message       NVARCHAR(MAX)
    );
    PRINT 'Table audit.ETL_Batch_Log created.';
END
GO

-- -------------------------------------------------------
-- STEP 12: AUDIT data quality summary table
-- -------------------------------------------------------
IF OBJECT_ID('audit.Data_Quality_Summary', 'U') IS NULL
BEGIN
    CREATE TABLE audit.Data_Quality_Summary
    (
        Summary_ID          BIGINT IDENTITY(1,1) PRIMARY KEY,
        Batch_ID            VARCHAR(100),
        Source_File         VARCHAR(255),
        Rule_Name           VARCHAR(100),
        Total_Checked       BIGINT,
        Passed_Records      BIGINT,
        Failed_Records      BIGINT,
        Execution_Date      DATETIME2(0) CONSTRAINT DF_DQ_Summary_Date DEFAULT SYSDATETIME()
    );
    PRINT 'Table audit.Data_Quality_Summary created.';
END
GO

-- -------------------------------------------------------
-- STEP 13: Verify
-- -------------------------------------------------------
SELECT
    DB_NAME() AS Database_Name,
    s.name    AS Schema_Name,
    t.name    AS Table_Name,
    p.rows    AS Row_Estimate
FROM sys.schemas s
JOIN sys.tables t ON s.schema_id = t.schema_id
JOIN sys.partitions p ON t.object_id = p.object_id
WHERE s.name IN ('raw', 'stg', 'curated', 'audit')
  AND p.index_id IN (0, 1)
GROUP BY s.name, t.name, p.rows
ORDER BY s.name, t.name;
GO

PRINT 'All SkyPoints tables created / verified successfully.';
GO
