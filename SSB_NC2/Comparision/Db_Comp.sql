SET NOCOUNT ON;

DECLARE @CollectionTime DATETIME = GETDATE();

;WITH ObjectCounts AS
(
    SELECT
        'Tables' AS ObjectName,
        COUNT(*) AS TotalCount
    FROM sys.tables

    UNION ALL

    SELECT
        'Views',
        COUNT(*)
    FROM sys.views

    UNION ALL

    SELECT
        'Stored Procedures',
        COUNT(*)
    FROM sys.procedures

    UNION ALL

    SELECT
        'Functions',
        COUNT(*)
    FROM sys.objects
    WHERE type IN ('FN','IF','TF','FS','FT')

    UNION ALL

    SELECT
        'Triggers',
        COUNT(*)
    FROM sys.triggers

    UNION ALL

    SELECT
        'Synonyms',
        COUNT(*)
    FROM sys.synonyms

    UNION ALL

    SELECT
        'Sequences',
        COUNT(*)
    FROM sys.sequences

    UNION ALL

    SELECT
        'User Defined Tables Types',
        COUNT(*)
    FROM sys.table_types

    UNION ALL

    SELECT
        'Schemas',
        COUNT(*)
    FROM sys.schemas

    UNION ALL

    SELECT
        'Database Users',
        COUNT(*)
    FROM sys.database_principals
    WHERE type IN ('S','U','G','E','X')
      AND principal_id > 4

    UNION ALL

    SELECT
        'Database Roles',
        COUNT(*)
    FROM sys.database_principals
    WHERE type = 'R'

    UNION ALL

    SELECT
        'All User Objects',
        COUNT(*)
    FROM sys.objects
    WHERE is_ms_shipped = 0

    UNION ALL

    SELECT
        'All Objects',
        COUNT(*)
    FROM sys.objects
)
SELECT
      @@SERVERNAME AS ServerName
    , DB_NAME() AS DatabaseName
    , ObjectName
    , TotalCount
    , @CollectionTime AS CollectionTime
FROM ObjectCounts
ORDER BY ObjectName;
