Import-Module SqlServer

$SourceServer = "SourceSQL"
$SourceDB     = "SourceDB"

$TargetServer = "TargetSQL"
$TargetDB     = "TargetDB"

# Get database users from source
$Users = Invoke-Sqlcmd -ServerInstance $SourceServer -Database $SourceDB -Query "
SELECT dp.name
FROM sys.database_principals dp
WHERE dp.type = 'S'
AND dp.principal_id > 4
AND dp.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys')
"

foreach ($User in $Users)
{
    $LoginName = $User.name

    Write-Host "Processing $LoginName"

    # Check source login
    $SourceLogin = Invoke-Sqlcmd -ServerInstance $SourceServer -Database master -Query "
    SELECT name
    FROM sys.server_principals
    WHERE name = '$LoginName'
    "

    if ($SourceLogin)
    {
        # Create login on target if missing
        $LoginExists = Invoke-Sqlcmd -ServerInstance $TargetServer -Database master -Query "
        SELECT name
        FROM sys.server_principals
        WHERE name = '$LoginName'
        "

        if (!$LoginExists)
        {
            $CreateLogin = @"
IF NOT EXISTS (
    SELECT 1
    FROM sys.server_principals
    WHERE name = '$LoginName'
)
BEGIN
    CREATE LOGIN [$LoginName]
    FROM WINDOWS
END
"@

            Invoke-Sqlcmd -ServerInstance $TargetServer -Database master -Query $CreateLogin
        }

        # Remap orphaned user
        $FixUser = @"
USE [$TargetDB];

IF EXISTS (
    SELECT 1
    FROM sys.database_principals
    WHERE name = '$LoginName'
)
BEGIN
    ALTER USER [$LoginName]
    WITH LOGIN = [$LoginName]
END
"@

        Invoke-Sqlcmd -ServerInstance $TargetServer -Query $FixUser
    }
}

# Script database role memberships
$RoleMemberships = Invoke-Sqlcmd -ServerInstance $SourceServer -Database $SourceDB -Query "
SELECT
    m.name AS MemberName,
    r.name AS RoleName
FROM sys.database_role_members drm
JOIN sys.database_principals r
    ON drm.role_principal_id=r.principal_id
JOIN sys.database_principals m
    ON drm.member_principal_id=m.principal_id
"

foreach ($Role in $RoleMemberships)
{
    $SQL = @"
USE [$TargetDB];
ALTER ROLE [$($Role.RoleName)]
ADD MEMBER [$($Role.MemberName)];
"@

    try
    {
        Invoke-Sqlcmd -ServerInstance $TargetServer -Query $SQL
    }
    catch {}
}

# Script object/database permissions
$Permissions = Invoke-Sqlcmd -ServerInstance $SourceServer -Database $SourceDB -Query "
SELECT
    USER_NAME(dp.grantee_principal_id) AS UserName,
    dp.permission_name,
    dp.state_desc,
    OBJECT_NAME(dp.major_id) AS ObjectName
FROM sys.database_permissions dp
WHERE USER_NAME(dp.grantee_principal_id) IS NOT NULL
"

foreach ($Perm in $Permissions)
{
    if ($Perm.ObjectName)
    {
        $SQL = "
USE [$TargetDB];
$($Perm.state_desc) $($Perm.permission_name)
ON OBJECT::[$($Perm.ObjectName)]
TO [$($Perm.UserName)];
"
    }

    try
    {
        Invoke-Sqlcmd -ServerInstance $TargetServer -Query $SQL
    }
    catch {}
}
