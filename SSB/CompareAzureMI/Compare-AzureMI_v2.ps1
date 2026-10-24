
#Requires -Version 5.1

<#
.SYNOPSIS
    Azure SQL Managed Instance Comparison Tool

.DESCRIPTION
    Compares two Azure SQL Managed Instances (Primary and Secondary) across:
    instance properties, databases, logins, server configuration, linked servers,
    and SQL Agent jobs. Outputs a self-contained HTML audit report.

    FIXES APPLIED:
      FIX 1 — Pre-initializes all variables to prevent VariableIsUndefined errors
      FIX 2 — Deduplicates FQDN: detects when HostFqdn is already fully qualified
      FIX 3 — Null guards on server/credential config lookups before use
      FIX 4 — Connection failures are non-terminating (partial report on one failure)
      FIX 5 — No Set-StrictMode at script scope; all variables safely initialized

.PARAMETER PrimaryMI
    Short name of the primary Managed Instance
    Example: ssc-gts-pfi-sub-prd-02-use2-sql-mi-1001

.PARAMETER SecondaryMI
    Short name of the secondary Managed Instance
    Example: ssc-gts-pfi-sub-prd-02-cne-sql-mi-1001

.PARAMETER ConfigFilePath
    Full path to mi-config.json

.PARAMETER OutputPath
    Full path for the generated HTML audit report

.EXAMPLE
    .\Compare-AzureMI.ps1 `
        -PrimaryMI      "ssc-gts-pfi-sub-prd-02-use2-sql-mi-1001" `
        -SecondaryMI    "ssc-gts-pfi-sub-prd-02-cne-sql-mi-1001" `
        -ConfigFilePath "E:\DBA\MSSQL\SCRIPTS\mi-config.json" `
        -OutputPath     "E:\DBA\MSSQL\SCRIPTS\Reports\audit.html"

.NOTES
    mi-config.json expected structure:
    {
      "TenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "Servers": [
        {
          "Name": "ssc-gts-pfi-sub-prd-02-use2-sql-mi-1001",
          "HostFqdn": "ssc-gts-pfi-sub-prd-02-use2-sql-mi-1001.f5bb953edf71.database.windows.net",
          "CredentialName": "azspn-pfi-reportlogin-linnational-prod-01",
          "Port": 1433
        },
        {
          "Name": "ssc-gts-pfi-sub-prd-02-cne-sql-mi-1001",
          "HostFqdn": "ssc-gts-pfi-sub-prd-02-cne-sql-mi-1001.f5bb953edf71.database.windows.net",
          "CredentialName": "azspn-pfi-reportlogin-linnational-prod-01",
          "Port": 1433
        }
      ],
      "Credentials": [
        {
          "Name": "azspn-pfi-reportlogin-linnational-prod-01",
          "ClientId": "9b392a36-d847-40b6-9529-a6bf904ce543",
          "ClientSecret": "your-secret-here"
        }
      ]
    }
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PrimaryMI,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SecondaryMI,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFilePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

# ================================================================
# REGION: FIX 1 — Pre-initialize all variables (prevents VariableIsUndefined)
# ================================================================
Add-Type -AssemblyName 'System.Data' -ErrorAction SilentlyContinue

$jsonConfig          = $null   # Full parsed JSON config
$primarySrvConfig    = $null   # Server entry for primary from JSON
$secondarySrvConfig  = $null   # Server entry for secondary from JSON
$primaryCredConfig   = $null   # Credential entry for primary
$secondaryCredConfig = $null   # Credential entry for secondary
$primaryToken        = $null   # AAD access token for primary
$secondaryToken      = $null   # AAD access token for secondary
$primaryFqdn         = $null   # Resolved FQDN for primary
$secondaryFqdn       = $null   # Resolved FQDN for secondary
$primaryConn         = $null   # SqlConnection for primary
$secondaryConn       = $null   # SqlConnection for secondary
$primaryPort         = 1433
$secondaryPort       = 1433
$scriptErrors        = [System.Collections.Generic.List[string]]::new()
$scriptStartTime     = Get-Date

# ================================================================
# REGION: Logging Helpers
# ================================================================

function Write-Header {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [HEADER]  $Message" -ForegroundColor Magenta
}

function Write-Info {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [INFO]    $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [SUCCESS] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [WARN]    $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [ERROR]   $Message" -ForegroundColor Red
    $script:scriptErrors.Add($Message)
}

# ================================================================
# REGION: FIX 2 — FQDN Helper (prevents duplicate hostname in FQDN)
# ================================================================

function Get-MiFqdn {
    <#
    .SYNOPSIS
        Returns the correct fully-qualified domain name for a Managed Instance
        without duplicating the server name prefix.
    .DESCRIPTION
        Handles three scenarios:
          1. HostFqdn already starts with ServerName  -> return HostFqdn as-is
          2. HostFqdn is already a full FQDN          -> return HostFqdn as-is
          3. HostFqdn is only a DNS suffix            -> prepend ServerName
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$HostFqdn
    )

    # Case 1: HostFqdn already has the server name as the first segment
    if ($HostFqdn.ToLower() -like "$($ServerName.ToLower()).*") {
        Write-Info "FQDN is already fully qualified (Case 1): $HostFqdn"
        return $HostFqdn
    }

    # Case 2: HostFqdn is a multi-segment FQDN ending in database.windows.net
    if ($HostFqdn -match "^[^.]+\..+\.database\.windows\.net$") {
        Write-Info "FQDN appears fully qualified (Case 2): $HostFqdn"
        return $HostFqdn
    }

    # Case 3: HostFqdn is just a suffix — build the full FQDN
    $fullFqdn = "$ServerName.$HostFqdn"
    Write-Info "Constructed FQDN (Case 3): $fullFqdn"
    return $fullFqdn
}

# ================================================================
# REGION: Azure AD Token Acquisition
# ================================================================

function Get-AzureSqlToken {
    <#
    .SYNOPSIS
        Acquires an Azure AD OAuth2 token for Azure SQL Database/MI
        using Service Principal client credentials flow.
    #>
    param (
        [Parameter(Mandatory = $true)] [string]$TenantId,
        [Parameter(Mandatory = $true)] [string]$ClientId,
        [Parameter(Mandatory = $true)] [string]$ClientSecret
    )

    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/token"
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        resource      = "https://database.windows.net/"
    }

    try {
        $response = Invoke-RestMethod `
            -Uri         $tokenUrl `
            -Method      Post `
            -Body        $body `
            -ContentType "application/x-www-form-urlencoded" `
            -ErrorAction Stop
        return $response.access_token
    }
    catch {
        throw "Failed to acquire AAD token for ClientId '$ClientId': $_"
    }
}

# ================================================================
# REGION: FIX 3 & 4 — SQL Connection Helper (null-safe, non-terminating)
# ================================================================

function Open-MiConnection {
    <#
    .SYNOPSIS
        Opens a SqlConnection to an Azure SQL Managed Instance using an AAD token.
        Returns the open connection, or $null on failure (non-terminating).
    #>
    param (
        [Parameter(Mandatory = $true)] [string]$ServerName,
        [Parameter(Mandatory = $true)] [string]$Fqdn,
        [Parameter(Mandatory = $true)] [string]$AccessToken,
        [int]$Port    = 1433,
        [int]$Timeout = 30
    )

    $connStr = "Server=tcp:$Fqdn,$Port;" +
               "Initial Catalog=master;" +
               "Persist Security Info=False;" +
               "Encrypt=True;" +
               "TrustServerCertificate=False;" +
               "Connection Timeout=$Timeout;"

    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = $connStr
    $conn.AccessToken      = $AccessToken

    try {
        Write-Info "Connecting to: $Fqdn,$Port"
        $conn.Open()
        Write-Success "Connected to '$ServerName'"
        return $conn
    }
    catch {
        Write-Err "Connection failed to '${Fqdn}': $_"
        # FIX 4: Return $null instead of throwing — allows partial report generation
        return $null
    }
}

# ================================================================
# REGION: SQL Query Runner
# ================================================================

function Invoke-MiQuery {
    <#
    .SYNOPSIS
        Executes a T-SQL query on an open SqlConnection.
        Returns an array of PSCustomObjects, or empty array on failure.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection]$Connection,

        [Parameter(Mandatory = $true)]
        [string]$Query,

        [int]$CommandTimeout = 60
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $cmd                = $Connection.CreateCommand()
        $cmd.CommandText    = $Query
        $cmd.CommandTimeout = $CommandTimeout

        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $colName      = $reader.GetName($i)
                $row[$colName] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
            }
            $results.Add([PSCustomObject]$row)
        }
        $reader.Close()
    }
    catch {
        Write-Err "Query execution failed: $_"
    }

    return $results.ToArray()
}

# ================================================================
# REGION: Data Collection Functions
# ================================================================

function Get-InstanceProperties {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    CAST(SERVERPROPERTY('ServerName')         AS NVARCHAR(256)) AS ServerName,
    CAST(SERVERPROPERTY('Edition')            AS NVARCHAR(256)) AS Edition,
    CAST(SERVERPROPERTY('ProductVersion')     AS NVARCHAR(256)) AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel')       AS NVARCHAR(256)) AS ProductLevel,
    CAST(SERVERPROPERTY('ProductUpdateLevel') AS NVARCHAR(256)) AS ProductUpdateLevel,
    CAST(SERVERPROPERTY('Collation')          AS NVARCHAR(256)) AS Collation,
    CAST(SERVERPROPERTY('IsHadrEnabled')      AS INT)           AS IsHadrEnabled,
    CAST(SERVERPROPERTY('IsSingleUser')       AS INT)           AS IsSingleUser,
    CAST(SERVERPROPERTY('EngineEdition')      AS INT)           AS EngineEdition
"@
    return Invoke-MiQuery -Connection $Conn -Query $q
}

function Get-DatabaseList {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name                 AS DatabaseName,
    state_desc           AS State,
    recovery_model_desc  AS RecoveryModel,
    compatibility_level  AS CompatibilityLevel,
    collation_name       AS Collation,
    CAST(is_read_only    AS INT) AS IsReadOnly,
    CAST(is_auto_close_on AS INT) AS AutoClose,
    CAST(is_auto_shrink_on AS INT) AS AutoShrink,
    CONVERT(NVARCHAR(30), create_date, 120) AS CreateDate
FROM sys.databases
WHERE database_id > 4
ORDER BY name
"@
    return Invoke-MiQuery -Connection $Conn -Query $q
}

function Get-ServerLogins {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name                  AS LoginName,
    type_desc             AS LoginType,
    CAST(is_disabled AS INT) AS IsDisabled,
    CONVERT(NVARCHAR(30), create_date, 120) AS CreateDate,
    default_database_name AS DefaultDatabase
FROM sys.server_principals
WHERE type    IN ('S','U','G','E','X')
  AND name NOT LIKE '##%'
  AND name NOT IN ('sa','public')
ORDER BY name
"@
    return Invoke-MiQuery -Connection $Conn -Query $q
}

function Get-ServerConfiguration {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name          AS ConfigName,
    CAST(value         AS NVARCHAR(50)) AS ConfigValue,
    CAST(value_in_use  AS NVARCHAR(50)) AS ValueInUse,
    description   AS Description
FROM sys.configurations
ORDER BY name
"@
    return Invoke-MiQuery -Connection $Conn -Query $q
}

function Get-LinkedServers {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    name        AS LinkedServerName,
    product     AS Product,
    provider    AS Provider,
    data_source AS DataSource,
    CAST(is_linked AS INT) AS IsLinked
FROM sys.servers
WHERE is_linked = 1
ORDER BY name
"@
    return Invoke-MiQuery -Connection $Conn -Query $q
}

function Get-AgentJobs {
    param([System.Data.SqlClient.SqlConnection]$Conn)
    $q = @"
SELECT
    j.name        AS JobName,
    CAST(j.enabled AS INT) AS IsEnabled,
    j.description AS Description,
    CONVERT(NVARCHAR(30), j.date_created,  120) AS DateCreated,
    CONVERT(NVARCHAR(30), j.date_modified, 120) AS DateModified,
    c.name        AS CategoryName
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON j.category_id = c.category_id
ORDER BY j.name
"@
    return Invoke-MiQuery -Connection $Conn -Query $q
}

# ================================================================
# REGION: Comparison Logic
# ================================================================

function Compare-MiDataSets {
    <#
    .SYNOPSIS
        Compares two PSCustomObject arrays by a key column.
        Returns categorized results: OnlyInPrimary, OnlyInSecondary, Differences, Matching.
    #>
    param (
        [Parameter(Mandatory = $true)]  [string]   $KeyColumn,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $PrimaryData,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $SecondaryData
    )

    if (-not $PrimaryData)   { $PrimaryData   = @() }
    if (-not $SecondaryData) { $SecondaryData = @() }

    $result = [PSCustomObject]@{
        OnlyInPrimary   = [System.Collections.Generic.List[PSCustomObject]]::new()
        OnlyInSecondary = [System.Collections.Generic.List[PSCustomObject]]::new()
        Differences     = [System.Collections.Generic.List[PSCustomObject]]::new()
        Matching        = [System.Collections.Generic.List[string]]::new()
    }

    $primaryKeys   = @($PrimaryData   | ForEach-Object { $_.$KeyColumn })
    $secondaryKeys = @($SecondaryData | ForEach-Object { $_.$KeyColumn })

    # Items only in primary
    foreach ($item in $PrimaryData) {
        if ($item.$KeyColumn -notin $secondaryKeys) { $result.OnlyInPrimary.Add($item) }
    }

    # Items only in secondary
    foreach ($item in $SecondaryData) {
        if ($item.$KeyColumn -notin $primaryKeys) { $result.OnlyInSecondary.Add($item) }
    }

    # Items in both — check for property differences
    $commonKeys = $primaryKeys | Where-Object { $_ -in $secondaryKeys }
    foreach ($key in $commonKeys) {
        $pRow  = $PrimaryData   | Where-Object { $_.$KeyColumn -eq $key } | Select-Object -First 1
        $sRow  = $SecondaryData | Where-Object { $_.$KeyColumn -eq $key } | Select-Object -First 1
        $diffs = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($prop in $pRow.PSObject.Properties.Name) {
            if ($prop -eq $KeyColumn) { continue }
            $pVal = "$($pRow.$prop)"
            $sVal = "$($sRow.$prop)"
            if ($pVal -ne $sVal) {
                $diffs.Add([PSCustomObject]@{
                    Property       = $prop
                    PrimaryValue   = $pRow.$prop
                    SecondaryValue = $sRow.$prop
                })
            }
        }

        if ($diffs.Count -gt 0) {
            $result.Differences.Add([PSCustomObject]@{ Key = $key; Diffs = $diffs.ToArray() })
        }
        else {
            $result.Matching.Add($key)
        }
    }

    return $result
}

# ================================================================
# REGION: HTML Report Builders
# ================================================================

function New-HtmlInstancePropertiesSection {
    param(
        [object]   $PrimaryProps,
        [object]   $SecondaryProps,
        [string]   $PrimaryName,
        [string]   $SecondaryName
    )

    $propNames = @(
        'Edition', 'ProductVersion', 'ProductLevel', 'ProductUpdateLevel',
        'Collation', 'IsHadrEnabled', 'IsSingleUser', 'EngineEdition'
    )

    $rows = foreach ($prop in $propNames) {
        $pVal     = if ($null -ne $PrimaryProps)   { $PrimaryProps.$prop }   else { '<em>N/A</em>' }
        $sVal     = if ($null -ne $SecondaryProps) { $SecondaryProps.$prop } else { '<em>N/A</em>' }
        $rowStyle = if ("$pVal" -ne "$sVal") { ' style="background:#fff8e1"' } else { '' }
        $diffBadge = if ("$pVal" -ne "$sVal") { ' <span class="badge badge-diff">DIFF</span>' } else { '' }
        "<tr$rowStyle><td><strong>$prop$diffBadge</strong></td><td>$pVal</td><td>$sVal</td></tr>"
    }

    return @"
    <div class="section">
        <h2>&#9881; Instance Properties</h2>
        <table>
            <thead>
                <tr>
                    <th>Property</th>
                    <th>Primary &mdash; $PrimaryName</th>
                    <th>Secondary &mdash; $SecondaryName</th>
                </tr>
            </thead>
            <tbody>$($rows -join "`n")</tbody>
        </table>
    </div>
"@
}

function New-HtmlComparisonSection {
    param(
        [string]   $Title,
        [string]   $Icon,
        [string]   $KeyColumn,
        [object[]] $PrimaryData,
        [object[]] $SecondaryData,
        [string]   $PrimaryName,
        [string]   $SecondaryName
    )

    $cmp = Compare-MiDataSets `
        -KeyColumn     $KeyColumn `
        -PrimaryData   $PrimaryData `
        -SecondaryData $SecondaryData

    $cntPrimOnly = $cmp.OnlyInPrimary.Count
    $cntSecOnly  = $cmp.OnlyInSecondary.Count
    $cntDiff     = $cmp.Differences.Count
    $cntMatch    = $cmp.Matching.Count

    # Stats bar
    $statsHtml = @"
    <div class="stat-row">
        <div class="stat-chip">&#128274; Primary only: <strong>$cntPrimOnly</strong></div>
        <div class="stat-chip">&#128275; Secondary only: <strong>$cntSecOnly</strong></div>
        <div class="stat-chip">&#9888; Differences: <strong>$cntDiff</strong></div>
        <div class="stat-chip">&#10003; Matching: <strong>$cntMatch</strong></div>
    </div>
"@

    # Only-in-primary table
    $primOnlyHtml = ""
    if ($cntPrimOnly -gt 0) {
        $cols  = $cmp.OnlyInPrimary[0].PSObject.Properties.Name
        $hdrCells = ($cols | ForEach-Object { "<th>$_</th>" }) -join ''
        $bodyRows = ($cmp.OnlyInPrimary | ForEach-Object {
            $r = $_
            $cells = ($cols | ForEach-Object { "<td>$($r.$_)</td>" }) -join ''
            "<tr>$cells</tr>"
        }) -join "`n"
        $primOnlyHtml = @"
        <h3 class="sub-heading primary-sub">&#9654; Only in Primary ($PrimaryName)</h3>
        <table><thead><tr>$hdrCells</tr></thead><tbody>$bodyRows</tbody></table>
"@
    }

    # Only-in-secondary table
    $secOnlyHtml = ""
    if ($cntSecOnly -gt 0) {
        $cols  = $cmp.OnlyInSecondary[0].PSObject.Properties.Name
        $hdrCells = ($cols | ForEach-Object { "<th>$_</th>" }) -join ''
        $bodyRows = ($cmp.OnlyInSecondary | ForEach-Object {
            $r = $_
            $cells = ($cols | ForEach-Object { "<td>$($r.$_)</td>" }) -join ''
            "<tr>$cells</tr>"
        }) -join "`n"
        $secOnlyHtml = @"
        <h3 class="sub-heading secondary-sub">&#9654; Only in Secondary ($SecondaryName)</h3>
        <table><thead><tr>$hdrCells</tr></thead><tbody>$bodyRows</tbody></table>
"@
    }

    # Differences table
    $diffsHtml = ""
    if ($cntDiff -gt 0) {
        $diffRows = foreach ($diffItem in $cmp.Differences) {
            foreach ($d in $diffItem.Diffs) {
                "<tr><td><strong>$($diffItem.Key)</strong></td><td>$($d.Property)</td><td class='val-primary'>$($d.PrimaryValue)</td><td class='val-secondary'>$($d.SecondaryValue)</td></tr>"
            }
        }
        $diffsHtml = @"
        <h3 class="sub-heading diff-sub">&#9888; Value Differences</h3>
        <table>
            <thead>
                <tr>
                    <th>$KeyColumn</th>
                    <th>Property</th>
                    <th>Primary Value</th>
                    <th>Secondary Value</th>
                </tr>
            </thead>
            <tbody>$($diffRows -join "`n")</tbody>
        </table>
"@
    }

    $noDataHtml = ""
    if ($cntPrimOnly -eq 0 -and $cntSecOnly -eq 0 -and $cntDiff -eq 0) {
        $noDataHtml = "<p class='no-diff'>&#10003; No differences detected &mdash; both instances match.</p>"
    }

    return @"
    <div class="section">
        <h2>$Icon $Title</h2>
        $statsHtml
        $noDataHtml
        $primOnlyHtml
        $secOnlyHtml
        $diffsHtml
    </div>
"@
}

function New-HtmlReport {
    param(
        [string]   $PrimaryName,
        [string]   $SecondaryName,
        [string[]] $SectionBlocks,
        [string[]] $Errors,
        [datetime] $RunTime
    )

    $errorHtml = ""
    if ($Errors.Count -gt 0) {
        $errRows = ($Errors | ForEach-Object { "<tr><td>$_</td></tr>" }) -join "`n"
        $errorHtml = @"
    <div class="section error-section">
        <h2>&#9888; Errors Encountered During Run</h2>
        <table><thead><tr><th>Error Message</th></tr></thead><tbody>$errRows</tbody></table>
    </div>
"@
    }

    $allSections = $SectionBlocks -join "`n"
    $runTimeStr  = $RunTime.ToString("yyyy-MM-dd HH:mm:ss")

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure MI Comparison Report</title>
    <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', Tahoma, Arial, sans-serif;
            background: #eef1f5;
            color: #2d2d2d;
            padding: 24px;
            font-size: 14px;
        }
        .report-header {
            background: linear-gradient(135deg, #0078d4 0%, #004578 100%);
            color: #fff;
            padding: 28px 32px;
            border-radius: 10px;
            margin-bottom: 22px;
            box-shadow: 0 4px 12px rgba(0,120,212,0.3);
        }
        .report-header h1 { font-size: 1.6em; margin-bottom: 8px; letter-spacing: -0.3px; }
        .report-header .meta { font-size: 0.88em; opacity: 0.85; line-height: 1.8; }
        .report-header .meta strong { opacity: 1; }
        .section {
            background: #fff;
            border-radius: 8px;
            padding: 24px 28px;
            margin-bottom: 18px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.07);
        }
        .section h2 {
            font-size: 1.05em;
            color: #0078d4;
            margin-bottom: 14px;
            padding-bottom: 10px;
            border-bottom: 2px solid #e8e8e8;
        }
        .error-section { border-left: 4px solid #d13438; }
        .error-section h2 { color: #d13438; }
        .sub-heading {
            font-size: 0.9em;
            font-weight: 600;
            margin: 18px 0 8px;
            padding: 6px 10px;
            border-radius: 4px;
        }
        .primary-sub   { background: #dce9f9; color: #004578; }
        .secondary-sub { background: #dff0d8; color: #107c10; }
        .diff-sub      { background: #fff4ce; color: #7d5a00; }
        table { width: 100%; border-collapse: collapse; font-size: 0.86em; margin-bottom: 6px; }
        thead th {
            background: #f4f4f4;
            padding: 9px 12px;
            text-align: left;
            font-weight: 600;
            border-bottom: 2px solid #ddd;
            color: #333;
            white-space: nowrap;
        }
        tbody td { padding: 8px 12px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }
        tbody tr:last-child td { border-bottom: none; }
        tbody tr:hover { background: #fafafa; }
        .val-primary   { color: #004578; font-weight: 500; }
        .val-secondary { color: #107c10; font-weight: 500; }
        .badge {
            display: inline-block;
            padding: 1px 7px;
            border-radius: 10px;
            font-size: 0.75em;
            font-weight: 700;
            margin-left: 6px;
            vertical-align: middle;
        }
        .badge-diff  { background: #fff4ce; color: #7d5a00; border: 1px solid #f0c040; }
        .stat-row    { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 14px; }
        .stat-chip {
            background: #f3f3f3;
            border: 1px solid #e0e0e0;
            border-radius: 20px;
            padding: 5px 14px;
            font-size: 0.84em;
            color: #444;
        }
        .stat-chip strong { color: #0078d4; }
        .no-diff {
            color: #107c10;
            background: #dff0d8;
            border-radius: 6px;
            padding: 10px 16px;
            font-size: 0.9em;
        }
        footer {
            text-align: center;
            color: #aaa;
            font-size: 0.8em;
            padding: 20px 0 10px;
        }
    </style>
</head>
<body>

<div class="report-header">
    <h1>&#128269; Azure SQL Managed Instance &mdash; Comparison Report</h1>
    <div class="meta">
        Generated: <strong>$runTimeStr</strong>
        &nbsp;&nbsp;|&nbsp;&nbsp;
        Primary: <strong>$PrimaryName</strong>
        &nbsp;&nbsp;|&nbsp;&nbsp;
        Secondary: <strong>$SecondaryName</strong>
    </div>
</div>

$errorHtml

$allSections

<footer>Azure MI Comparison Tool &nbsp;&bull;&nbsp; $runTimeStr</footer>

</body>
</html>
"@
}

# ================================================================
# REGION: Main Execution
# ================================================================

Write-Header "─────────────────────────────────────────────────────"
Write-Header "  Azure MI Comparison Tool"
Write-Header "  Primary   : $PrimaryMI"
Write-Header "  Secondary : $SecondaryMI"
Write-Header "─────────────────────────────────────────────────────"

# ── Step 1: Load Config ─────────────────────────────────────────
Write-Info "Config loading from: $ConfigFilePath"

try {
    $jsonConfig = Get-Content -Path $ConfigFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
    Write-Success "Config loaded from: $ConfigFilePath"
}
catch {
    Write-Err "Failed to load config: $_"
    exit 1
}

# ── Step 2: Validate Config Structure ──────────────────────────

$configErrors = @()
if ([string]::IsNullOrWhiteSpace($jsonConfig.TenantId))           { $configErrors += "Missing: TenantId" }
if ($null -eq $jsonConfig.Servers    -or $jsonConfig.Servers.Count    -eq 0) { $configErrors += "Missing or empty: Servers" }
if ($null -eq $jsonConfig.Credentials -or $jsonConfig.Credentials.Count -eq 0) { $configErrors += "Missing or empty: Credentials" }

if ($configErrors.Count -gt 0) {
    foreach ($e in $configErrors) { Write-Err "Config validation: $e" }
    exit 1
}

# ── Step 3: Match Server Configs (FIX 3 — null guards) ─────────

$primarySrvConfig = $jsonConfig.Servers |
    Where-Object { $_.Name -eq $PrimaryMI } |
    Select-Object -First 1

if ($null -eq $primarySrvConfig) {
    Write-Err "No server entry found for PrimaryMI: '$PrimaryMI'"
    Write-Err "Servers in config: $($jsonConfig.Servers.Name -join ', ')"
    exit 1
}
Write-Success "Matched server config for Primary: '$PrimaryMI'"

$secondarySrvConfig = $jsonConfig.Servers |
    Where-Object { $_.Name -eq $SecondaryMI } |
    Select-Object -First 1

if ($null -eq $secondarySrvConfig) {
    Write-Err "No server entry found for SecondaryMI: '$SecondaryMI'"
    Write-Err "Servers in config: $($jsonConfig.Servers.Name -join ', ')"
    exit 1
}
Write-Success "Matched server config for Secondary: '$SecondaryMI'"

# ── Step 4: Match Credentials (FIX 3 — null guards) ────────────

$primaryCredConfig = $jsonConfig.Credentials |
    Where-Object { $_.Name -eq $primarySrvConfig.CredentialName } |
    Select-Object -First 1

if ($null -eq $primaryCredConfig) {
    Write-Err "No credential found for name: '$($primarySrvConfig.CredentialName)'"
    exit 1
}
Write-Success "Matched credentials: '$($primaryCredConfig.Name)' for server '$PrimaryMI'"

$secondaryCredConfig = $jsonConfig.Credentials |
    Where-Object { $_.Name -eq $secondarySrvConfig.CredentialName } |
    Select-Object -First 1

if ($null -eq $secondaryCredConfig) {
    Write-Err "No credential found for name: '$($secondarySrvConfig.CredentialName)'"
    exit 1
}
Write-Success "Matched credentials: '$($secondaryCredConfig.Name)' for server '$SecondaryMI'"

# ── Step 5: Acquire Azure AD Tokens ────────────────────────────

Write-Info "Acquiring Azure AD tokens..."

try {
    $primaryToken = Get-AzureSqlToken `
        -TenantId     $jsonConfig.TenantId `
        -ClientId     $primaryCredConfig.ClientId `
        -ClientSecret $primaryCredConfig.ClientSecret
    Write-Success "Access token acquired for ClientId: $($primaryCredConfig.ClientId)"
}
catch {
    Write-Err "Token acquisition failed for Primary: $_"
    exit 1
}

try {
    $secondaryToken = Get-AzureSqlToken `
        -TenantId     $jsonConfig.TenantId `
        -ClientId     $secondaryCredConfig.ClientId `
        -ClientSecret $secondaryCredConfig.ClientSecret
    Write-Success "Access token acquired for ClientId: $($secondaryCredConfig.ClientId)"
}
catch {
    Write-Err "Token acquisition failed for Secondary: $_"
    exit 1
}

# ── Step 6: Resolve FQDNs (FIX 2) ──────────────────────────────

$primaryFqdn   = Get-MiFqdn -ServerName $PrimaryMI   -HostFqdn $primarySrvConfig.HostFqdn
$secondaryFqdn = Get-MiFqdn -ServerName $SecondaryMI -HostFqdn $secondarySrvConfig.HostFqdn
$primaryPort   = if ($primarySrvConfig.Port)   { $primarySrvConfig.Port }   else { 1433 }
$secondaryPort = if ($secondarySrvConfig.Port) { $secondarySrvConfig.Port } else { 1433 }

# ── Step 7: Open SQL Connections (FIX 3 & 4) ───────────────────

Write-Info "Opening SQL connections..."

$primaryConn = Open-MiConnection `
    -ServerName  $PrimaryMI `
    -Fqdn        $primaryFqdn `
    -AccessToken $primaryToken `
    -Port        $primaryPort

$secondaryConn = Open-MiConnection `
    -ServerName  $SecondaryMI `
    -Fqdn        $secondaryFqdn `
    -AccessToken $secondaryToken `
    -Port        $secondaryPort

# FIX 4: Warn but continue with partial report if one fails
if ($null -eq $primaryConn) {
    Write-Warn "Primary connection unavailable — Primary sections will show N/A."
}
if ($null -eq $secondaryConn) {
    Write-Warn "Secondary connection unavailable — Secondary sections will show N/A."
}
if ($null -eq $primaryConn -and $null -eq $secondaryConn) {
    Write-Err "Both connections failed. Cannot generate report."
    exit 1
}

# ── Step 8: Collect Data ────────────────────────────────────────

Write-Info "Collecting data from instances..."

$pInstanceProps = if ($primaryConn)   { Get-InstanceProperties  -Conn $primaryConn   } else { $null }
$sInstanceProps = if ($secondaryConn) { Get-InstanceProperties  -Conn $secondaryConn } else { $null }

$pDbs    = if ($primaryConn)   { @(Get-DatabaseList       -Conn $primaryConn)   } else { @() }
$sDbs    = if ($secondaryConn) { @(Get-DatabaseList       -Conn $secondaryConn) } else { @() }

$pLogins = if ($primaryConn)   { @(Get-ServerLogins       -Conn $primaryConn)   } else { @() }
$sLogins = if ($secondaryConn) { @(Get-ServerLogins       -Conn $secondaryConn) } else { @() }

$pSpCfg  = if ($primaryConn)   { @(Get-ServerConfiguration -Conn $primaryConn)   } else { @() }
$sSpCfg  = if ($secondaryConn) { @(Get-ServerConfiguration -Conn $secondaryConn) } else { @() }

$pLinked = if ($primaryConn)   { @(Get-LinkedServers      -Conn $primaryConn)   } else { @() }
$sLinked = if ($secondaryConn) { @(Get-LinkedServers      -Conn $secondaryConn) } else { @() }

$pJobs   = if ($primaryConn)   { @(Get-AgentJobs          -Conn $primaryConn)   } else { @() }
$sJobs   = if ($secondaryConn) { @(Get-AgentJobs          -Conn $secondaryConn) } else { @() }

Write-Success "Data collection complete."

# ── Step 9: Build HTML Sections ─────────────────────────────────

Write-Info "Generating HTML report..."

$pProps = if ($null -ne $pInstanceProps -and @($pInstanceProps).Count -gt 0) { $pInstanceProps[0] } else { $null }
$sProps = if ($null -ne $sInstanceProps -and @($sInstanceProps).Count -gt 0) { $sInstanceProps[0] } else { $null }

$sections = @(
    New-HtmlInstancePropertiesSection `
        -PrimaryProps   $pProps `
        -SecondaryProps $sProps `
        -PrimaryName    $PrimaryMI `
        -SecondaryName  $SecondaryMI

    New-HtmlComparisonSection `
        -Title         "Databases" `
        -Icon          "&#128196;" `
        -KeyColumn     "DatabaseName" `
        -PrimaryData   $pDbs `
        -SecondaryData $sDbs `
        -PrimaryName   $PrimaryMI `
        -SecondaryName $SecondaryMI

    New-HtmlComparisonSection `
        -Title         "Server Logins" `
        -Icon          "&#128100;" `
        -KeyColumn     "LoginName" `
        -PrimaryData   $pLogins `
        -SecondaryData $sLogins `
        -PrimaryName   $PrimaryMI `
        -SecondaryName $SecondaryMI

    New-HtmlComparisonSection `
        -Title         "Server Configuration (sp_configure)" `
        -Icon          "&#9881;" `
        -KeyColumn     "ConfigName" `
        -PrimaryData   $pSpCfg `
        -SecondaryData $sSpCfg `
        -PrimaryName   $PrimaryMI `
        -SecondaryName $SecondaryMI

    New-HtmlComparisonSection `
        -Title         "Linked Servers" `
        -Icon          "&#128279;" `
        -KeyColumn     "LinkedServerName" `
        -PrimaryData   $pLinked `
        -SecondaryData $sLinked `
        -PrimaryName   $PrimaryMI `
        -SecondaryName $SecondaryMI

    New-HtmlComparisonSection `
        -Title         "SQL Agent Jobs" `
        -Icon          "&#128336;" `
        -KeyColumn     "JobName" `
        -PrimaryData   $pJobs `
        -SecondaryData $sJobs `
        -PrimaryName   $PrimaryMI `
        -SecondaryName $SecondaryMI
)

$htmlReport = New-HtmlReport `
    -PrimaryName   $PrimaryMI `
    -SecondaryName $SecondaryMI `
    -SectionBlocks $sections `
    -Errors        $scriptErrors.ToArray() `
    -RunTime       $scriptStartTime

# ── Step 10: Write Report ───────────────────────────────────────

$outputDir = Split-Path -Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    try {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-Success "Created output directory: $outputDir"
    }
    catch {
        Write-Err "Could not create output directory '$outputDir': $_"
        exit 1
    }
}

try {
    $htmlReport | Out-File -FilePath $OutputPath -Encoding UTF8 -Force -ErrorAction Stop
    Write-Success "Report written to: $OutputPath"
}
catch {
    Write-Err "Failed to write report to '$OutputPath': $_"
    exit 1
}

# ── Step 11: Cleanup ────────────────────────────────────────────

Write-Info "Closing connections..."
if ($null -ne $primaryConn   -and $primaryConn.State   -eq [System.Data.ConnectionState]::Open) {
    $primaryConn.Close()
    Write-Success "Primary connection closed."
}
if ($null -ne $secondaryConn -and $secondaryConn.State -eq [System.Data.ConnectionState]::Open) {
    $secondaryConn.Close()
    Write-Success "Secondary connection closed."
}

$elapsed = [math]::Round(((Get-Date) - $scriptStartTime).TotalSeconds, 1)
Write-Header "─────────────────────────────────────────────────────"
Write-Header "  Run complete in ${elapsed}s"
Write-Header "  Report   : $OutputPath"
Write-Header "  Errors   : $($scriptErrors.Count)"
Write-Header "─────────────────────────────────────────────────────"
