#Requires -Version 5.1
<#
.SYNOPSIS
    Compares database properties between two SQL Server instances using SMO.

.DESCRIPTION
    Connects to source and target SQL Server instances, retrieves database
    properties via SMO and sys.databases, and generates a styled HTML comparison report.

.PARAMETER SourceServer
    Name or IP of the source SQL Server instance.

.PARAMETER TargetServer
    Name or IP of the target SQL Server instance.

.PARAMETER SourceDatabase
    Source database name, or "All" to compare every user database on the source.

.PARAMETER TargetDatabase
    Target database name, or "All" to compare every user database on the target.

.PARAMETER OutputPath
    Folder where the HTML report is saved. Defaults to the current directory.

.PARAMETER UseWindowsAuth
    Switch to use Windows Authentication (default). Omit to be prompted for SQL credentials.

.PARAMETER SourceCredential
    PSCredential for SQL Authentication on the source server (optional).

.PARAMETER TargetCredential
    PSCredential for SQL Authentication on the target server (optional).

.EXAMPLE
    .\Compare-SqlDatabases.ps1 -SourceServer "SQL01" -TargetServer "SQL02" `
        -SourceDatabase "All" -TargetDatabase "All"

.EXAMPLE
    .\Compare-SqlDatabases.ps1 -SourceServer "SQL01" -TargetServer "SQL02" `
        -SourceDatabase "AdventureWorks" -TargetDatabase "AdventureWorks" `
        -UseWindowsAuth
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true,  HelpMessage = "Source SQL Server instance name or IP")]
    [string]$SourceServer,

    [Parameter(Mandatory = $true,  HelpMessage = "Target SQL Server instance name or IP")]
    [string]$TargetServer,

    [Parameter(Mandatory = $true,  HelpMessage = "Source database name or 'All'")]
    [string]$SourceDatabase,

    [Parameter(Mandatory = $true,  HelpMessage = "Target database name or 'All'")]
    [string]$TargetDatabase,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [switch]$UseWindowsAuth,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$SourceCredential,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$TargetCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
#region  ASSEMBLY LOADER
# ---------------------------------------------------------------------------
function Import-SmoAssemblies {
    <#
    .SYNOPSIS Loads SMO assemblies, preferring the SqlServer module, with fallback to GAC.
    #>
    $requiredTypes = @(
        "Microsoft.SqlServer.Management.Smo.Server",
        "Microsoft.SqlServer.Management.Common.ServerConnection"
    )

    # Check if already loaded
    $alreadyLoaded = $true
    foreach ($typeName in $requiredTypes) {
        try { $null = [type]$typeName } catch { $alreadyLoaded = $false; break }
    }
    if ($alreadyLoaded) { Write-Verbose "SMO assemblies already loaded."; return }

    # Attempt 1: SqlServer module (preferred — ships with up-to-date SMO)
    if (Get-Module -ListAvailable -Name "SqlServer" -ErrorAction SilentlyContinue) {
        try {
            Import-Module SqlServer -DisableNameChecking -ErrorAction Stop
            Write-Verbose "SMO loaded via SqlServer module."
            return
        } catch {
            Write-Warning "SqlServer module found but failed to import: $($_.Exception.Message)"
        }
    }

    # Attempt 2: SQLPS module
    if (Get-Module -ListAvailable -Name "SQLPS" -ErrorAction SilentlyContinue) {
        try {
            Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
            Write-Verbose "SMO loaded via SQLPS module."
            return
        } catch {
            Write-Warning "SQLPS module found but failed to import: $($_.Exception.Message)"
        }
    }

    # Attempt 3: LoadWithPartialName (legacy fallback — deprecated but functional)
    $assemblyNames = @(
        "Microsoft.SqlServer.Smo",
        "Microsoft.SqlServer.ConnectionInfo",
        "Microsoft.SqlServer.Management.Sdk.Sfc",
        "Microsoft.SqlServer.SqlEnum"
    )
    foreach ($asm in $assemblyNames) {
        try {
            [System.Reflection.Assembly]::LoadWithPartialName($asm) | Out-Null
            Write-Verbose "Loaded (GAC fallback): $asm"
        } catch {
            Write-Warning "Could not load assembly '$asm': $($_.Exception.Message)"
        }
    }

    # Final validation
    foreach ($typeName in $requiredTypes) {
        try { $null = [type]$typeName }
        catch {
            throw ("SMO type '$typeName' is unavailable. " +
                   "Install SQL Server Management Studio (SSMS) or the SqlServer PowerShell module " +
                   "('Install-Module SqlServer') and re-run the script.")
        }
    }
    Write-Verbose "SMO assemblies verified."
}
#endregion

# ---------------------------------------------------------------------------
#region  CONNECTION FACTORY
# ---------------------------------------------------------------------------
function Connect-SqlServer {
    <#
    .SYNOPSIS Creates and returns an SMO Server object for the given instance.
    #>
    param(
        [Parameter(Mandatory)] [string]$ServerName,
        [System.Management.Automation.PSCredential]$Credential = $null,
        [bool]$WindowsAuth = $true
    )

    Write-Host "  Connecting to: $ServerName ..." -ForegroundColor Cyan

    try {
        $conn = New-Object Microsoft.SqlServer.Management.Common.ServerConnection
        $conn.ServerInstance   = $ServerName
        $conn.ConnectTimeout   = 30
        $conn.StatementTimeout = 120

        if ($WindowsAuth -or ($null -eq $Credential)) {
            $conn.LoginSecure = $true
            Write-Verbose "  Auth method: Windows Integrated"
        } else {
            $conn.LoginSecure   = $false
            $conn.Login         = $Credential.UserName
            $conn.SecurePassword = $Credential.Password
            Write-Verbose "  Auth method: SQL Login ($($Credential.UserName))"
        }

        $smo = New-Object Microsoft.SqlServer.Management.Smo.Server($conn)

        # Force a round-trip to verify the connection is live
        $versionCheck = $smo.VersionString
        if ([string]::IsNullOrWhiteSpace($versionCheck)) {
            throw "Connected but version string is empty — server may be unavailable."
        }

        Write-Host "  OK  $ServerName  [SQL Server $versionCheck  |  Edition: $($smo.Edition)]" `
            -ForegroundColor Green
        return $smo

    } catch [Microsoft.SqlServer.Management.Common.ConnectionFailureException] {
        Write-Error ("Connection failure for '$ServerName': $($_.Exception.Message) " +
                     "— Verify the server name, firewall rules, and SQL Browser service.")
        return $null
    } catch {
        Write-Error "Unexpected error connecting to '$ServerName': $($_.Exception.Message)"
        return $null
    }
}
#endregion

# ---------------------------------------------------------------------------
#region  PROPERTY RETRIEVAL
# ---------------------------------------------------------------------------
function Get-DatabaseProperties {
    <#
    .SYNOPSIS
        Queries sys.databases and sys.master_files on the given SMO Server and
        returns one [PSCustomObject] per matching database.
    #>
    param(
        [Parameter(Mandatory)] [Microsoft.SqlServer.Management.Smo.Server]$SmoServer,
        [Parameter(Mandatory)] [string]$DatabaseName        # pass "All" to fetch all user DBs
    )

    # T-SQL — a single query covers all properties we want to compare
    $whereClause = if ($DatabaseName -eq "All") {
        "WHERE d.database_id > 4"           # exclude system DBs (master/tempdb/model/msdb)
    } else {
        "WHERE d.name = N'$($DatabaseName.Replace("'","''"))'"
    }

    $query = @"
SELECT
    d.name                              AS [DatabaseName],
    d.compatibility_level               AS [CompatibilityLevel],
    d.collation_name                    AS [Collation],
    d.recovery_model_desc               AS [RecoveryModel],
    d.state_desc                        AS [State],
    d.user_access_desc                  AS [UserAccess],
    CAST(d.is_read_only        AS INT)  AS [ReadOnly],
    CAST(d.is_auto_close_on    AS INT)  AS [AutoClose],
    CAST(d.is_auto_shrink_on   AS INT)  AS [AutoShrink],
    CAST(d.is_auto_create_stats_on   AS INT) AS [AutoCreateStats],
    CAST(d.is_auto_update_stats_on   AS INT) AS [AutoUpdateStats],
    CAST(d.is_fulltext_enabled AS INT)  AS [FullTextEnabled],
    d.page_verify_option_desc           AS [PageVerify],
    d.log_reuse_wait_desc               AS [LogReuseWait],
    CAST(d.is_encrypted        AS INT)  AS [Encrypted],
    CAST(d.is_trustworthy_on   AS INT)  AS [Trustworthy],
    CAST(d.is_db_chaining_on   AS INT)  AS [DBChaining],
    CAST(d.is_broker_enabled   AS INT)  AS [BrokerEnabled],
    d.snapshot_isolation_state_desc     AS [SnapshotIsolation],
    CAST(d.is_read_committed_snapshot_on AS INT) AS [ReadCommittedSnapshot],
    CAST(d.is_ansi_null_default_on AS INT) AS [ANSINullDefault],
    CAST(d.is_ansi_nulls_on    AS INT)  AS [ANSINulls],
    CAST(d.is_ansi_padding_on  AS INT)  AS [ANSIPadding],
    CAST(d.is_ansi_warnings_on AS INT)  AS [ANSIWarnings],
    CAST(d.is_arithabort_on    AS INT)  AS [ArithAbort],
    CAST(d.is_concat_null_yields_null_on AS INT) AS [ConcatNullYieldsNull],
    CAST(d.is_numeric_roundabort_on AS INT) AS [NumericRoundAbort],
    CAST(d.is_quoted_identifier_on AS INT) AS [QuotedIdentifier],
    CAST(d.is_recursive_triggers_on AS INT) AS [RecursiveTriggers],
    CAST(d.is_cursor_close_on_commit_on AS INT) AS [CursorCloseOnCommit],
    CAST(d.is_local_cursor_default AS INT)  AS [LocalCursorDefault],
    CAST(d.is_parameterization_forced AS INT) AS [ForcedParameterization],
    d.create_date                       AS [CreateDate],
    CAST(ISNULL(
        (SELECT SUM(CAST(mf.size AS BIGINT)) * 8.0 / 1024
         FROM sys.master_files mf
         WHERE mf.database_id = d.database_id AND mf.type = 0), 0)
    AS DECIMAL(18,2))                   AS [DataSizeMB],
    CAST(ISNULL(
        (SELECT SUM(CAST(mf.size AS BIGINT)) * 8.0 / 1024
         FROM sys.master_files mf
         WHERE mf.database_id = d.database_id AND mf.type = 1), 0)
    AS DECIMAL(18,2))                   AS [LogSizeMB]
FROM sys.databases d
$whereClause
ORDER BY d.name;
"@

    try {
        $ds = $SmoServer.Databases["master"].ExecuteWithResults($query)

        if ($ds.Tables[0].Rows.Count -eq 0) {
            Write-Warning "No rows returned for database '$DatabaseName' on '$($SmoServer.Name)'."
            return @()
        }

        $output = @()
        foreach ($row in $ds.Tables[0].Rows) {
            $obj = [ordered]@{}
            foreach ($col in $ds.Tables[0].Columns) {
                $obj[$col.ColumnName] = $row[$col.ColumnName]
            }
            $output += [PSCustomObject]$obj
        }
        return $output

    } catch {
        Write-Error ("Failed to retrieve properties for '$DatabaseName' " +
                     "on '$($SmoServer.Name)': $($_.Exception.Message)")
        return $null
    }
}
#endregion

# ---------------------------------------------------------------------------
#region  PROPERTY COMPARISON ENGINE
# ---------------------------------------------------------------------------
# Properties treated as informational (displayed but not flagged as mismatches)
$script:InfoOnlyProperties = @(
    "DatabaseName", "CreateDate", "DataSizeMB", "LogSizeMB"
)

function Compare-DatabaseProperties {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$SourceProps,
        [Parameter(Mandatory)] [PSCustomObject]$TargetProps,
        [Parameter(Mandatory)] [string]$SourceDbName,
        [Parameter(Mandatory)] [string]$TargetDbName
    )

    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()
    $diffCount = 0

    # Union of all property names in source row
    $propNames = $SourceProps.PSObject.Properties.Name

    foreach ($prop in $propNames) {
        $srcVal = if ($SourceProps.PSObject.Properties[$prop]) { "$($SourceProps.$prop)" } else { "N/A" }
        $tgtVal = if ($TargetProps.PSObject.Properties[$prop]) { "$($TargetProps.$prop)" } else { "N/A" }

        $isInfo  = $prop -in $script:InfoOnlyProperties
        $isDiff  = (-not $isInfo) -and ($srcVal -ne $tgtVal)
        if ($isDiff) { $diffCount++ }

        $rows.Add([PSCustomObject]@{
            Property   = $prop
            Source     = $srcVal
            Target     = $tgtVal
            IsDiff     = $isDiff
            IsInfoOnly = $isInfo
        })
    }

    return [PSCustomObject]@{
        SourceDatabase = $SourceDbName
        TargetDatabase = $TargetDbName
        Rows           = $rows
        DiffCount      = $diffCount
    }
}
#endregion

# ---------------------------------------------------------------------------
#region  HTML REPORT GENERATOR
# ---------------------------------------------------------------------------
function New-HtmlReport {
    param(
        [string]$SourceServer,
        [string]$TargetServer,
        [array] $ComparisonData,
        [System.Collections.Generic.List[PSCustomObject]]$Comments,
        [string]$OutputPath
    )

    $reportDate  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $reportFile  = Join-Path $OutputPath ("SqlDbComparison_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".html")
    $totalDiffs  = ($ComparisonData | Measure-Object -Property DiffCount -Sum).Sum
    $dbCount     = $ComparisonData.Count
    $dbsWithDiff = ($ComparisonData | Where-Object { $_.DiffCount -gt 0 }).Count
    $dbsClean    = $dbCount - $dbsWithDiff

    # ---- CSS + skeleton -------------------------------------------------------
    $css = @'
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:#f0f2f5;color:#2d3748;font-size:14px;line-height:1.5}
.header{background:linear-gradient(135deg,#1a365d 0%,#2b6cb0 100%);color:#fff;padding:28px 40px;display:flex;justify-content:space-between;align-items:center;box-shadow:0 4px 12px rgba(0,0,0,.25)}
.header h1{font-size:22px;font-weight:700;letter-spacing:.4px}
.header .sub{font-size:12px;opacity:.8;margin-top:5px}
.header .meta{text-align:right;font-size:12px;opacity:.85;line-height:1.8}
.srv-banner{display:flex}
.srv-card{flex:1;padding:16px 32px;display:flex;align-items:center;gap:14px;color:#fff}
.srv-card.src{background:#1a4731;border-right:3px solid #0d1f15}
.srv-card.tgt{background:#1a3a5c}
.srv-icon{width:42px;height:42px;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:22px}
.srv-card.src .srv-icon{background:#276749}
.srv-card.tgt .srv-icon{background:#2b4c7e}
.srv-lbl{font-size:10px;text-transform:uppercase;letter-spacing:1.2px;opacity:.7}
.srv-name{font-size:17px;font-weight:700;margin-top:2px}
.summary{background:#fff;padding:22px 40px;border-bottom:1px solid #e2e8f0}
.summary h2{font-size:13px;font-weight:700;text-transform:uppercase;letter-spacing:1px;color:#4a5568;margin-bottom:14px}
.cards{display:flex;gap:14px;flex-wrap:wrap}
.card{flex:1;min-width:150px;padding:16px 18px;border-radius:10px}
.card.blue  {background:#ebf8ff;border-left:4px solid #3182ce}
.card.green {background:#f0fff4;border-left:4px solid #38a169}
.card.red   {background:#fff5f5;border-left:4px solid #e53e3e}
.card.orange{background:#fffaf0;border-left:4px solid #dd6b20}
.card .lbl{font-size:10px;text-transform:uppercase;letter-spacing:1px;color:#718096}
.card .val{font-size:30px;font-weight:800;margin-top:4px}
.card.blue  .val{color:#2b6cb0}
.card.green .val{color:#276749}
.card.red   .val{color:#c53030}
.card.orange .val{color:#c05621}
.content{padding:28px 40px}
.db-block{background:#fff;border-radius:12px;box-shadow:0 1px 6px rgba(0,0,0,.08);margin-bottom:26px;overflow:hidden}
.db-head{padding:14px 22px;display:flex;justify-content:space-between;align-items:center;background:#f7fafc;border-bottom:1px solid #e2e8f0}
.db-head h3{font-size:15px;font-weight:700;color:#2d3748;display:flex;align-items:center;gap:9px}
.db-meta{font-size:11px;color:#718096;margin-right:8px}
.badge{padding:4px 12px;border-radius:20px;font-size:11px;font-weight:700}
.badge.diff{background:#fed7d7;color:#c53030}
.badge.ok  {background:#c6f6d5;color:#276749}
table{width:100%;border-collapse:collapse}
thead th{padding:10px 18px;font-size:11px;text-transform:uppercase;letter-spacing:.8px;font-weight:700;background:#edf2f7;color:#4a5568;text-align:left;border-bottom:2px solid #cbd5e0}
thead th:first-child{width:28%}
thead th:nth-child(2),thead th:nth-child(3){width:31%}
thead th:last-child{width:10%;text-align:center}
tbody tr{border-bottom:1px solid #e2e8f0}
tbody tr:last-child{border-bottom:none}
tbody tr:hover{background:#f7fafc}
td{padding:9px 18px;vertical-align:middle}
.pn{font-weight:600;color:#4a5568;font-size:13px}
.pv{font-family:'Courier New',monospace;font-size:12px}
.r-diff td{background:#fff5f5!important}
.r-diff td:first-child{border-left:3px solid #e53e3e}
.r-diff .pn{color:#c53030}
.r-info td{background:#f7fafc!important}
.r-info td:first-child{border-left:3px solid #a0aec0}
.si{text-align:center;font-size:14px}
.v-ok  {color:#38a169}
.v-diff{color:#e53e3e;font-weight:700}
.v-info{color:#a0aec0;font-style:italic}
.sec-lbl{padding:7px 22px;background:#edf2f7;font-size:10px;text-transform:uppercase;letter-spacing:1.2px;color:#718096;font-weight:700}
.legend{display:flex;gap:18px;padding:10px 22px;background:#f7fafc;border-top:1px solid #e2e8f0;font-size:11px;color:#4a5568}
.ld{display:flex;align-items:center;gap:5px}
.dot{width:9px;height:9px;border-radius:50%;display:inline-block}
.dot.d{background:#e53e3e}.dot.m{background:#38a169}.dot.i{background:#a0aec0}
.cmts{background:#fff;border-radius:12px;box-shadow:0 1px 6px rgba(0,0,0,.08);margin-bottom:26px;overflow:hidden}
.cmts-head{padding:14px 22px;background:#fffbeb;border-bottom:1px solid #faf089;display:flex;align-items:center;gap:10px}
.cmts-head h3{font-size:15px;font-weight:700;color:#744210}
.cmts-body{padding:14px 22px}
.ci{display:flex;gap:12px;padding:9px 0;border-bottom:1px solid #e2e8f0;align-items:flex-start}
.ci:last-child{border-bottom:none}
.ci-ico{font-size:15px;flex-shrink:0;margin-top:2px}
.ct{display:inline-block;padding:2px 7px;border-radius:4px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;margin-right:6px}
.ct.warning{background:#fefcbf;color:#744210}
.ct.error  {background:#fed7d7;color:#c53030}
.ct.info   {background:#bee3f8;color:#2b6cb0}
.ct.success{background:#c6f6d5;color:#276749}
.cm{font-size:13px;color:#4a5568}
footer{text-align:center;padding:22px;color:#a0aec0;font-size:11px;border-top:1px solid #e2e8f0;background:#fff}
'@

    # ---- Open HTML ------------------------------------------------------------
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("<!DOCTYPE html>")
    [void]$sb.AppendLine("<html lang='en'><head>")
    [void]$sb.AppendLine("<meta charset='UTF-8'>")
    [void]$sb.AppendLine("<meta name='viewport' content='width=device-width,initial-scale=1.0'>")
    [void]$sb.AppendLine("<title>SQL Database Comparison Report</title>")
    [void]$sb.AppendLine("<style>$css</style></head><body>")

    # ---- Header ---------------------------------------------------------------
    [void]$sb.AppendLine(@"
<div class='header'>
  <div>
    <h1>&#128202; SQL Server Database Comparison Report</h1>
    <div class='sub'>Property-level comparison &bull; SMO + sys.databases</div>
  </div>
  <div class='meta'>
    <div>&#128197; $reportDate</div>
    <div>Databases compared: <strong>$dbCount</strong></div>
  </div>
</div>
"@)

    # ---- Server banner --------------------------------------------------------
    [void]$sb.AppendLine(@"
<div class='srv-banner'>
  <div class='srv-card src'>
    <div class='srv-icon'>&#128190;</div>
    <div><div class='srv-lbl'>Source Server</div><div class='srv-name'>$SourceServer</div></div>
  </div>
  <div class='srv-card tgt'>
    <div class='srv-icon'>&#127919;</div>
    <div><div class='srv-lbl'>Target Server</div><div class='srv-name'>$TargetServer</div></div>
  </div>
</div>
"@)

    # ---- Summary cards --------------------------------------------------------
    [void]$sb.AppendLine(@"
<div class='summary'>
  <h2>&#128200; Comparison Summary</h2>
  <div class='cards'>
    <div class='card blue' ><div class='lbl'>Databases Compared</div><div class='val'>$dbCount</div></div>
    <div class='card green'><div class='lbl'>Fully Matching</div><div class='val'>$dbsClean</div></div>
    <div class='card red'  ><div class='lbl'>Databases with Diffs</div><div class='val'>$dbsWithDiff</div></div>
    <div class='card orange'><div class='lbl'>Total Property Diffs</div><div class='val'>$totalDiffs</div></div>
  </div>
</div>
<div class='content'>
"@)

    # ---- Per-database blocks --------------------------------------------------
    foreach ($comp in $ComparisonData) {
        $badgeCls  = if ($comp.DiffCount -gt 0) { "diff" } else { "ok" }
        $badgeTxt  = if ($comp.DiffCount -gt 0) { "&#9888; $($comp.DiffCount) Difference(s)" } else { "&#10003; Identical" }
        $dbLabel   = if ($comp.SourceDatabase -eq $comp.TargetDatabase) {
            $comp.SourceDatabase
        } else {
            "$($comp.SourceDatabase) &#8594; $($comp.TargetDatabase)"
        }

        [void]$sb.AppendLine(@"
<div class='db-block'>
  <div class='db-head'>
    <h3>&#128451; $dbLabel</h3>
    <div style='display:flex;align-items:center;gap:10px'>
      <span class='db-meta'>$($comp.Rows.Count) properties</span>
      <span class='badge $badgeCls'>$badgeTxt</span>
    </div>
  </div>
  <table>
    <thead>
      <tr>
        <th>Property</th>
        <th>&#128190; Source &mdash; $($comp.SourceDatabase)</th>
        <th>&#127919; Target &mdash; $($comp.TargetDatabase)</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
"@)

        # Informational rows first
        $infoRows    = $comp.Rows | Where-Object { $_.IsInfoOnly }
        $configRows  = $comp.Rows | Where-Object { -not $_.IsInfoOnly }

        if ($infoRows) {
            [void]$sb.AppendLine("<tr><td colspan='4' class='sec-lbl'>&#128202; Informational</td></tr>")
            foreach ($r in $infoRows) {
                [void]$sb.AppendLine(@"
      <tr class='r-info'>
        <td><span class='pn'>$($r.Property)</span></td>
        <td><span class='pv v-info'>$($r.Source)</span></td>
        <td><span class='pv v-info'>$($r.Target)</span></td>
        <td class='si'><span class='v-info'>&#8213;</span></td>
      </tr>
"@)
            }
        }

        if ($configRows) {
            [void]$sb.AppendLine("<tr><td colspan='4' class='sec-lbl'>&#9881; Configuration Properties</td></tr>")
            foreach ($r in $configRows) {
                if ($r.IsDiff) {
                    [void]$sb.AppendLine(@"
      <tr class='r-diff'>
        <td><span class='pn'>$($r.Property)</span></td>
        <td><span class='pv v-diff'>$($r.Source)</span></td>
        <td><span class='pv v-diff'>$($r.Target)</span></td>
        <td class='si'><span class='v-diff'>&#10007;</span></td>
      </tr>
"@)
                } else {
                    [void]$sb.AppendLine(@"
      <tr>
        <td><span class='pn'>$($r.Property)</span></td>
        <td><span class='pv'>$($r.Source)</span></td>
        <td><span class='pv'>$($r.Target)</span></td>
        <td class='si'><span class='v-ok'>&#10003;</span></td>
      </tr>
"@)
                }
            }
        }

        [void]$sb.AppendLine(@"
    </tbody>
  </table>
  <div class='legend'>
    <span class='ld'><span class='dot d'></span> Mismatch</span>
    <span class='ld'><span class='dot m'></span> Match</span>
    <span class='ld'><span class='dot i'></span> Informational (not compared)</span>
  </div>
</div>
"@)
    }

    # ---- Comments section ----------------------------------------------------
    if ($Comments -and $Comments.Count -gt 0) {
        [void]$sb.AppendLine(@"
<div class='cmts'>
  <div class='cmts-head'><span style='font-size:20px'>&#128204;</span>
    <h3>Notes &amp; Observations ($($Comments.Count))</h3>
  </div>
  <div class='cmts-body'>
"@)
        foreach ($c in $Comments) {
            $ico = switch ($c.Type) {
                "error"   { "&#10060;" }
                "warning" { "&#9888;" }
                "info"    { "&#8505;" }
                "success" { "&#10004;" }
                default   { "&#8226;" }
            }
            [void]$sb.AppendLine(@"
    <div class='ci'>
      <span class='ci-ico'>$ico</span>
      <div>
        <span class='ct $($c.Type)'>$($c.Type)</span>
        <span class='cm'>$($c.Message)</span>
      </div>
    </div>
"@)
        }
        [void]$sb.AppendLine("  </div></div>")
    }

    # ---- Footer --------------------------------------------------------------
    [void]$sb.AppendLine(@"
</div>
<footer>
  Generated by <strong>Compare-SqlDatabases.ps1</strong> &bull; $reportDate &bull;
  <strong>$SourceServer</strong> &rarr; <strong>$TargetServer</strong>
</footer>
</body></html>
"@)

    # ---- Write file ----------------------------------------------------------
    try {
        [System.IO.File]::WriteAllText($reportFile, $sb.ToString(),
            [System.Text.Encoding]::UTF8)
        Write-Host "`n  Report saved: $reportFile" -ForegroundColor Green
        return $reportFile
    } catch {
        Write-Error "Failed to save HTML report to '$reportFile': $($_.Exception.Message)"
        return $null
    }
}
#endregion

# ---------------------------------------------------------------------------
#region  MAIN ORCHESTRATION
# ---------------------------------------------------------------------------
function Invoke-Main {
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host "   SQL Server Database Comparison Tool"      -ForegroundColor Cyan
    Write-Host "============================================`n" -ForegroundColor Cyan

    $comments = [System.Collections.Generic.List[PSCustomObject]]::new()

    # -- Step 1: Load SMO ------------------------------------------------------
    Write-Host "[1/4] Loading SMO assemblies..." -ForegroundColor Yellow
    try {
        Import-SmoAssemblies
        $comments.Add([PSCustomObject]@{ Type="success"; Message="SMO assemblies loaded successfully." })
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }

    # -- Step 2: Connect -------------------------------------------------------
    Write-Host "`n[2/4] Establishing connections..." -ForegroundColor Yellow

    $srcCred = if ((-not $UseWindowsAuth) -and ($null -eq $SourceCredential)) {
        Get-Credential -Message "SQL credentials for SOURCE: $SourceServer"
    } else { $SourceCredential }

    $tgtCred = if ((-not $UseWindowsAuth) -and ($null -eq $TargetCredential)) {
        Get-Credential -Message "SQL credentials for TARGET: $TargetServer"
    } else { $TargetCredential }

    $srcSmo = Connect-SqlServer -ServerName $SourceServer -Credential $srcCred -WindowsAuth $UseWindowsAuth.IsPresent
    $tgtSmo = Connect-SqlServer -ServerName $TargetServer -Credential $tgtCred -WindowsAuth $UseWindowsAuth.IsPresent

    if ($null -eq $srcSmo) {
        $comments.Add([PSCustomObject]@{Type="error";Message="Failed to connect to source server: $SourceServer"})
        Write-Error "Aborting — source connection failed."
        exit 1
    }
    if ($null -eq $tgtSmo) {
        $comments.Add([PSCustomObject]@{Type="error";Message="Failed to connect to target server: $TargetServer"})
        Write-Error "Aborting — target connection failed."
        exit 1
    }

    $comments.Add([PSCustomObject]@{Type="info";
        Message="Source: $SourceServer — SQL Server $($srcSmo.VersionString), Edition: $($srcSmo.Edition)"})
    $comments.Add([PSCustomObject]@{Type="info";
        Message="Target: $TargetServer — SQL Server $($tgtSmo.VersionString), Edition: $($tgtSmo.Edition)"})

    if ($srcSmo.VersionMajor -ne $tgtSmo.VersionMajor) {
        $comments.Add([PSCustomObject]@{Type="warning";
            Message=("SQL Server version mismatch — Source: $($srcSmo.VersionString) / " +
                     "Target: $($tgtSmo.VersionString). Some property comparisons may be unreliable.")})
    }

    # -- Step 3: Determine DB pairs -------------------------------------------
    Write-Host "`n[3/4] Resolving database pairs..." -ForegroundColor Yellow

    function Resolve-DbList {
        param(
            [Microsoft.SqlServer.Management.Smo.Server]$Smo,
            [string]$DbParam,
            [string]$Role
        )
        if ($DbParam -eq "All") {
            $list = $Smo.Databases |
                Where-Object { -not $_.IsSystemObject -and $_.Status -eq "Normal" } |
                Select-Object -ExpandProperty Name | Sort-Object
            Write-Host "  $Role 'All': found $($list.Count) user database(s) on $($Smo.Name)" -ForegroundColor White
            return $list
        }
        if (-not $Smo.Databases[$DbParam]) {
            throw "Database '$DbParam' not found on $($Smo.Name)."
        }
        return @($DbParam)
    }

    try {
        $srcDbs = Resolve-DbList -Smo $srcSmo -DbParam $SourceDatabase -Role "Source"
        $tgtDbs = Resolve-DbList -Smo $tgtSmo -DbParam $TargetDatabase -Role "Target"
    } catch {
        $comments.Add([PSCustomObject]@{Type="error";Message=$_.Exception.Message})
        Write-Error $_.Exception.Message
        exit 1
    }

    # Build pairs
    $pairs = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($SourceDatabase -eq "All" -and $TargetDatabase -eq "All") {
        $allNames = ($srcDbs + $tgtDbs) | Select-Object -Unique | Sort-Object
        foreach ($n in $allNames) {
            $inS = $srcDbs -contains $n
            $inT = $tgtDbs -contains $n
            if ($inS -and $inT) {
                $pairs.Add([PSCustomObject]@{ Src=$n; Tgt=$n })
            } elseif ($inS) {
                $comments.Add([PSCustomObject]@{Type="warning";
                    Message="'$n' exists on source but NOT on target — skipped."})
            } else {
                $comments.Add([PSCustomObject]@{Type="warning";
                    Message="'$n' exists on target but NOT on source — skipped."})
            }
        }
    } elseif ($SourceDatabase -eq "All") {
        foreach ($n in $srcDbs) { $pairs.Add([PSCustomObject]@{ Src=$n; Tgt=$TargetDatabase }) }
    } elseif ($TargetDatabase -eq "All") {
        foreach ($n in $tgtDbs) { $pairs.Add([PSCustomObject]@{ Src=$SourceDatabase; Tgt=$n }) }
    } else {
        $pairs.Add([PSCustomObject]@{ Src=$SourceDatabase; Tgt=$TargetDatabase })
    }

    if ($pairs.Count -eq 0) {
        Write-Warning "No comparable database pairs found. Check your inputs."
        exit 0
    }

    # -- Step 4: Compare -------------------------------------------------------
    Write-Host "`n[4/4] Comparing properties and generating report..." -ForegroundColor Yellow

    $allComparisons = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($pair in $pairs) {
        Write-Host "  Comparing  [$($pair.Src)]  vs  [$($pair.Tgt)] ..." -ForegroundColor White

        $srcProps = Get-DatabaseProperties -SmoServer $srcSmo -DatabaseName $pair.Src
        $tgtProps = Get-DatabaseProperties -SmoServer $tgtSmo -DatabaseName $pair.Tgt

        if ((-not $srcProps) -or $srcProps.Count -eq 0) {
            $comments.Add([PSCustomObject]@{Type="error";
                Message="Could not retrieve properties for '$($pair.Src)' on $SourceServer."})
            continue
        }
        if ((-not $tgtProps) -or $tgtProps.Count -eq 0) {
            $comments.Add([PSCustomObject]@{Type="error";
                Message="Could not retrieve properties for '$($pair.Tgt)' on $TargetServer."})
            continue
        }

        $cmp = Compare-DatabaseProperties `
            -SourceProps  $srcProps[0] `
            -TargetProps  $tgtProps[0] `
            -SourceDbName $pair.Src    `
            -TargetDbName $pair.Tgt

        if ($cmp.DiffCount -gt 0) {
            $diffProps = ($cmp.Rows | Where-Object { $_.IsDiff } | Select-Object -ExpandProperty Property) -join ", "
            $comments.Add([PSCustomObject]@{Type="warning";
                Message="'$($pair.Src)' — $($cmp.DiffCount) difference(s) in: $diffProps"})
            Write-Host "    $($cmp.DiffCount) difference(s) found" -ForegroundColor Yellow
        } else {
            $comments.Add([PSCustomObject]@{Type="success";
                Message="'$($pair.Src)' — all compared properties are identical."})
            Write-Host "    All properties match" -ForegroundColor Green
        }

        $allComparisons.Add($cmp)
    }

    # -- Generate HTML ---------------------------------------------------------
    $reportPath = New-HtmlReport `
        -SourceServer    $SourceServer `
        -TargetServer    $TargetServer `
        -ComparisonData  $allComparisons `
        -Comments        $comments `
        -OutputPath      $OutputPath

    if ($reportPath) {
        $total = ($allComparisons | Measure-Object -Property DiffCount -Sum).Sum
        Write-Host "`n============================================" -ForegroundColor Cyan
        Write-Host "  Done!  Total differences: $total"           -ForegroundColor $(if ($total -gt 0) {"Yellow"} else {"Green"})
        Write-Host "  Report: $reportPath"                        -ForegroundColor Green
        Write-Host "============================================`n" -ForegroundColor Cyan
        try { Start-Process $reportPath } catch { <# non-fatal #> }
    }
}

Invoke-Main
#endregion
