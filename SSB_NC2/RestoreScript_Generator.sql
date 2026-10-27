DECLARE @BackupFolder VARCHAR(500) = 'H:\SQLBackups';
DECLARE @DataPath     VARCHAR(500) = 'L:\SQLData';
DECLARE @LogPath      VARCHAR(500) = 'M:\SQLLogs';

IF OBJECT_ID('tempdb..#Files') IS NOT NULL
    DROP TABLE #Files;

CREATE TABLE #Files
(
    subdirectory NVARCHAR(512),
    depth INT,
    isfile BIT
);

INSERT INTO #Files
EXEC master.sys.xp_dirtree @BackupFolder, 1, 1;

SELECT
    'RESTORE DATABASE [' +
    LEFT(subdirectory, LEN(subdirectory) - 13) + -- Removes _YYYYMMDD.bak
    ']
FROM DISK = N''' + @BackupFolder + '\' + subdirectory + '''
WITH
    -- Update logical names after RESTORE FILELISTONLY
    MOVE ''LogicalData'' TO N''' + @DataPath + '\' +
    LEFT(subdirectory, LEN(subdirectory) - 4) + '.mdf'',
    MOVE ''LogicalLog'' TO N''' + @LogPath + '\' +
    LEFT(subdirectory, LEN(subdirectory) - 4) + '_Log.ldf'',
    REPLACE,
    RECOVERY,
    STATS = 10;
GO
'
AS RestoreScript
FROM #Files
WHERE isfile = 1
  AND subdirectory LIKE '%.bak'
ORDER BY subdirectory;
