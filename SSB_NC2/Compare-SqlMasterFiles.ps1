#Requires -Version 5.1
<#
.SYNOPSIS
Compares sys.master_files properties between two SQL Server instances using SMO.

.DESCRIPTION
Connects to source and target SQL Server instances via SMO, queries sys.master_files
for each matched database pair, and generates a styled HTML comparison report showing
file-level differences: name, physical_name, state_desc, size, growth.

.PARAMETER SourceServer
Source SQL Server instance name or IP (e.g. "SQL01" or "SQL01,1733").

.PARAMETER TargetServer
Target SQL Server instance name or IP.

.PARAMETER SourceDatabase
Source database name, or "All" to compare every user database on the source.

.PARAMETER TargetDatabase
Target database name, or "All" to compare every user database on the target.

.PARAMETER OutputPath
Folder where the HTML report is saved. Defaults to the current directory.

.PARAMETER UseWindowsAuth
Use Windows Authentication (default).

.PARAMETER SourceCredential
PSCredential for SQL Authentication on the source (optional).

.PARAMETER TargetCredential
PSCredential for SQL Authentication on the target (optional).

.EXAMPLE
.\Compare-SqlMasterFiles.ps1 -SourceServer "SQL01,1733" -TargetServer "SQL02,1733" `
-SourceDatabase "All" -TargetDatabase "All" -UseWindowsAuth

.EXAMPLE
.\Compare-SqlMasterFiles.ps1 -SourceServer "SQL-PROD-01" -TargetServer "SQL-DR-02" `
-SourceDatabase "SalesDB" -TargetDatabase "SalesDB" -UseWindowsAuth
#>

[CmdletBinding()]
param(
[Parameter(Mandatory = $true)] [string]$SourceServer,
[Parameter(Mandatory = $true)] [string]$TargetServer,
[Parameter(Mandatory = $true)] [string]$SourceDatabase,
[Parameter(Mandatory = $true)] [string]$TargetDatabase,
[Parameter(Mandatory = $false)] [string]$OutputPath = (Get-Location).Path,
[Parameter(Mandatory = $false)] [switch]$UseWindowsAuth,
[Parameter(Mandatory = $false)] [System.Management.Automation.PSCredential]$SourceCredential,
[Parameter(Mandatory = $false)] [System.Management.Automation.PSCredential]$TargetCredential
)

$ErrorActionPreference = "Stop"
$ScriptVersion = "2.0.0"

---------------------------------------------------------------------------
#region HTML ENCODING HELPER

---------------------------------------------------------------------------
function ConvertTo-HtmlEncoded {
param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
if ([string]::IsNullOrEmpty($Text)) { return "" }
$Text = $Text.Replace('&', '&')
$Text = $Text.Replace('<', '<')
$Text = $Text.Replace('>', '>')
$Text = $Text.Replace('"', '"')
$Text = $Text.Replace("'", ''')
return $Text
}
#endregion

---------------------------------------------------------------------------
#region SMO ASSEMBLY LOADER

---------------------------------------------------------------------------
function Import-SmoAssemblies {
$smoLoaded = $false
try {
$null = [Microsoft.SqlServer.Management.Smo.Server]
$null = [Microsoft.SqlServer.Management.Common.ServerConnection]
$smoLoaded = $true
} catch { $smoLoaded = $false }

if ($smoLoaded) { Write-Verbose "SMO assemblies already loaded."; return }

if (Get-Module -ListAvailable -Name "SqlServer" -ErrorAction SilentlyContinue) {
    try { Import-Module SqlServer -DisableNameChecking -ErrorAction Stop
          Write-Verbose "SMO loaded via SqlServer module."; return
    } catch { Write-Warning "SqlServer module failed: $($_.Exception.Message)" }
}
if (Get-Module -ListAvailable -Name "SQLPS" -ErrorAction SilentlyContinue) {
    try { Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
          Write-Verbose "SMO loaded via SQLPS module."; return
    } catch { Write-Warning "SQLPS module failed: $($_.Exception.Message)" }
}
foreach ($asm in @(
    "Microsoft.SqlServer.Smo",
    "Microsoft.SqlServer.ConnectionInfo",
    "Microsoft.SqlServer.Management.Sdk.Sfc",
    "Microsoft.SqlServer.SqlEnum")) {
    try   { [System.Reflection.Assembly]::LoadWithPartialName($asm) | Out-Null }
    catch { Write-Warning "Could not load '$asm': $($_.Exception.Message)" }
}
try {
    $null = [Microsoft.SqlServer.Management.Smo.Server]
    $null = [Microsoft.SqlServer.Management.Common.ServerConnection]
} catch {
    throw "SMO types unavailable. Install SSMS or run: Install-Module SqlServer"
}
}
#endregion

---------------------------------------------------------------------------
#region CONNECTION FACTORY

---------------------------------------------------------------------------
function Connect-SqlServer {
param(
[Parameter(Mandatory)] [string]$ServerName,
[System.Management.Automation.PSCredential]$Credential = $null,
[bool]$WindowsAuth = $true
)
Write-Host " Connecting to: $ServerName ..." -ForegroundColor Cyan
try {
$conn = New-Object Microsoft.SqlServer.Management.Common.ServerConnection
$conn.ServerInstance = $ServerName
$conn.ConnectTimeout = 30
$conn.StatementTimeout = 120
if ($WindowsAuth -or ($null -eq $Credential)) {
$conn.LoginSecure = $true
} else {
$conn.LoginSecure = $false
$conn.Login = $Credential.UserName
$conn.SecurePassword = $Credential.Password
}
$smo = New-Object Microsoft.SqlServer.Management.Smo.Server($conn)
$ver = $smo.VersionString
if ([string]::IsNullOrWhiteSpace($ver)) {
throw "Server returned empty version — instance may be unavailable."
}
Write-Host (" OK {0} [SQL Server {1} | Edition: {2}]" -f
$ServerName, $ver, $smo.Edition) -ForegroundColor Green
return $smo
} catch [Microsoft.SqlServer.Management.Common.ConnectionFailureException] {
Write-Error "Connection failure for '$ServerName': $($.Exception.Message)"
return $null
} catch {
Write-Error "Error connecting to '$ServerName': $($.Exception.Message)"
return $null
}
}
#endregion

---------------------------------------------------------------------------
#region MASTER FILES QUERY

---------------------------------------------------------------------------
function Get-MasterFileProperties {
<#
.SYNOPSIS
Queries sys.master_files for the specified database (or all user databases).
Returns a list of file-row PSCustomObjects grouped by database name.

    Columns returned:
      DatabaseName, FileId, LogicalName, PhysicalName, FileType,
      StateDesc, SizeMB, GrowthDisplay, IsPercentGrowth, GrowthRaw
#>
param(
    [Parameter(Mandatory)] [Microsoft.SqlServer.Management.Smo.Server]$SmoServer,
    [Parameter(Mandatory)] [string]$DatabaseName
)

$safeDb      = $DatabaseName.Replace("'", "''")
$whereClause = if ($DatabaseName -eq "All") {
    "WHERE d.database_id > 4"
} else {
    "WHERE d.name = N'$safeDb'"
}

$query = @"
SELECT
d.name AS [DatabaseName],
mf.file_id AS [FileId],
mf.name AS [LogicalName],
mf.physical_name AS [PhysicalName],
mf.type_desc AS [FileType],
mf.state_desc AS [StateDesc],
CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2)) AS [SizeMB],
CASE
WHEN mf.is_percent_growth = 1
THEN CAST(mf.growth AS VARCHAR(10)) + '%'
ELSE
CAST(CAST(mf.growth * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + ' MB'
END AS [GrowthDisplay],
mf.is_percent_growth AS [IsPercentGrowth],
mf.growth AS [GrowthRaw]
FROM sys.master_files mf
INNER JOIN sys.databases d ON d.database_id = mf.database_id
$whereClause
ORDER BY d.name, mf.type, mf.file_id;
"@

try {
    $ds    = $SmoServer.Databases["master"].ExecuteWithResults($query)
    $table = $ds.Tables[0]

    if ($table.Rows.Count -eq 0) {
        Write-Warning "No master_files rows for '$DatabaseName' on '$($SmoServer.Name)'."
        return [PSCustomObject[]]@()
    }

    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($row in $table.Rows) {
        $obj = [ordered]@{}
        foreach ($col in $table.Columns) {
            $v = $row[$col.ColumnName]
            $obj[$col.ColumnName] = if ($v -is [System.DBNull]) { "" } else { "$v" }
        }
        $list.Add([PSCustomObject]$obj)
    }
    return [PSCustomObject[]]$list.ToArray()

} catch {
    Write-Error "Failed querying master_files for '$DatabaseName' on " +
                "'$($SmoServer.Name)': $($_.Exception.Message)"
    return [PSCustomObject[]]@()
}
}
#endregion

---------------------------------------------------------------------------
#region COMPARISON ENGINE

---------------------------------------------------------------------------
Columns that are shown but never count as differences
$script:InfoColumns = [System.Collections.Generic.HashSet[string]]::new(
[System.StringComparer]::OrdinalIgnoreCase)
@("DatabaseName","FileId","LogicalName","FileType","IsPercentGrowth","GrowthRaw") |
ForEach-Object { [void]$script:InfoColumns.Add($_) }

Columns that ARE compared for differences
$script:CompareColumns = @("PhysicalName","StateDesc","SizeMB","GrowthDisplay")

function Compare-DatabaseFiles {
<#
.SYNOPSIS
Compares source and target file rows for one database.
Matches on LogicalName. Returns a result object with per-file comparisons.
#>
param(
[Parameter(Mandatory)] [PSCustomObject[]]$SourceFiles,
[Parameter(Mandatory)] [PSCustomObject[]]$TargetFiles,
[Parameter(Mandatory)] [string]$SourceDbName,
[Parameter(Mandatory)] [string]$TargetDbName
)

# Build lookup dictionaries keyed by LogicalName (case-insensitive)
$srcMap = [System.Collections.Generic.Dictionary[string,PSCustomObject]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $SourceFiles) { $srcMap[$f.LogicalName] = $f }

$tgtMap = [System.Collections.Generic.Dictionary[string,PSCustomObject]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $TargetFiles) { $tgtMap[$f.LogicalName] = $f }

# Union of all logical names
$allNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($k in $srcMap.Keys) { [void]$allNames.Add($k) }
foreach ($k in $tgtMap.Keys) { [void]$allNames.Add($k) }

$fileResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalDiffs  = 0
$missingInTgt = [System.Collections.Generic.List[string]]::new()
$missingInSrc = [System.Collections.Generic.List[string]]::new()

foreach ($logName in ($allNames | Sort-Object)) {
    $hasSrc = $srcMap.ContainsKey($logName)
    $hasTgt = $tgtMap.ContainsKey($logName)

    if (-not $hasSrc) {
        $missingInSrc.Add($logName)
        # Show target-only file
        $tRow = $tgtMap[$logName]
        $propRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($col in $script:CompareColumns) {
            $propRows.Add([PSCustomObject]@{
                Column   = $col
                Source   = "— NOT PRESENT —"
                Target   = "$($tRow.PSObject.Properties[$col].Value)"
                IsDiff   = $true
                IsMissing = $true
            })
            $totalDiffs++
        }
        $fileResults.Add([PSCustomObject]@{
            LogicalName  = $logName
            FileType     = "$($tRow.FileType)"
            FileId       = "$($tRow.FileId)"
            Status       = "MissingOnSource"
            PropRows     = $propRows
            DiffCount    = $propRows.Count
        })
        continue
    }
    if (-not $hasTgt) {
        $missingInTgt.Add($logName)
        $sRow = $srcMap[$logName]
        $propRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($col in $script:CompareColumns) {
            $propRows.Add([PSCustomObject]@{
                Column   = $col
                Source   = "$($sRow.PSObject.Properties[$col].Value)"
                Target   = "— NOT PRESENT —"
                IsDiff   = $true
                IsMissing = $true
            })
            $totalDiffs++
        }
        $fileResults.Add([PSCustomObject]@{
            LogicalName  = $logName
            FileType     = "$($sRow.FileType)"
            FileId       = "$($sRow.FileId)"
            Status       = "MissingOnTarget"
            PropRows     = $propRows
            DiffCount    = $propRows.Count
        })
        continue
    }

    # Both sides present — compare
    $sRow      = $srcMap[$logName]
    $tRow      = $tgtMap[$logName]
    $propRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $fileDiffs = 0

    foreach ($col in $script:CompareColumns) {
        $sv = if ($null -ne $sRow.PSObject.Properties[$col]) {
            "$($sRow.PSObject.Properties[$col].Value)" } else { "" }
        $tv = if ($null -ne $tRow.PSObject.Properties[$col]) {
            "$($tRow.PSObject.Properties[$col].Value)" } else { "" }
        $isDiff = $sv -ne $tv
        if ($isDiff) { $fileDiffs++; $totalDiffs++ }
        $propRows.Add([PSCustomObject]@{
            Column    = $col
            Source    = $sv
            Target    = $tv
            IsDiff    = $isDiff
            IsMissing = $false
        })
    }

    $fileResults.Add([PSCustomObject]@{
        LogicalName = $logName
        FileType    = "$($sRow.FileType)"
        FileId      = "$($sRow.FileId)"
        Status      = if ($fileDiffs -gt 0) { "Diff" } else { "Match" }
        PropRows    = $propRows
        DiffCount   = $fileDiffs
    })
}

return [PSCustomObject]@{
    SourceDatabase = $SourceDbName
    TargetDatabase = $TargetDbName
    FileResults    = $fileResults
    TotalDiffs     = $totalDiffs
    MissingOnTarget = $missingInTgt
    MissingOnSource = $missingInSrc
    SourceFileCount = $SourceFiles.Count
    TargetFileCount = $TargetFiles.Count
}
}
#endregion

---------------------------------------------------------------------------
#region HTML REPORT GENERATOR

---------------------------------------------------------------------------
function New-HtmlReport {
param(
[string]$SourceServerName,
[string]$TargetServerName,
[object]$SourceSmo,
[object]$TargetSmo,
[System.Collections.Generic.List[PSCustomObject]]$ComparisonList,
[System.Collections.Generic.List[PSCustomObject]]$Comments,
[string]$ReportOutputPath,
[string]$Version = "2.0.0"
)

$reportDate  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$reportFile  = Join-Path $ReportOutputPath ("SqlMasterFiles_" +
               (Get-Date -Format "yyyyMMdd_HHmmss") + ".html")

$totalDiffs  = 0; foreach ($c in $ComparisonList) { $totalDiffs += $c.TotalDiffs }
$dbCount     = $ComparisonList.Count
$dbsWithDiff = ($ComparisonList | Where-Object { $_.TotalDiffs -gt 0 } | Measure-Object).Count
$dbsClean    = $dbCount - $dbsWithDiff

$srcVer = if ($null -ne $SourceSmo) { $SourceSmo.VersionString } else { "Unknown" }
$tgtVer = if ($null -ne $TargetSmo) { $TargetSmo.VersionString } else { "Unknown" }
$srcEd  = if ($null -ne $SourceSmo) { $SourceSmo.Edition       } else { "Unknown" }
$tgtEd  = if ($null -ne $TargetSmo) { $TargetSmo.Edition       } else { "Unknown" }

$css = @'
,::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,-apple-system,sans-serif;background:#f1f5f9;color:#1e293b;font-size:14px;line-height:1.6}

/* Header */
.rpt-header{background:linear-gradient(135deg,#0f172a 0%,#1e3a5f 50%,#1d4ed8 100%);color:#fff;padding:32px 48px;display:flex;justify-content:space-between;align-items:flex-start;box-shadow:0 4px 20px rgba(0,0,0,.3)}
.rpt-header-left h1{font-size:24px;font-weight:700;letter-spacing:.3px;display:flex;align-items:center;gap:10px}
.rpt-header-left .subtitle{font-size:12px;color:#93c5fd;margin-top:6px;letter-spacing:.3px}
.rpt-header-right{text-align:right;font-size:12px;color:#bfdbfe;line-height:2}
.rpt-header-right strong{color:#fff}

/* Server Banner */
.srv-banner{display:grid;grid-template-columns:1fr 1fr}
.srv-card{display:flex;align-items:center;gap:16px;padding:20px 48px;color:#fff}
.srv-card.src{background:#14532d;border-right:1px solid #166534}
.srv-card.tgt{background:#1e3a5f}
.srv-icon{width:48px;height:48px;border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:24px;flex-shrink:0}
.srv-card.src .srv-icon{background:#166534}
.srv-card.tgt .srv-icon{background:#1d4ed8}
.srv-info-label{font-size:10px;text-transform:uppercase;letter-spacing:1.5px;color:rgba(255,255,255,.6);margin-bottom:3px}
.srv-info-name{font-size:18px;font-weight:700;color:#fff}
.srv-info-ver{font-size:11px;color:rgba(255,255,255,.55);margin-top:3px}

/* Summary */
.summary-strip{background:#fff;padding:28px 48px;border-bottom:1px solid #e2e8f0;box-shadow:0 1px 3px rgba(0,0,0,.05)}
.summary-strip h2{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:1.5px;color:#64748b;margin-bottom:16px;display:flex;align-items:center;gap:8px}
.summary-cards{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}
.s-card{border-radius:12px;padding:18px 22px;display:flex;flex-direction:column;gap:6px;border:1px solid transparent}
.s-card.blue {background:#eff6ff;border-color:#bfdbfe}
.s-card.green {background:#f0fdf4;border-color:#bbf7d0}
.s-card.red {background:#fef2f2;border-color:#fecaca}
.s-card.orange{background:#fff7ed;border-color:#fed7aa}
.s-card-label {font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:1px;color:#64748b}
.s-card-value {font-size:34px;font-weight:800;line-height:1}
.s-card.blue .s-card-value{color:#1d4ed8}
.s-card.green .s-card-value{color:#15803d}
.s-card.red .s-card-value{color:#dc2626}
.s-card.orange .s-card-value{color:#ea580c}

/* Content */
.content{padding:32px 48px}

/* DB Block */
.db-block{background:#fff;border:1px solid #e2e8f0;border-radius:16px;box-shadow:0 2px 8px rgba(0,0,0,.06);margin-bottom:32px;overflow:hidden}
.db-block-header{display:flex;justify-content:space-between;align-items:center;padding:16px 24px;background:#f8fafc;border-bottom:2px solid #e2e8f0}
.db-block-title{display:flex;align-items:center;gap:10px;font-size:17px;font-weight:700;color:#0f172a}
.db-block-meta{display:flex;align-items:center;gap:12px}
.file-count{font-size:12px;color:#94a3b8;font-weight:500}
.badge{display:inline-flex;align-items:center;gap:5px;padding:5px 14px;border-radius:999px;font-size:12px;font-weight:700}
.badge-diff{background:#fee2e2;color:#b91c1c;border:1px solid #fecaca}
.badge-ok {background:#dcfce7;color:#15803d;border:1px solid #bbf7d0}

/* File Sections */
.file-section{border-bottom:1px solid #f1f5f9}
.file-section:last-child{border-bottom:none}
.file-header{display:flex;justify-content:space-between;align-items:center;padding:12px 24px;background:#f8fafc;border-bottom:1px solid #e2e8f0;border-top:1px solid #e2e8f0;cursor:pointer}
.file-header:hover{background:#f1f5f9}
.file-title{display:flex;align-items:center;gap:10px}
.file-icon{font-size:16px}
.file-logical{font-size:14px;font-weight:700;color:#1e293b}
.file-type-pill{display:inline-flex;align-items:center;padding:2px 10px;border-radius:999px;font-size:10.5px;font-weight:700;text-transform:uppercase;letter-spacing:.8px}
.pill-rows{background:#dbeafe;color:#1e40af}
.pill-log {background:#fce7f3;color:#9d174d}
.file-status-area{display:flex;align-items:center;gap:10px}
.file-diff-count{font-size:11px;color:#94a3b8}
.status-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.status-dot.diff {background:#ef4444}
.status-dot.match {background:#22c55e}
.status-dot.missing{background:#f59e0b}

/* File Properties Table */
table.file-table{width:100%;border-collapse:collapse;font-size:13.5px}
table.file-table thead tr{background:#f1f5f9;border-bottom:2px solid #cbd5e1}
table.file-table thead th{padding:10px 20px;text-align:left;font-size:10.5px;font-weight:700;text-transform:uppercase;letter-spacing:1px;color:#475569;white-space:nowrap}
table.file-table thead th:first-child {width:18%}
table.file-table thead th:nth-child(2){width:37%}
table.file-table thead th:nth-child(3){width:37%}
table.file-table thead th:last-child {width:8%;text-align:center}
table.file-table tbody tr{border-bottom:1px solid #f1f5f9;transition:background .1s}
table.file-table tbody tr:last-child{border-bottom:none}
table.file-table tbody tr:hover{background:#f8fafc}
table.file-table tbody tr.row-diff{background:#fff5f5;border-bottom:1px solid #fecaca}
table.file-table tbody tr.row-diff:hover{background:#fee2e2}
table.file-table tbody tr.row-diff td:first-child{border-left:3px solid #ef4444;padding-left:17px}
table.file-table tbody tr.row-missing{background:#fffbeb;border-bottom:1px solid #fde68a}
table.file-table tbody tr.row-missing td:first-child{border-left:3px solid #f59e0b;padding-left:17px}
table.file-table td{padding:10px 20px;vertical-align:middle}
.col-name{font-weight:700;color:#334155;font-size:12.5px;text-transform:uppercase;letter-spacing:.6px}
.row-diff .col-name{color:#b91c1c}
.row-missing .col-name{color:#92400e}
.col-val{font-family:'Consolas','Courier New',monospace;font-size:12.5px;color:#1e293b;word-break:break-all}
.row-diff .col-val{color:#b91c1c;font-weight:700}
.row-missing .col-val{color:#92400e;font-style:italic}
.missing-placeholder{color:#94a3b8;font-style:italic;font-size:12px}
.cell-status{text-align:center;font-size:15px}
.ico-match {color:#16a34a;font-weight:700}
.ico-diff {color:#dc2626;font-weight:700}
.ico-missing{color:#d97706;font-weight:700}

/* Legend */
.legend{display:flex;gap:24px;padding:12px 24px;background:#f8fafc;border-top:1px solid #e2e8f0;font-size:11.5px;color:#475569}
.legend-item{display:flex;align-items:center;gap:7px}
.legend-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.legend-dot.d{background:#ef4444}
.legend-dot.m{background:#22c55e}
.legend-dot.w{background:#f59e0b}

/* Notes */
.notes-panel{background:#fff;border:1px solid #e2e8f0;border-radius:16px;box-shadow:0 2px 8px rgba(0,0,0,.06);margin-bottom:28px;overflow:hidden}
.notes-header{display:flex;align-items:center;gap:12px;padding:16px 24px;background:#fffbeb;border-bottom:1px solid #fde68a}
.notes-header h3{font-size:15px;font-weight:700;color:#92400e}
.notes-header .pin-icon{font-size:20px}
.notes-body{padding:4px 0}
.note-row{display:flex;align-items:flex-start;gap:12px;padding:11px 24px;border-bottom:1px solid #f8fafc;transition:background .1s}
.note-row:last-child{border-bottom:none}
.note-row:hover{background:#fffdf5}
.note-icon{font-size:15px;flex-shrink:0;margin-top:1px}
.note-content{display:flex;flex-wrap:wrap;align-items:baseline;gap:6px}
.note-badge{display:inline-block;padding:2px 8px;border-radius:5px;font-size:9.5px;font-weight:800;text-transform:uppercase;letter-spacing:.6px;flex-shrink:0}
.note-badge.success{background:#dcfce7;color:#166534}
.note-badge.info {background:#dbeafe;color:#1e40af}
.note-badge.warning{background:#fef9c3;color:#854d0e}
.note-badge.error {background:#fee2e2;color:#991b1b}
.note-text{font-size:13px;color:#334155;line-height:1.5}

/* Footer */
.rpt-footer{text-align:center;padding:24px 48px;font-size:12px;color:#94a3b8;background:#fff;border-top:1px solid #e2e8f0}
.rpt-footer strong{color:#64748b}
'@

$sb = [System.Text.StringBuilder]::new(4MB)

[void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head>')
[void]$sb.AppendLine('<meta charset="UTF-8">')
[void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1.0">')
[void]$sb.AppendLine('<title>SQL Server Master Files Comparison Report</title>')
[void]$sb.AppendLine("<style>$css</style></head><body>")

# ── Header
$encSrc = ConvertTo-HtmlEncoded $SourceServerName
$encTgt = ConvertTo-HtmlEncoded $TargetServerName
[void]$sb.AppendLine(@"
# ── Per-Database Blocks
foreach ($comp in $ComparisonList) {
    $eDbSrc    = ConvertTo-HtmlEncoded $comp.SourceDatabase
    $eDbTgt    = ConvertTo-HtmlEncoded $comp.TargetDatabase
    $dbLabel   = if ($eDbSrc -eq $eDbTgt) { $eDbSrc } else { "$eDbSrc &#8594; $eDbTgt" }
    $badgeCls  = if ($comp.TotalDiffs -gt 0) { "badge-diff" } else { "badge-ok" }
    $badgeTxt  = if ($comp.TotalDiffs -gt 0) {
        "&#9888;&nbsp;$($comp.TotalDiffs) Difference(s)"
    } else { "&#10003;&nbsp;Identical" }
    $fileCount = $comp.FileResults.Count

    [void]$sb.AppendLine(@"
    foreach ($fr in $comp.FileResults) {
        $eLogical  = ConvertTo-HtmlEncoded $fr.LogicalName
        $ftPill    = if ($fr.FileType -eq "LOG") {
            "<span class='file-type-pill pill-log'>&#128220; LOG</span>"
        } else {
            "<span class='file-type-pill pill-rows'>&#128190; DATA</span>"
        }

        $dotCls = switch ($fr.Status) {
            "Diff"            { "diff" }
            "MissingOnTarget" { "missing" }
            "MissingOnSource" { "missing" }
            default           { "match" }
        }
        $fileDiffLabel = if ($fr.DiffCount -gt 0) {
            "<span class='file-diff-count'>$($fr.DiffCount) diff(s)</span>"
        } else { "<span class='file-diff-count'>Match</span>" }

        [void]$sb.AppendLine(@"
        foreach ($pr in $fr.PropRows) {
            $eCol = ConvertTo-HtmlEncoded $pr.Column
            $eSrc = ConvertTo-HtmlEncoded $pr.Source
            $eTgt = ConvertTo-HtmlEncoded $pr.Target

            if ($pr.IsMissing) {
                $srcCell = if ($pr.Source -like "*NOT PRESENT*") {
                    "<span class='missing-placeholder'>&#8212; Not present on source</span>"
                } else { "<span class='col-val'>$eSrc</span>" }
                $tgtCell = if ($pr.Target -like "*NOT PRESENT*") {
                    "<span class='missing-placeholder'>&#8212; Not present on target</span>"
                } else { "<span class='col-val'>$eTgt</span>" }
                [void]$sb.AppendLine(@"
    <tr class="row-missing">
      <td class="col-name">$eCol</td>
      <td>$srcCell</td>
      <td>$tgtCell</td>
      <td class="cell-status"><span class="ico-missing">&#9888;</span></td>
    </tr>
"@)
} elseif ($pr.IsDiff) {
[void]$sb.AppendLine(@"

$eCol
$eSrc
$eTgt
✗

"@)
} else {
[void]$sb.AppendLine(@"

$eCol
$eSrc
$eTgt
✓

"@)
}
}

        [void]$sb.AppendLine("      </tbody></table></div>")
    }

    [void]$sb.AppendLine(@"
# ── Notes
if ($null -ne $Comments -and $Comments.Count -gt 0) {
    [void]$sb.AppendLine(@"
[void]$sb.AppendLine(@"
try {
    [System.IO.File]::WriteAllText($reportFile, $sb.ToString(),
        [System.Text.Encoding]::UTF8)
    Write-Host "  Report saved: $reportFile" -ForegroundColor Green
    return $reportFile
} catch {
    Write-Error "Failed to write report '$reportFile': $($_.Exception.Message)"
    return $null
}
}
#endregion

---------------------------------------------------------------------------
#region MAIN ORCHESTRATION

---------------------------------------------------------------------------
function Invoke-Main {

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "   SQL Server Master Files Comparison Tool"  -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

$comments = [System.Collections.Generic.List[PSCustomObject]]::new()
$srcSmo   = $null
$tgtSmo   = $null

# 1 — Load SMO
Write-Host "[1/4] Loading SMO assemblies..." -ForegroundColor Yellow
try {
    Import-SmoAssemblies
    $comments.Add([PSCustomObject]@{ Type="success"
        Message="SMO assemblies loaded successfully." })
} catch { Write-Error $_.Exception.Message; exit 1 }

# 2 — Connect
Write-Host "`n[2/4] Establishing connections..." -ForegroundColor Yellow
$srcCred = $null; $tgtCred = $null
if (-not $UseWindowsAuth) {
    $srcCred = if ($null -ne $SourceCredential) { $SourceCredential } else {
        Get-Credential -Message "SQL credentials for SOURCE: $SourceServer" }
    $tgtCred = if ($null -ne $TargetCredential) { $TargetCredential } else {
        Get-Credential -Message "SQL credentials for TARGET: $TargetServer" }
}

$srcSmo = Connect-SqlServer -ServerName $SourceServer `
          -Credential $srcCred -WindowsAuth $UseWindowsAuth.IsPresent
$tgtSmo = Connect-SqlServer -ServerName $TargetServer `
          -Credential $tgtCred -WindowsAuth $UseWindowsAuth.IsPresent

if ($null -eq $srcSmo) {
    $comments.Add([PSCustomObject]@{Type="error";Message="Failed to connect to source: $SourceServer"})
    Write-Error "Aborting — source connection failed."; exit 1 }
if ($null -eq $tgtSmo) {
    $comments.Add([PSCustomObject]@{Type="error";Message="Failed to connect to target: $TargetServer"})
    Write-Error "Aborting — target connection failed."; exit 1 }

$comments.Add([PSCustomObject]@{ Type="info"
    Message="Source: $SourceServer — SQL Server $($srcSmo.VersionString), $($srcSmo.Edition)." })
$comments.Add([PSCustomObject]@{ Type="info"
    Message="Target: $TargetServer — SQL Server $($tgtSmo.VersionString), $($tgtSmo.Edition)." })

if ($srcSmo.VersionMajor -ne $tgtSmo.VersionMajor) {
    $comments.Add([PSCustomObject]@{ Type="warning"
        Message="SQL Server major version mismatch — Source: $($srcSmo.VersionString) / " +
                "Target: $($tgtSmo.VersionString)." }) }

# 3 — Resolve DB list
Write-Host "`n[3/4] Resolving database pairs..." -ForegroundColor Yellow

function Resolve-DbList {
    param([Microsoft.SqlServer.Management.Smo.Server]$Smo,[string]$DbParam,[string]$Role)
    if ($DbParam -eq "All") {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($db in $Smo.Databases) {
            if ((-not $db.IsSystemObject) -and
                ($db.Status -eq [Microsoft.SqlServer.Management.Smo.DatabaseStatus]::Normal)) {
                $names.Add($db.Name) } }
        $sorted = $names | Sort-Object
        Write-Host ("  $Role 'All': found {0} user database(s) on {1}" -f
            $names.Count, $Smo.Name) -ForegroundColor White
        return [string[]]$sorted
    }
    $found = $false
    foreach ($db in $Smo.Databases) { if ($db.Name -eq $DbParam) { $found=$true; break } }
    if (-not $found) { throw "Database '$DbParam' not found on $($Smo.Name)." }
    return [string[]]@($DbParam)
}

try {
    [string[]]$srcDbs = @(Resolve-DbList -Smo $srcSmo -DbParam $SourceDatabase -Role "Source")
    [string[]]$tgtDbs = @(Resolve-DbList -Smo $tgtSmo -DbParam $TargetDatabase -Role "Target")
} catch {
    $comments.Add([PSCustomObject]@{Type="error";Message=$_.Exception.Message})
    Write-Error $_.Exception.Message; exit 1 }

$pairs = [System.Collections.Generic.List[PSCustomObject]]::new()
if ($SourceDatabase -eq "All" -and $TargetDatabase -eq "All") {
    $all  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $sSet = [System.Collections.Generic.HashSet[string]]::new($srcDbs,[System.StringComparer]::OrdinalIgnoreCase)
    $tSet = [System.Collections.Generic.HashSet[string]]::new($tgtDbs,[System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $srcDbs) { [void]$all.Add($n) }
    foreach ($n in $tgtDbs) { [void]$all.Add($n) }
    foreach ($n in ($all | Sort-Object)) {
        $inS=$sSet.Contains($n); $inT=$tSet.Contains($n)
        if ($inS -and $inT) { $pairs.Add([PSCustomObject]@{Src=$n;Tgt=$n}) }
        elseif ($inS) {
            $m="'$n' on source ($SourceServer) but NOT on target ($TargetServer) — skipped."
            $comments.Add([PSCustomObject]@{Type="warning";Message=$m}); Write-Warning $m }
        else {
            $m="'$n' on target ($TargetServer) but NOT on source ($SourceServer) — skipped."
            $comments.Add([PSCustomObject]@{Type="warning";Message=$m}); Write-Warning $m }
    }
} elseif ($SourceDatabase -eq "All") {
    foreach ($n in $srcDbs) { $pairs.Add([PSCustomObject]@{Src=$n;Tgt=$TargetDatabase}) }
} elseif ($TargetDatabase -eq "All") {
    foreach ($n in $tgtDbs) { $pairs.Add([PSCustomObject]@{Src=$SourceDatabase;Tgt=$n}) }
} else {
    $pairs.Add([PSCustomObject]@{Src=$SourceDatabase;Tgt=$TargetDatabase}) }

if ($pairs.Count -eq 0) { Write-Warning "No comparable database pairs found."; exit 0 }

# 4 — Compare
Write-Host "`n[4/4] Comparing sys.master_files and generating report..." -ForegroundColor Yellow
$allComparisons = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($pair in $pairs) {
    Write-Host ("  Comparing  [{0}]  vs  [{1}] ..." -f $pair.Src,$pair.Tgt) -ForegroundColor White

    [PSCustomObject[]]$srcFiles = @(Get-MasterFileProperties -SmoServer $srcSmo -DatabaseName $pair.Src)
    [PSCustomObject[]]$tgtFiles = @(Get-MasterFileProperties -SmoServer $tgtSmo -DatabaseName $pair.Tgt)

    if ($srcFiles.Count -eq 0) {
        $comments.Add([PSCustomObject]@{Type="error"
            Message="No master_files data for '$($pair.Src)' on $SourceServer — skipped."})
        Write-Warning "  Skipped '$($pair.Src)' — no source data."; continue }
    if ($tgtFiles.Count -eq 0) {
        $comments.Add([PSCustomObject]@{Type="error"
            Message="No master_files data for '$($pair.Tgt)' on $TargetServer — skipped."})
        Write-Warning "  Skipped '$($pair.Tgt)' — no target data."; continue }

    $cmp = Compare-DatabaseFiles `
        -SourceFiles  $srcFiles  -TargetFiles  $tgtFiles `
        -SourceDbName $pair.Src  -TargetDbName $pair.Tgt

    if ($cmp.TotalDiffs -gt 0) {
        $diffFiles = ($cmp.FileResults | Where-Object { $_.DiffCount -gt 0 } |
                      Select-Object -ExpandProperty LogicalName) -join ", "
        $comments.Add([PSCustomObject]@{Type="warning"
            Message="$($pair.Src) — $($cmp.TotalDiffs) difference(s) across file(s): $diffFiles"})
        if ($cmp.MissingOnTarget.Count -gt 0) {
            $comments.Add([PSCustomObject]@{Type="warning"
                Message="$($pair.Src): File(s) present on SOURCE but missing on TARGET: $($cmp.MissingOnTarget -join ', ')"}) }
        if ($cmp.MissingOnSource.Count -gt 0) {
            $comments.Add([PSCustomObject]@{Type="warning"
                Message="$($pair.Src): File(s) present on TARGET but missing on SOURCE: $($cmp.MissingOnSource -join ', ')"}) }
        Write-Host "    $($cmp.TotalDiffs) difference(s) found across $($cmp.FileResults.Count) file(s)" -ForegroundColor Yellow
    } else {
        $comments.Add([PSCustomObject]@{Type="success"
            Message="$($pair.Src) — all $($cmp.FileResults.Count) file(s) are identical on both servers."})
        Write-Host "    All files match" -ForegroundColor Green }

    $allComparisons.Add($cmp)
}

$reportPath = New-HtmlReport `
    -SourceServerName $SourceServer  -TargetServerName $TargetServer `
    -SourceSmo        $srcSmo        -TargetSmo        $tgtSmo       `
    -ComparisonList   $allComparisons -Comments        $comments      `
    -ReportOutputPath $OutputPath    -Version          $ScriptVersion

if ($null -ne $reportPath) {
    $finalDiffs = 0; foreach ($c in $allComparisons) { $finalDiffs += $c.TotalDiffs }
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host ("  Done!  DBs compared: {0}  |  Total diffs: {1}" -f
        $allComparisons.Count, $finalDiffs) `
        -ForegroundColor $(if ($finalDiffs -gt 0) {"Yellow"} else {"Green"})
    Write-Host "  Report: $reportPath" -ForegroundColor Green
    Write-Host "============================================`n" -ForegroundColor Cyan
    try { Start-Process $reportPath } catch { }
}
}

Invoke-Main
#endregion
