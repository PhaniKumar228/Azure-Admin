<#
.SYNOPSIS
    Compares SQL objects between two Azure Managed Instances and generates an HTML report.

.DESCRIPTION
    Connects to Primary and Secondary Azure MI using Service Principal credentials
    defined in a JSON config file. Compares: server configs, logins, server roles,
    credentials, linked servers, certificates, databases, agent jobs, job steps,
    schedules, operators, alerts, and per-database users/roles/schemas/object counts.

.PARAMETER PrimaryMI
    Short name or FQDN of the Primary Managed Instance (e.g., mi-prod-eastus-01)

.PARAMETER SecondaryMI
    Short name or FQDN of the Secondary Managed Instance (e.g., mi-dr-eastus-01)

.PARAMETER ConfigFilePath
    Path to the JSON credentials config file. Default: .\mi-config.json

.PARAMETER OutputPath
    Path for the HTML report output. Default: .\MI_Comparison_<timestamp>.html

.PARAMETER Port
    SQL port for MI connections. Default: 1433

.EXAMPLE
    .\Compare-AzureMI.ps1 -PrimaryMI "mi-prod-eastus-01" -SecondaryMI "mi-dr-eastus-01"

.EXAMPLE
    .\Compare-AzureMI.ps1 -PrimaryMI "mi-prod-eastus-01" -SecondaryMI "mi-dr-eastus-01" `
        -ConfigFilePath "C:\Configs\mi-config.json" -OutputPath "C:\Reports\comparison.html"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Primary MI short name or FQDN")]
    [string]$PrimaryMI,

    [Parameter(Mandatory = $true, HelpMessage = "Secondary MI short name or FQDN")]
    [string]$SecondaryMI,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFilePath = ".\mi-config.json",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\MI_Comparison_$(Get-Date -Format 'yyyyMMdd_HHmmss').html",

    [Parameter(Mandatory = $false)]
    [int]$Port = 1433
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
#region HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","HEADER")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "HEADER"  { "Magenta" }
        default   { "Cyan" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-AccessToken {
    <#
    .SYNOPSIS Retrieves an OAuth2 token from Azure AD using Client Credentials flow.
    #>
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    try {
        $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/token"
        $body = @{
            grant_type    = "client_credentials"
            resource      = "https://database.windows.net/"
            client_id     = $ClientId
            client_secret = $ClientSecret
        }
        $response = Invoke-RestMethod -Uri $tokenEndpoint -Method Post `
            -Body $body -ContentType "application/x-www-form-urlencoded"
        Write-Log "Access token acquired for ClientId: $ClientId" "SUCCESS"
        return $response.access_token
    }
    catch {
        Write-Log "Failed to acquire token for ClientId '$ClientId': $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Get-MICredentials {
    <#
    .SYNOPSIS Finds matching SPN credentials for a given MI server name from config.
    #>
    param(
        [PSCustomObject]$Config,
        [string]$ServerName
    )
    # Normalize input — strip FQDN suffixes and whitespace
    $normalizedInput = ($ServerName -replace '\..*$', '').Trim().ToLower()

    foreach ($mi in $Config.ManagedInstances) {
        $normalizedConfig = ($mi.ServerName -replace '\..*$', '').Trim().ToLower()
        if ($normalizedConfig -eq $normalizedInput) {
            Write-Log "Matched credentials: '$($mi.ServicePrincipalName)' for server '$ServerName'" "SUCCESS"
            return $mi
        }
    }
    throw "No credentials found in '$ConfigFilePath' for server: '$ServerName'. " +
          "Available entries: $(($Config.ManagedInstances | ForEach-Object { $_.ServerName }) -join ', ')"
}

function New-SQLConnection {
    <#
    .SYNOPSIS Opens a SqlConnection to Azure MI using an AAD access token.
    #>
    param(
        [string]$ServerName,
        [string]$Database = "master",
        [string]$AccessToken,
        [int]$ConnectPort = 1433
    )
    # Build FQDN from config FQDNSuffix if available, otherwise use default pattern
    $fqdn = if ($ServerName -match '\.database\.windows\.net') {
        $ServerName
    } else {
        $matchedMI = $script:Config.ManagedInstances | Where-Object {
            ($_.ServerName -replace '\..*$', '').ToLower() -eq ($ServerName -replace '\..*$', '').ToLower()
        }
        if ($matchedMI -and $matchedMI.FQDNSuffix) {
            "$($matchedMI.ServerName).$($matchedMI.FQDNSuffix)"
        } else {
            # Fallback — caller must provide full FQDN in ServerName
            "$ServerName.database.windows.net"
        }
    }

    $connStr = "Server=tcp:$fqdn,$ConnectPort;" +
               "Initial Catalog=$Database;" +
               "Persist Security Info=False;" +
               "Connect Timeout=60;" +
               "Encrypt=True;" +
               "TrustServerCertificate=False;" +
               "MultipleActiveResultSets=False;"

    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.AccessToken = $AccessToken
        $conn.Open()
        Write-Log "Connected to: $fqdn / $Database" "SUCCESS"
        return $conn
    }
    catch {
        Write-Log "Connection failed to '$fqdn': $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Invoke-SQLQuery {
    <#
    .SYNOPSIS Executes a T-SQL query and returns a DataTable. Returns $null on failure.
    #>
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Query,
        [int]$CommandTimeout = 120
    )
    try {
        $cmd                = $Connection.CreateCommand()
        $cmd.CommandText    = $Query
        $cmd.CommandTimeout = $CommandTimeout
        $adapter            = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $ds                 = New-Object System.Data.DataSet
        $null               = $adapter.Fill($ds)
        return $ds.Tables[0]
    }
    catch {
        Write-Log "Query failed on '$($Connection.DataSource)': $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Compare-ObjectLists {
    <#
    .SYNOPSIS Compares two lists of PSCustomObjects by key. Returns OnlyInPrimary,
              OnlyInSecondary, Different (value diffs), and Matching.
    #>
    param(
        [object[]]$PrimaryList,
        [object[]]$SecondaryList,
        [string]$KeyColumn,
        [string[]]$CompareColumns = @()
    )

    $result = [PSCustomObject]@{
        OnlyInPrimary   = @()
        OnlyInSecondary = @()
        Different       = @()
        Matching        = @()
    }

    $safeP = if ($PrimaryList)   { $PrimaryList   | Where-Object { $_ -ne $null } } else { @() }
    $safeS = if ($SecondaryList) { $SecondaryList | Where-Object { $_ -ne $null } } else { @() }

    $primaryKeys   = $safeP | ForEach-Object { $_.$KeyColumn }
    $secondaryKeys = $safeS | ForEach-Object { $_.$KeyColumn }

    foreach ($item in $safeP) {
        if ($item.$KeyColumn -notin $secondaryKeys) {
            $result.OnlyInPrimary += $item
        }
    }

    foreach ($item in $safeS) {
        if ($item.$KeyColumn -notin $primaryKeys) {
            $result.OnlyInSecondary += $item
        }
    }

    if ($CompareColumns.Count -gt 0) {
        foreach ($pItem in $safeP) {
            $key   = $pItem.$KeyColumn
            $sItem = $safeS | Where-Object { $_.$KeyColumn -eq $key } | Select-Object -First 1
            if ($sItem) {
                $diffs = @()
                foreach ($col in $CompareColumns) {
                    $pVal = if ($null -ne $pItem.$col) { "$($pItem.$col)" } else { "" }
                    $sVal = if ($null -ne $sItem.$col) { "$($sItem.$col)" } else { "" }
                    if ($pVal -ne $sVal) {
                        $diffs += [PSCustomObject]@{
                            Property       = $col
                            PrimaryValue   = $pVal
                            SecondaryValue = $sVal
                        }
                    }
                }
                if ($diffs.Count -gt 0) {
                    $result.Different += [PSCustomObject]@{ Name = $key; Differences = $diffs }
                } else {
                    $result.Matching  += $key
                }
            }
        }
    }

    return $result
}

function ConvertDataTable-ToObjects {
    <#
    .SYNOPSIS Converts a DataTable to an array of PSCustomObjects for easier handling.
    #>
    param([System.Data.DataTable]$Table)
    if ($null -eq $Table -or $Table.Rows.Count -eq 0) { return @() }
    $cols = $Table.Columns | ForEach-Object { $_.ColumnName }
    return $Table.Rows | ForEach-Object {
        $row = $_
        $obj = [ordered]@{}
        foreach ($col in $cols) { $obj[$col] = $row[$col] }
        [PSCustomObject]$obj
    }
}

#endregion

# ─────────────────────────────────────────────────────────────────────────────
#region DATA COLLECTION FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

function Get-ServerConfigurations {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name,
    CAST(value_in_use AS NVARCHAR(50)) AS current_value,
    CAST(minimum     AS NVARCHAR(50)) AS minimum,
    CAST(maximum     AS NVARCHAR(50)) AS maximum,
    description
FROM sys.configurations
ORDER BY name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-ServerLogins {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    sp.name,
    sp.type_desc,
    CAST(sp.is_disabled           AS NVARCHAR(5))  AS is_disabled,
    sp.default_database_name,
    sp.default_language_name,
    ISNULL(CAST(sl.is_policy_checked    AS NVARCHAR(5)), 'N/A') AS is_policy_checked,
    ISNULL(CAST(sl.is_expiration_checked AS NVARCHAR(5)), 'N/A') AS is_expiration_checked,
    CAST(sp.create_date AS NVARCHAR(30)) AS create_date
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sp.principal_id = sl.principal_id
WHERE sp.type IN ('S','U','G','E','X')
  AND sp.name NOT LIKE '##%##'
  AND sp.name NOT IN ('sa','public')
ORDER BY sp.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-ServerRoleMembers {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    r.name AS RoleName,
    m.name AS MemberName,
    r.name + '|' + m.name AS RoleKey
FROM sys.server_role_members srm
JOIN sys.server_principals r ON srm.role_principal_id  = r.principal_id
JOIN sys.server_principals m ON srm.member_principal_id = m.principal_id
WHERE m.name NOT LIKE '##%##'
  AND m.name NOT IN ('sa')
ORDER BY r.name, m.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-ServerCredentials {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name,
    credential_identity,
    CAST(create_date  AS NVARCHAR(30)) AS create_date,
    CAST(modify_date  AS NVARCHAR(30)) AS modify_date
FROM sys.credentials
ORDER BY name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-LinkedServers {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    s.name,
    s.product,
    s.provider,
    ISNULL(s.data_source,'') AS data_source,
    CAST(s.is_rpc_out_enabled    AS NVARCHAR(5)) AS is_rpc_out_enabled,
    CAST(s.is_data_access_enabled AS NVARCHAR(5)) AS is_data_access_enabled
FROM sys.servers s
WHERE s.is_linked = 1
ORDER BY s.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-TDECertificates {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name,
    CAST(certificate_id AS NVARCHAR(20)) AS certificate_id,
    ISNULL(subject,'')                   AS subject,
    CAST(start_date  AS NVARCHAR(30))    AS start_date,
    CAST(expiry_date AS NVARCHAR(30))    AS expiry_date,
    pvt_key_encryption_type_desc
FROM sys.certificates
WHERE name NOT LIKE '##%'
ORDER BY name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-Databases {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name,
    state_desc,
    recovery_model_desc,
    CAST(compatibility_level AS NVARCHAR(10)) AS compatibility_level,
    collation_name,
    CAST(is_read_only           AS NVARCHAR(5)) AS is_read_only,
    CAST(is_auto_close_on       AS NVARCHAR(5)) AS is_auto_close_on,
    CAST(is_auto_shrink_on      AS NVARCHAR(5)) AS is_auto_shrink_on,
    CAST(is_auto_create_stats_on AS NVARCHAR(5)) AS is_auto_create_stats_on,
    CAST(is_auto_update_stats_on AS NVARCHAR(5)) AS is_auto_update_stats_on,
    CAST(is_encrypted            AS NVARCHAR(5)) AS is_encrypted,
    CAST(is_trustworthy_on       AS NVARCHAR(5)) AS is_trustworthy_on,
    page_verify_option_desc,
    containment_desc
FROM sys.databases
WHERE name NOT IN ('master','model','msdb','tempdb')
  AND state_desc = 'ONLINE'
ORDER BY name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-AgentJobs {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    j.name,
    CAST(j.enabled AS NVARCHAR(5))  AS enabled,
    ISNULL(j.description,'')         AS description,
    CAST(j.start_step_id AS NVARCHAR(10)) AS start_step_id,
    ISNULL(c.name,'Uncategorized')   AS category_name,
    CAST(j.notify_level_eventlog AS NVARCHAR(5))  AS notify_level_eventlog,
    CAST(j.notify_level_email    AS NVARCHAR(5))  AS notify_level_email,
    CAST(j.delete_level          AS NVARCHAR(5))  AS delete_level
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON j.category_id = c.category_id
ORDER BY j.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-AgentJobSteps {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    j.name                                    AS job_name,
    CAST(s.step_id AS NVARCHAR(10))           AS step_id,
    s.step_name,
    s.subsystem,
    CAST(s.on_success_action AS NVARCHAR(5))  AS on_success_action,
    CAST(s.on_fail_action    AS NVARCHAR(5))  AS on_fail_action,
    ISNULL(s.database_name,'')               AS database_name,
    j.name + '|' + CAST(s.step_id AS NVARCHAR(10)) + '|' + s.step_name AS StepKey
FROM msdb.dbo.sysjobsteps s
JOIN msdb.dbo.sysjobs j ON s.job_id = j.job_id
ORDER BY j.name, s.step_id
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-AgentSchedules {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    j.name                                         AS job_name,
    sc.name                                        AS schedule_name,
    CAST(sc.enabled           AS NVARCHAR(5))     AS enabled,
    CAST(sc.freq_type         AS NVARCHAR(10))    AS freq_type,
    CAST(sc.freq_interval     AS NVARCHAR(10))    AS freq_interval,
    CAST(sc.freq_subday_type  AS NVARCHAR(10))    AS freq_subday_type,
    CAST(sc.freq_subday_interval AS NVARCHAR(10)) AS freq_subday_interval,
    CAST(sc.active_start_time AS NVARCHAR(10))    AS active_start_time,
    CAST(sc.active_end_time   AS NVARCHAR(10))    AS active_end_time,
    j.name + '|' + sc.name AS ScheduleKey
FROM msdb.dbo.sysjobschedules js
JOIN msdb.dbo.sysjobs      j  ON js.job_id      = j.job_id
JOIN msdb.dbo.sysschedules sc ON js.schedule_id = sc.schedule_id
ORDER BY j.name, sc.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-AgentOperators {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name,
    CAST(enabled AS NVARCHAR(5)) AS enabled,
    ISNULL(email_address,'')      AS email_address,
    CAST(weekday_pager_start_time AS NVARCHAR(10)) AS pager_start,
    CAST(weekday_pager_end_time   AS NVARCHAR(10)) AS pager_end
FROM msdb.dbo.sysoperators
ORDER BY name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-AgentAlerts {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    a.name,
    CAST(a.enabled   AS NVARCHAR(5))  AS enabled,
    CAST(a.message_id AS NVARCHAR(10)) AS message_id,
    CAST(a.severity   AS NVARCHAR(5))  AS severity,
    ISNULL(a.database_name,'')         AS database_name,
    ISNULL(o.name,'')                  AS operator_name
FROM msdb.dbo.sysalerts a
LEFT JOIN msdb.dbo.sysoperators o ON a.operator_id = o.id
ORDER BY a.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-DatabaseUsers {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$DBName)
    $q = @"
SELECT
    dp.name,
    dp.type_desc,
    ISNULL(dp.default_schema_name,'dbo') AS default_schema_name,
    ISNULL(sp.name,'')                   AS login_name
FROM [$DBName].sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S','U','G','E','X')
  AND dp.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys','public')
  AND dp.name NOT LIKE '##%'
ORDER BY dp.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-DatabaseRoleMembers {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$DBName)
    $q = @"
SELECT
    r.name AS RoleName,
    m.name AS MemberName,
    r.name + '|' + m.name AS RoleKey
FROM [$DBName].sys.database_role_members drm
JOIN [$DBName].sys.database_principals r ON drm.role_principal_id  = r.principal_id
JOIN [$DBName].sys.database_principals m ON drm.member_principal_id = m.principal_id
WHERE m.name NOT IN ('dbo','guest')
  AND m.name NOT LIKE '##%'
ORDER BY r.name, m.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-DatabaseSchemas {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$DBName)
    $q = @"
SELECT
    s.name  AS SchemaName,
    dp.name AS OwnerName
FROM [$DBName].sys.schemas s
JOIN [$DBName].sys.database_principals dp ON s.principal_id = dp.principal_id
WHERE s.name NOT IN (
    'dbo','guest','INFORMATION_SCHEMA','sys',
    'db_owner','db_accessadmin','db_securityadmin','db_ddladmin',
    'db_backupoperator','db_datareader','db_datawriter',
    'db_denydatareader','db_denydatawriter')
ORDER BY s.name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-DatabaseObjectCounts {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$DBName)
    $q = @"
SELECT
    type_desc AS ObjectType,
    CAST(COUNT(*) AS NVARCHAR(20)) AS ObjectCount
FROM [$DBName].sys.objects
WHERE is_ms_shipped = 0
GROUP BY type_desc
ORDER BY type_desc
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

function Get-DatabasePermissions {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$DBName)
    $q = @"
SELECT
    dp.permission_name,
    dp.state_desc,
    pr.name AS principal_name,
    pr.type_desc AS principal_type,
    ISNULL(obj.name,'(database-level)') AS object_name,
    dp.permission_name + '|' + pr.name + '|' + ISNULL(obj.name,'') AS PermKey
FROM [$DBName].sys.database_permissions dp
JOIN [$DBName].sys.database_principals pr ON dp.grantee_principal_id = pr.principal_id
LEFT JOIN [$DBName].sys.objects obj ON dp.major_id = obj.object_id
WHERE pr.name NOT IN ('dbo','guest','public','INFORMATION_SCHEMA','sys')
  AND pr.name NOT LIKE 'db_%'
  AND pr.name NOT LIKE '##%'
ORDER BY pr.name, dp.permission_name
"@
    return ConvertDataTable-ToObjects (Invoke-SQLQuery -Connection $Conn -Query $q)
}

#endregion

# ─────────────────────────────────────────────────────────────────────────────
#region HTML REPORT BUILDER
# ─────────────────────────────────────────────────────────────────────────────

function Get-ReportCSS {
    return @'
<style>
:root {
  --blue:#0078d4; --blue-dk:#005a9e; --green:#107c10; --red:#d13438;
  --orange:#d83b01; --yellow-bg:#fff4ce; --red-bg:#fde7e9;
  --green-bg:#dff6dd; --orange-bg:#fff0e6; --grey:#605e5c;
  --border:#edebe9; --card:#ffffff; --page:#f3f2f1;
}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:var(--page);color:#201f1e;font-size:13px}
a{color:var(--blue);text-decoration:none}

/* ── Header ── */
.hdr{background:linear-gradient(135deg,#0078d4,#005a9e);color:#fff;padding:28px 40px}
.hdr h1{font-size:26px;font-weight:300;letter-spacing:-0.5px}
.hdr h1 b{font-weight:700}
.hdr .meta{margin-top:6px;font-size:12px;opacity:.85}

/* ── MI Cards ── */
.mi-row{display:flex;gap:16px;padding:20px 40px 0;flex-wrap:wrap}
.mi-card{flex:1;min-width:240px;background:var(--card);border-radius:8px;
  padding:14px 18px;box-shadow:0 1px 4px rgba(0,0,0,.1)}
.mi-card.primary  {border-left:5px solid #0078d4}
.mi-card.secondary{border-left:5px solid #00b294}
.mi-card .lbl{font-size:10px;text-transform:uppercase;letter-spacing:1px;color:var(--grey);margin-bottom:4px}
.mi-card .val{font-size:15px;font-weight:600;color:var(--blue)}

/* ── Summary tiles ── */
.tiles{display:flex;gap:14px;padding:20px 40px;flex-wrap:wrap}
.tile{flex:1;min-width:130px;background:var(--card);border-radius:8px;
  padding:18px;text-align:center;box-shadow:0 1px 4px rgba(0,0,0,.1);border-top:4px solid var(--blue)}
.tile.t-red   {border-top-color:var(--red)}
.tile.t-green {border-top-color:var(--green)}
.tile.t-orange{border-top-color:var(--orange)}
.tile .num{font-size:34px;font-weight:700;color:var(--blue);line-height:1}
.tile.t-red    .num{color:var(--red)}
.tile.t-green  .num{color:var(--green)}
.tile.t-orange .num{color:var(--orange)}
.tile .lbl{font-size:11px;color:var(--grey);margin-top:5px}

/* ── Content ── */
.content{padding:0 40px 40px}

/* ── Legend ── */
.legend{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:18px;font-size:11px}
.leg{display:flex;align-items:center;gap:5px}
.dot{width:12px;height:12px;border-radius:2px}
.d-miss  {background:var(--red-bg);   border:1px solid var(--red)}
.d-extra {background:var(--green-bg); border:1px solid var(--green)}
.d-diff  {background:var(--yellow-bg);border:1px solid #c0a000}
.d-ok    {background:var(--green-bg); border:1px solid var(--green)}

/* ── Sections ── */
.sec{background:var(--card);border-radius:8px;margin-bottom:12px;
  box-shadow:0 1px 4px rgba(0,0,0,.1);overflow:hidden}
.sec-hdr{display:flex;align-items:center;padding:14px 18px;cursor:pointer;
  user-select:none;border-bottom:1px solid var(--border);transition:background .12s}
.sec-hdr:hover{background:#faf9f8}
.sec-title{font-weight:600;font-size:14px;flex:1}
.sec-badges{margin-right:10px}
.chevron{font-size:11px;color:var(--grey);transition:transform .2s}
.chevron.open{transform:rotate(180deg)}
.sec-body{padding:18px;display:none}
.sec-body.active{display:block}

/* ── Badges ── */
.badge{display:inline-block;padding:2px 9px;border-radius:10px;font-size:10px;
  font-weight:700;margin-right:3px;letter-spacing:.3px}
.b-miss {background:var(--red-bg);   color:var(--red)}
.b-extra{background:var(--green-bg); color:var(--green)}
.b-diff {background:var(--yellow-bg);color:#7a5c00}
.b-ok   {background:var(--green-bg); color:var(--green)}

/* ── Tables ── */
table{width:100%;border-collapse:collapse;margin-top:6px;font-size:12px}
th{background:#f4f4f4;padding:8px 10px;text-align:left;font-weight:600;
  border:1px solid #ddd;font-size:11px;text-transform:uppercase;letter-spacing:.4px}
td{padding:7px 10px;border:1px solid #eee;vertical-align:top;word-break:break-word}
tr:nth-child(even) td{background:#fafafa}
.r-miss td{background:var(--red-bg)   !important;border-color:#f1a6a9}
.r-extra td{background:var(--green-bg)!important;border-color:#9fd89f}
.r-diff td{background:var(--yellow-bg)!important;border-color:#e0c060}

/* ── Sub-headers ── */
.sh{margin:14px 0 6px;font-size:12px;font-weight:700;padding:4px 8px;border-radius:3px}
.sh-miss {color:var(--red);   background:var(--red-bg)}
.sh-extra{color:var(--green); background:var(--green-bg)}
.sh-diff {color:#7a5c00;      background:var(--yellow-bg)}
.sh-info {color:var(--grey);  background:#f4f4f4}

/* ── DB detail block ── */
.db-block{border:1px solid var(--border);border-radius:6px;margin-bottom:14px;overflow:hidden}
.db-block-hdr{background:#f0f0f0;padding:10px 14px;font-weight:600;font-size:12px;
  display:flex;align-items:center;gap:8px}
.db-block-body{padding:16px}

.ok-msg{color:var(--green);font-weight:600;padding:8px 10px;
  background:var(--green-bg);border-radius:4px;font-size:12px}
.no-data{color:var(--grey);font-style:italic;padding:6px}

.footer{text-align:center;padding:18px;color:var(--grey);font-size:11px}
</style>
'@
}

function New-ComparisonTable {
    param(
        [string]$PrimaryName,
        [string]$SecondaryName,
        [object[]]$OnlyInPrimary,
        [object[]]$OnlyInSecondary,
        [object[]]$Different,
        [string[]]$Columns,
        [string]$KeyColumn
    )
    $html = ""

    if ($OnlyInPrimary -and $OnlyInPrimary.Count -gt 0) {
        $html += "<div class='sh sh-miss'>⚠ Missing in Secondary [$SecondaryName] — $($OnlyInPrimary.Count) item(s)</div>"
        $html += "<table><thead><tr>"
        foreach ($c in $Columns) { $html += "<th>$c</th>" }
        $html += "</tr></thead><tbody>"
        foreach ($row in $OnlyInPrimary) {
            $html += "<tr class='r-miss'>"
            foreach ($c in $Columns) { $html += "<td>$([System.Web.HttpUtility]::HtmlEncode($row.$c))</td>" }
            $html += "</tr>"
        }
        $html += "</tbody></table>"
    }

    if ($OnlyInSecondary -and $OnlyInSecondary.Count -gt 0) {
        $html += "<div class='sh sh-extra'>➕ Only in Secondary [$SecondaryName] — $($OnlyInSecondary.Count) item(s)</div>"
        $html += "<table><thead><tr>"
        foreach ($c in $Columns) { $html += "<th>$c</th>" }
        $html += "</tr></thead><tbody>"
        foreach ($row in $OnlyInSecondary) {
            $html += "<tr class='r-extra'>"
            foreach ($c in $Columns) { $html += "<td>$([System.Web.HttpUtility]::HtmlEncode($row.$c))</td>" }
            $html += "</tr>"
        }
        $html += "</tbody></table>"
    }

    if ($Different -and $Different.Count -gt 0) {
        $html += "<div class='sh sh-diff'>⚡ Value Differences — $($Different.Count) item(s)</div>"
        $html += "<table><thead><tr><th>Name</th><th>Property</th><th>Primary Value</th><th>Secondary Value</th></tr></thead><tbody>"
        foreach ($item in $Different) {
            foreach ($diff in $item.Differences) {
                $html += "<tr class='r-diff'>"
                $html += "<td>$([System.Web.HttpUtility]::HtmlEncode($item.Name))</td>"
                $html += "<td>$([System.Web.HttpUtility]::HtmlEncode($diff.Property))</td>"
                $html += "<td>$([System.Web.HttpUtility]::HtmlEncode($diff.PrimaryValue))</td>"
                $html += "<td>$([System.Web.HttpUtility]::HtmlEncode($diff.SecondaryValue))</td>"
                $html += "</tr>"
            }
        }
        $html += "</tbody></table>"
    }

    if (-not $html) {
        $html = "<div class='ok-msg'>✔ All objects match.</div>"
    }

    return $html
}

function New-Section {
    param(
        [string]$Title,
        [string]$Id,
        [string]$Content,
        [int]$Missing = 0,
        [int]$Extra   = 0,
        [int]$Diff    = 0
    )
    $badges = ""
    if ($Missing -gt 0) { $badges += "<span class='badge b-miss'>$Missing Missing</span>" }
    if ($Extra   -gt 0) { $badges += "<span class='badge b-extra'>$Extra Extra</span>" }
    if ($Diff    -gt 0) { $badges += "<span class='badge b-diff'>$Diff Diff</span>" }
    if (-not $badges)   { $badges  = "<span class='badge b-ok'>✔ Matched</span>" }

    return @"
<div class="sec">
  <div class="sec-hdr" onclick="toggle('$Id')">
    <span class="sec-title">$Title</span>
    <span class="sec-badges">$badges</span>
    <span class="chevron" id="chv-$Id">▼</span>
  </div>
  <div class="sec-body" id="$Id">$Content</div>
</div>
"@
}

#endregion

# ─────────────────────────────────────────────────────────────────────────────
#region MAIN EXECUTION
# ─────────────────────────────────────────────────────────────────────────────

Write-Log "═══════════════════════════════════════════════════════" "HEADER"
Write-Log "  Azure MI Comparison Tool" "HEADER"
Write-Log "  Primary   : $PrimaryMI" "HEADER"
Write-Log "  Secondary : $SecondaryMI" "HEADER"
Write-Log "═══════════════════════════════════════════════════════" "HEADER"

# ── Load config ───────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigFilePath)) {
    Write-Log "Config file not found: '$ConfigFilePath'" "ERROR"
    exit 1
}
$script:Config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json
Write-Log "Config loaded from: $ConfigFilePath"

# ── Resolve credentials ───────────────────────────────────────────────────────
$priCreds = Get-MICredentials -Config $script:Config -ServerName $PrimaryMI
$secCreds = Get-MICredentials -Config $script:Config -ServerName $SecondaryMI

# ── Get AAD tokens ────────────────────────────────────────────────────────────
Write-Log "Acquiring Azure AD tokens..."
$priToken = Get-AccessToken -TenantId $script:Config.TenantId `
    -ClientId $priCreds.ServicePrincipalId -ClientSecret $priCreds.ServicePrincipalSecret
$secToken = Get-AccessToken -TenantId $script:Config.TenantId `
    -ClientId $secCreds.ServicePrincipalId -ClientSecret $secCreds.ServicePrincipalSecret

# ── Open connections ──────────────────────────────────────────────────────────
Write-Log "Opening SQL connections..."
$priConn = New-SQLConnection -ServerName $PrimaryMI   -AccessToken $priToken   -ConnectPort $Port
$secConn = New-SQLConnection -ServerName $SecondaryMI -AccessToken $secToken   -ConnectPort $Port

# Add System.Web for HtmlEncode
Add-Type -AssemblyName System.Web

# ── Collect server-level data ─────────────────────────────────────────────────
Write-Log "Collecting: Server Configurations..."
$priSrvCfg  = Get-ServerConfigurations  -Conn $priConn
$secSrvCfg  = Get-ServerConfigurations  -Conn $secConn

Write-Log "Collecting: Logins..."
$priLogins  = Get-ServerLogins          -Conn $priConn
$secLogins  = Get-ServerLogins          -Conn $secConn

Write-Log "Collecting: Server Role Members..."
$priSrvRoles= Get-ServerRoleMembers     -Conn $priConn
$secSrvRoles= Get-ServerRoleMembers     -Conn $secConn

Write-Log "Collecting: Credentials..."
$priSrvCreds= Get-ServerCredentials     -Conn $priConn
$secSrvCreds= Get-ServerCredentials     -Conn $secConn

Write-Log "Collecting: Linked Servers..."
$priLinked  = Get-LinkedServers         -Conn $priConn
$secLinked  = Get-LinkedServers         -Conn $secConn

Write-Log "Collecting: Certificates..."
$priCerts   = Get-TDECertificates       -Conn $priConn
$secCerts   = Get-TDECertificates       -Conn $secConn

Write-Log "Collecting: Databases..."
$priDBs     = Get-Databases             -Conn $priConn
$secDBs     = Get-Databases             -Conn $secConn

Write-Log "Collecting: Agent Jobs..."
$priJobs    = Get-AgentJobs             -Conn $priConn
$secJobs    = Get-AgentJobs             -Conn $secConn

Write-Log "Collecting: Agent Job Steps..."
$priSteps   = Get-AgentJobSteps         -Conn $priConn
$secSteps   = Get-AgentJobSteps         -Conn $secConn

Write-Log "Collecting: Agent Schedules..."
$priScheds  = Get-AgentSchedules        -Conn $priConn
$secScheds  = Get-AgentSchedules        -Conn $secConn

Write-Log "Collecting: Agent Operators..."
$priOps     = Get-AgentOperators        -Conn $priConn
$secOps     = Get-AgentOperators        -Conn $secConn

Write-Log "Collecting: Agent Alerts..."
$priAlerts  = Get-AgentAlerts           -Conn $priConn
$secAlerts  = Get-AgentAlerts           -Conn $secConn

# ── Compare server-level objects ──────────────────────────────────────────────
Write-Log "Running server-level comparisons..."

$cmpCfg   = Compare-ObjectLists $priSrvCfg   $secSrvCfg   "name"      @("current_value")
$cmpLogin = Compare-ObjectLists $priLogins   $secLogins   "name"      @("type_desc","is_disabled","default_database_name")
$cmpRole  = Compare-ObjectLists $priSrvRoles $secSrvRoles "RoleKey"   @()
$cmpCred  = Compare-ObjectLists $priSrvCreds $secSrvCreds "name"      @("credential_identity")
$cmpLink  = Compare-ObjectLists $priLinked   $secLinked   "name"      @("product","provider","data_source")
$cmpCert  = Compare-ObjectLists $priCerts    $secCerts    "name"      @("subject","expiry_date")
$cmpDB    = Compare-ObjectLists $priDBs      $secDBs      "name"      @("recovery_model_desc","compatibility_level","collation_name","is_encrypted","page_verify_option_desc")
$cmpJob   = Compare-ObjectLists $priJobs     $secJobs     "name"      @("enabled","category_name")
$cmpStep  = Compare-ObjectLists $priSteps    $secSteps    "StepKey"   @("subsystem","database_name")
$cmpSched = Compare-ObjectLists $priScheds   $secScheds   "ScheduleKey" @("enabled","freq_type","freq_interval","active_start_time")
$cmpOp    = Compare-ObjectLists $priOps      $secOps      "name"      @("enabled","email_address")
$cmpAlert = Compare-ObjectLists $priAlerts   $secAlerts   "name"      @("enabled","severity","database_name")

# ── Per-database comparisons ──────────────────────────────────────────────────
Write-Log "Starting per-database comparisons..."
$priDBNames = $priDBs | ForEach-Object { $_.name }
$secDBNames = $secDBs | ForEach-Object { $_.name }
$commonDBs  = $priDBNames | Where-Object { $_ -in $secDBNames }

$dbDetailHtml  = ""
$dbTotalMiss   = 0
$dbTotalExtra  = 0
$dbTotalDiff   = 0

foreach ($dbName in ($commonDBs | Sort-Object)) {
    Write-Log "  → Database: $dbName"

    $priDBUsers  = Get-DatabaseUsers       -Conn $priConn -DBName $dbName
    $secDBUsers  = Get-DatabaseUsers       -Conn $secConn -DBName $dbName
    $priDBRoles  = Get-DatabaseRoleMembers -Conn $priConn -DBName $dbName
    $secDBRoles  = Get-DatabaseRoleMembers -Conn $secConn -DBName $dbName
    $priDBSchema = Get-DatabaseSchemas     -Conn $priConn -DBName $dbName
    $secDBSchema = Get-DatabaseSchemas     -Conn $secConn -DBName $dbName
    $priDBPerms  = Get-DatabasePermissions -Conn $priConn -DBName $dbName
    $secDBPerms  = Get-DatabasePermissions -Conn $secConn -DBName $dbName
    $priObjCnt   = Get-DatabaseObjectCounts -Conn $priConn -DBName $dbName
    $secObjCnt   = Get-DatabaseObjectCounts -Conn $secConn -DBName $dbName

    $cmpDBUser   = Compare-ObjectLists $priDBUsers  $secDBUsers  "name"       @("type_desc","login_name")
    $cmpDBRole   = Compare-ObjectLists $priDBRoles  $secDBRoles  "RoleKey"    @()
    $cmpDBSchema = Compare-ObjectLists $priDBSchema $secDBSchema "SchemaName" @("OwnerName")
    $cmpDBPerm   = Compare-ObjectLists $priDBPerms  $secDBPerms  "PermKey"    @("state_desc")
    $cmpObjCnt   = Compare-ObjectLists $priObjCnt   $secObjCnt   "ObjectType" @("ObjectCount")

    $dbMiss  = $cmpDBUser.OnlyInPrimary.Count + $cmpDBRole.OnlyInPrimary.Count   + $cmpDBSchema.OnlyInPrimary.Count   + $cmpDBPerm.OnlyInPrimary.Count
    $dbExtra = $cmpDBUser.OnlyInSecondary.Count + $cmpDBRole.OnlyInSecondary.Count + $cmpDBSchema.OnlyInSecondary.Count + $cmpDBPerm.OnlyInSecondary.Count
    $dbDiff  = $cmpDBUser.Different.Count + $cmpObjCnt.Different.Count + $cmpDBPerm.Different.Count

    $dbTotalMiss  += $dbMiss
    $dbTotalExtra += $dbExtra
    $dbTotalDiff  += $dbDiff

    $dbBadgeHtml = ""
    if ($dbMiss  -gt 0) { $dbBadgeHtml += "<span class='badge b-miss'>$dbMiss Missing</span>" }
    if ($dbExtra -gt 0) { $dbBadgeHtml += "<span class='badge b-extra'>$dbExtra Extra</span>" }
    if ($dbDiff  -gt 0) { $dbBadgeHtml += "<span class='badge b-diff'>$dbDiff Diff</span>" }
    if (-not $dbBadgeHtml) { $dbBadgeHtml = "<span class='badge b-ok'>✔ Matched</span>" }

    $dbBodyHtml  = ""
    $dbBodyHtml += "<div class='sh sh-info'>👥 Database Users</div>"
    $dbBodyHtml += New-ComparisonTable $PrimaryMI $SecondaryMI $cmpDBUser.OnlyInPrimary $cmpDBUser.OnlyInSecondary $cmpDBUser.Different @("name","type_desc","login_name","default_schema_name") "name"

    $dbBodyHtml += "<div class='sh sh-info'>🛡 Database Role Memberships</div>"
    $dbBodyHtml += New-ComparisonTable $PrimaryMI $SecondaryMI $cmpDBRole.OnlyInPrimary $cmpDBRole.OnlyInSecondary @() @("RoleName","MemberName") "RoleKey"

    $dbBodyHtml += "<div class='sh sh-info'>📂 Schemas</div>"
    $dbBodyHtml += New-ComparisonTable $PrimaryMI $SecondaryMI $cmpDBSchema.OnlyInPrimary $cmpDBSchema.OnlyInSecondary $cmpDBSchema.Different @("SchemaName","OwnerName") "SchemaName"

    $dbBodyHtml += "<div class='sh sh-info'>🔐 Database Permissions</div>"
    $dbBodyHtml += New-ComparisonTable $PrimaryMI $SecondaryMI $cmpDBPerm.OnlyInPrimary $cmpDBPerm.OnlyInSecondary $cmpDBPerm.Different @("principal_name","permission_name","state_desc","object_name") "PermKey"

    $dbBodyHtml += "<div class='sh sh-info'>📊 Object Count Comparison</div>"
    $dbBodyHtml += New-ComparisonTable $PrimaryMI $SecondaryMI $cmpObjCnt.OnlyInPrimary $cmpObjCnt.OnlyInSecondary $cmpObjCnt.Different @("ObjectType","ObjectCount") "ObjectType"

    $dbDetailHtml += @"
<div class="db-block">
  <div class="db-block-hdr">🗄 $dbName &nbsp;&nbsp;$dbBadgeHtml</div>
  <div class="db-block-body">$dbBodyHtml</div>
</div>
"@
}

# ── Compute totals for summary tiles ─────────────────────────────────────────
$totalMissing = $cmpLogin.OnlyInPrimary.Count + $cmpCred.OnlyInPrimary.Count +
                $cmpJob.OnlyInPrimary.Count   + $cmpDB.OnlyInPrimary.Count   +
                $cmpCert.OnlyInPrimary.Count  + $cmpRole.OnlyInPrimary.Count +
                $cmpLink.OnlyInPrimary.Count  + $cmpOp.OnlyInPrimary.Count   +
                $cmpAlert.OnlyInPrimary.Count + $cmpStep.OnlyInPrimary.Count +
                $cmpSched.OnlyInPrimary.Count + $dbTotalMiss

$totalExtra   = $cmpLogin.OnlyInSecondary.Count + $cmpCred.OnlyInSecondary.Count +
                $cmpJob.OnlyInSecondary.Count   + $cmpDB.OnlyInSecondary.Count   +
                $cmpCert.OnlyInSecondary.Count  + $cmpRole.OnlyInSecondary.Count +
                $cmpLink.OnlyInSecondary.Count  + $cmpOp.OnlyInSecondary.Count   +
                $cmpAlert.OnlyInSecondary.Count + $cmpStep.OnlyInSecondary.Count +
                $cmpSched.OnlyInSecondary.Count + $dbTotalExtra

$totalDiff    = $cmpCfg.Different.Count + $cmpLogin.Different.Count +
                $cmpDB.Different.Count  + $cmpJob.Different.Count   +
                $cmpSched.Different.Count + $cmpStep.Different.Count + $dbTotalDiff

$reportTime   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# ─────────────────────────────────────────────────────────────────────────────
#region BUILD HTML REPORT
# ─────────────────────────────────────────────────────────────────────────────

Write-Log "Building HTML report..."

$reportHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Azure MI Comparison — $PrimaryMI vs $SecondaryMI</title>
$(Get-ReportCSS)
</head>
<body>

<div class="hdr">
  <h1>Azure Managed Instance <b>Comparison Report</b></h1>
  <div class="meta">
    🕐 Generated: $reportTime &nbsp;|&nbsp;
    📌 Primary: <b>$PrimaryMI</b> &nbsp;|&nbsp;
    📌 Secondary: <b>$SecondaryMI</b>
  </div>
</div>

<div class="mi-row">
  <div class="mi-card primary">
    <div class="lbl">Primary Managed Instance</div>
    <div class="val">$PrimaryMI</div>
    <div style="font-size:11px;color:#605e5c;margin-top:3px">SPN: $($priCreds.ServicePrincipalName)</div>
  </div>
  <div class="mi-card secondary">
    <div class="lbl">Secondary Managed Instance</div>
    <div class="val">$SecondaryMI</div>
    <div style="font-size:11px;color:#605e5c;margin-top:3px">SPN: $($secCreds.ServicePrincipalName)</div>
  </div>
</div>

<div class="tiles">
  <div class="tile t-red">
    <div class="num">$totalMissing</div>
    <div class="lbl">Missing in Secondary</div>
  </div>
  <div class="tile t-green">
    <div class="num">$totalExtra</div>
    <div class="lbl">Only in Secondary</div>
  </div>
  <div class="tile t-orange">
    <div class="num">$totalDiff</div>
    <div class="lbl">Configuration Diffs</div>
  </div>
  <div class="tile">
    <div class="num">$($priDBs.Count)</div>
    <div class="lbl">Primary Databases</div>
  </div>
  <div class="tile">
    <div class="num">$($secDBs.Count)</div>
    <div class="lbl">Secondary Databases</div>
  </div>
  <div class="tile">
    <div class="num">$($priJobs.Count)</div>
    <div class="lbl">Primary Agent Jobs</div>
  </div>
  <div class="tile">
    <div class="num">$($priLogins.Count)</div>
    <div class="lbl">Primary Logins</div>
  </div>
</div>

<div class="content">

<div class="legend">
  <span class="leg"><div class="dot d-miss"></div> Missing in Secondary</span>
  <span class="leg"><div class="dot d-extra"></div> Only in Secondary</span>
  <span class="leg"><div class="dot d-diff"></div> Value Difference</span>
  <span class="leg"><div class="dot d-ok"></div> All Matched</span>
</div>

"@

# ── Section: Server Config ────────────────────────────────────────────────────
$cfgContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpCfg.OnlyInPrimary $cmpCfg.OnlyInSecondary $cmpCfg.Different `
    @("name","current_value","description") "name"
$reportHtml += New-Section "⚙ Server Configurations (sp_configure)" "s-cfg" $cfgContent `
    $cmpCfg.OnlyInPrimary.Count $cmpCfg.OnlyInSecondary.Count $cmpCfg.Different.Count

# ── Section: Logins ───────────────────────────────────────────────────────────
$loginContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpLogin.OnlyInPrimary $cmpLogin.OnlyInSecondary $cmpLogin.Different `
    @("name","type_desc","is_disabled","default_database_name","create_date") "name"
$reportHtml += New-Section "👤 Server Logins" "s-logins" $loginContent `
    $cmpLogin.OnlyInPrimary.Count $cmpLogin.OnlyInSecondary.Count $cmpLogin.Different.Count

# ── Section: Server Roles ─────────────────────────────────────────────────────
$roleContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpRole.OnlyInPrimary $cmpRole.OnlyInSecondary @() `
    @("RoleName","MemberName") "RoleKey"
$reportHtml += New-Section "🛡 Server Role Memberships" "s-roles" $roleContent `
    $cmpRole.OnlyInPrimary.Count $cmpRole.OnlyInSecondary.Count 0

# ── Section: Credentials ──────────────────────────────────────────────────────
$credContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpCred.OnlyInPrimary $cmpCred.OnlyInSecondary $cmpCred.Different `
    @("name","credential_identity","create_date","modify_date") "name"
$reportHtml += New-Section "🔑 Server Credentials" "s-creds" $credContent `
    $cmpCred.OnlyInPrimary.Count $cmpCred.OnlyInSecondary.Count $cmpCred.Different.Count

# ── Section: Linked Servers ───────────────────────────────────────────────────
$linkContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpLink.OnlyInPrimary $cmpLink.OnlyInSecondary @() `
    @("name","product","provider","data_source","is_rpc_out_enabled") "name"
$reportHtml += New-Section "🔗 Linked Servers" "s-linked" $linkContent `
    $cmpLink.OnlyInPrimary.Count $cmpLink.OnlyInSecondary.Count 0

# ── Section: Certificates ─────────────────────────────────────────────────────
$certContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpCert.OnlyInPrimary $cmpCert.OnlyInSecondary @() `
    @("name","subject","start_date","expiry_date","pvt_key_encryption_type_desc") "name"
$reportHtml += New-Section "📜 Certificates (TDE & Others)" "s-certs" $certContent `
    $cmpCert.OnlyInPrimary.Count $cmpCert.OnlyInSecondary.Count 0

# ── Section: Databases ────────────────────────────────────────────────────────
$dbListContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpDB.OnlyInPrimary $cmpDB.OnlyInSecondary $cmpDB.Different `
    @("name","state_desc","recovery_model_desc","compatibility_level","collation_name","is_encrypted","page_verify_option_desc") "name"
$reportHtml += New-Section "🗄 Databases & Properties" "s-dbs" $dbListContent `
    $cmpDB.OnlyInPrimary.Count $cmpDB.OnlyInSecondary.Count $cmpDB.Different.Count

# ── Section: Agent Jobs ───────────────────────────────────────────────────────
$jobContent  = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpJob.OnlyInPrimary  $cmpJob.OnlyInSecondary  $cmpJob.Different `
    @("name","enabled","category_name","description") "name"
$stepContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpStep.OnlyInPrimary $cmpStep.OnlyInSecondary $cmpStep.Different `
    @("job_name","step_id","step_name","subsystem","database_name") "StepKey"
$schedContent= New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpSched.OnlyInPrimary $cmpSched.OnlyInSecondary $cmpSched.Different `
    @("job_name","schedule_name","enabled","freq_type","freq_interval","active_start_time") "ScheduleKey"

$agentJobHtml = "<div class='sh sh-info'>Jobs</div>$jobContent" +
                "<div class='sh sh-info' style='margin-top:14px'>Job Steps</div>$stepContent" +
                "<div class='sh sh-info' style='margin-top:14px'>Schedules</div>$schedContent"

$agentJobMiss = $cmpJob.OnlyInPrimary.Count  + $cmpStep.OnlyInPrimary.Count  + $cmpSched.OnlyInPrimary.Count
$agentJobXtra = $cmpJob.OnlyInSecondary.Count + $cmpStep.OnlyInSecondary.Count + $cmpSched.OnlyInSecondary.Count
$agentJobDiff = $cmpJob.Different.Count + $cmpStep.Different.Count + $cmpSched.Different.Count
$reportHtml  += New-Section "⏰ SQL Agent — Jobs, Steps & Schedules" "s-agent" $agentJobHtml `
    $agentJobMiss $agentJobXtra $agentJobDiff

# ── Section: Operators & Alerts ───────────────────────────────────────────────
$opContent  = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpOp.OnlyInPrimary    $cmpOp.OnlyInSecondary    $cmpOp.Different `
    @("name","enabled","email_address") "name"
$altContent = New-ComparisonTable $PrimaryMI $SecondaryMI `
    $cmpAlert.OnlyInPrimary $cmpAlert.OnlyInSecondary @() `
    @("name","enabled","severity","database_name","operator_name") "name"

$opAltHtml  = "<div class='sh sh-info'>Operators</div>$opContent" +
              "<div class='sh sh-info' style='margin-top:14px'>Alerts</div>$altContent"
$opAltMiss  = $cmpOp.OnlyInPrimary.Count  + $cmpAlert.OnlyInPrimary.Count
$opAltExtra = $cmpOp.OnlyInSecondary.Count + $cmpAlert.OnlyInSecondary.Count
$reportHtml += New-Section "📣 Agent Operators & Alerts" "s-ops" $opAltHtml `
    $opAltMiss $opAltExtra ($cmpOp.Different.Count)

# ── Section: Per-Database Detail ──────────────────────────────────────────────
$reportHtml += New-Section "🔍 Per-Database Detail Comparison ($($commonDBs.Count) common databases)" `
    "s-dbdetail" $dbDetailHtml $dbTotalMiss $dbTotalExtra $dbTotalDiff

$reportHtml += @"
</div><!-- /content -->

<div class="footer">
  Azure MI Comparison Report &mdash; $reportTime &mdash;
  Primary: <b>$PrimaryMI</b> | Secondary: <b>$SecondaryMI</b>
</div>

<script>
function toggle(id) {
    var body = document.getElementById(id);
    var chv  = document.getElementById('chv-' + id);
    var open = body.classList.toggle('active');
    chv.textContent = open ? '▲' : '▼';
    if (open) chv.classList.add('open'); else chv.classList.remove('open');
}
// Auto-expand sections that have issues
document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('.b-miss,.b-diff,.b-extra').forEach(function (b) {
        var sec  = b.closest('.sec');
        if (!sec) return;
        var body = sec.querySelector('.sec-body');
        var chv  = sec.querySelector('.chevron');
        if (body && !body.classList.contains('active')) {
            body.classList.add('active');
            if (chv) { chv.textContent = '▲'; chv.classList.add('open'); }
        }
    });
});
</script>
</body>
</html>
"@

#endregion

# ── Close connections ─────────────────────────────────────────────────────────
try { $priConn.Close(); $priConn.Dispose() } catch {}
try { $secConn.Close(); $secConn.Dispose() } catch {}
Write-Log "SQL connections closed."

# ── Save report ───────────────────────────────────────────────────────────────
$reportHtml | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
Write-Log "═══════════════════════════════════════════════════════" "HEADER"
Write-Log "  Report saved : $OutputPath" "SUCCESS"
Write-Log "  Missing      : $totalMissing" "WARN"
Write-Log "  Extra        : $totalExtra" "WARN"
Write-Log "  Differences  : $totalDiff" "WARN"
Write-Log "═══════════════════════════════════════════════════════" "HEADER"

# Auto-open in browser on Windows
if ($env:OS -match 'Windows') {
    Start-Process $OutputPath
}
