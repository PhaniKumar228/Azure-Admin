----------------------------------------------------------------------------
-- INPUTS
----------------------------------------------------------------------------
DECLARE @BackupFolder VARCHAR(4000) = 'H:\SQLBackups';
DECLARE @DataFolder   VARCHAR(4000) = 'L:\SQLData';
DECLARE @LogFolder    VARCHAR(4000) = 'M:\SQLLogs';

----------------------------------------------------------------------------
-- GET BAK FILES
----------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#BackupFiles') IS NOT NULL
    DROP TABLE #BackupFiles;

CREATE TABLE #BackupFiles
(
    FileName VARCHAR(4000)
);

INSERT INTO #BackupFiles
EXEC xp_cmdshell 'dir /b "H:\SQLBackups\*.bak"';

DELETE FROM #BackupFiles
WHERE FileName IS NULL;

----------------------------------------------------------------------------
-- GENERATE RESTORE SCRIPTS
----------------------------------------------------------------------------
DECLARE
      @FileName      VARCHAR(4000)
    , @BackupFile    VARCHAR(4000)
    , @SQL           NVARCHAR(MAX)
    , @RestoreSQL    NVARCHAR(MAX)
    , @DBName        SYSNAME;

DECLARE FileCursor CURSOR FAST_FORWARD
FOR
SELECT FileName
FROM #BackupFiles
ORDER BY FileName;

OPEN FileCursor;

FETCH NEXT FROM FileCursor INTO @FileName;

WHILE @@FETCH_STATUS = 0
BEGIN

    SET @BackupFile = @BackupFolder + '\' + @FileName;

    ------------------------------------------------------------------------
    -- GET LOGICAL FILE NAMES
    ------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#FileList') IS NOT NULL
        DROP TABLE #FileList;

    CREATE TABLE #FileList
    (
        LogicalName           NVARCHAR(128),
        PhysicalName          NVARCHAR(260),
        [Type]                CHAR(1),
        FileGroupName         NVARCHAR(128),
        Size                  NUMERIC(20,0),
        MaxSize               NUMERIC(20,0),
        FileID                BIGINT,
        CreateLSN             NUMERIC(25,0),
        DropLSN               NUMERIC(25,0),
        UniqueID              UNIQUEIDENTIFIER,
        ReadOnlyLSN           NUMERIC(25,0),
        ReadWriteLSN          NUMERIC(25,0),
        BackupSizeInBytes     BIGINT,
        SourceBlockSize       INT,
        FileGroupID           INT,
        LogGroupGUID          UNIQUEIDENTIFIER,
        DifferentialBaseLSN   NUMERIC(25,0),
        DifferentialBaseGUID  UNIQUEIDENTIFIER,
        IsReadOnly            BIT,
        IsPresent             BIT,
        TDEThumbprint         VARBINARY(32),
        SnapshotURL           NVARCHAR(360)
    );

    SET @SQL =
    'RESTORE FILELISTONLY FROM DISK = ''' + @BackupFile + '''';

    INSERT #FileList
    EXEC (@SQL);

    ------------------------------------------------------------------------
    -- GET DATABASE NAME
    ------------------------------------------------------------------------
    SELECT TOP(1)
        @DBName = LEFT(@FileName, LEN(@FileName) - 13) -- removes _YYYYMMDD.bak
    WHERE @FileName LIKE '%_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].bak';

    IF @DBName IS NULL
        SET @DBName = REPLACE(@FileName,'.bak','');

    ------------------------------------------------------------------------
    -- BUILD RESTORE COMMAND
    ------------------------------------------------------------------------
    SET @RestoreSQL =
    'RESTORE DATABASE [' + @DBName + ']
FROM DISK = N''' + @BackupFile + '''
WITH ';

    SELECT @RestoreSQL =
           @RestoreSQL +
           '
MOVE N''' + LogicalName + ''' TO N''' +
           CASE
               WHEN [Type] = 'L'
               THEN @LogFolder + '\' + @DBName + '_Log.ldf'
               ELSE @DataFolder + '\' + @DBName +
                    CASE
                        WHEN ROW_NUMBER() OVER (PARTITION BY [Type] ORDER BY FileID) = 1
                            THEN '.mdf'
                        ELSE '_' + CAST(FileID AS VARCHAR(10)) + '.ndf'
                    END
           END + ''','
    FROM #FileList
    ORDER BY FileID;

    SET @RestoreSQL =
        LEFT(@RestoreSQL,LEN(@RestoreSQL)-1) +
        '
, RECOVERY
, REPLACE
, STATS = 10;
GO

';

    PRINT REPLICATE('-',100);
    PRINT @RestoreSQL;

    FETCH NEXT FROM FileCursor INTO @FileName;

END

CLOSE FileCursor;
DEALLOCATE FileCursor;
