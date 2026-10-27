#Requires -Version 5.1
<#
.SYNOPSIS
    Compares database properties between two SQL Server instances using SMO.

.DESCRIPTION
    Connects to source and target SQL Server instances, retrieves database
    properties via SMO and sys.databases, and generates a styled HTML comparison report.

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
    .\Compare-SqlDatabases.ps1 -SourceServer "SQL01,1733" -TargetServer "SQL02,1733" `
        -SourceDatabase "All" -TargetDatabase "All" -UseWindowsAuth
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$SourceServer,
    [Parameter(Mandatory = $true)]  [string]$TargetServer,
    [Parameter(Mandatory = $true)]  [string]$SourceDatabase,
    [Parameter(Mandatory = $true)]  [string]$TargetDatabase,
    [Parameter(Mandatory = $false)] [string]$OutputPath = (Get-Location).Path,
    [Parameter(Mandatory = $false)] [switch]$UseWindowsAuth,
    [Parameter(Mandatory = $false)] [System.Management.Automation.PSCredential]$SourceCredential,
    [Parameter(Mandatory = $false)] [System.Management.Automation.PSCredential]$TargetCredential
)

# Set-StrictMode -Version Latest intentionally omitted:
# It raises PropertyNotFoundStrict on .Count when a single PSCustomObject is
# returned from a function and PowerShell unrolls the single-item array.
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
#region  HTML ENCODING HELPER
# ---------------------------------------------------------------------------
function ConvertTo-HtmlEncoded {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $Text = $Text.Replace('&',  '&amp;')
    $Text = $Text.Replace('<',  '&lt;')
    $Text = $Text.Replace('>',  '&gt;')
    $Text = $Text.Replace('"',  '&quot;')
    $Text = $Text.Replace("'",  '&#39;')
    return $Text
}
#endregion

# ---------------------------------------------------------------------------
#region  PROPERTY EXCLUSION / INFO LISTS
# ---------------------------------------------------------------------------
# Excluded: .NET System.Array artifact properties that appear when the caller
# accidentally receives the whole inner PSCustomObject[] instead of a single row.
$script:ExcludeProperties = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
@("Count","Length","LongLength","Rank","SyncRoot",
  "IsReadOnly","IsFixedSize","IsSynchronized") |
    ForEach-Object { [void]$script:ExcludeProperties.Add($_) }

# Shown in the report but excluded from the diff count.
$script:InfoOnlyProperties = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
@("DatabaseName","CreateDate","DataSizeMB","LogSizeMB") |
    ForEach-Object { [void]$script:InfoOnlyProperties.Add($_) }
#endregion

# ---------------------------------------------------------------------------
#region  SMO ASSEMBLY LOADER
# ---------------------------------------------------------------------------
function Import-SmoAssemblies {
    $smoLoaded = $false
    try {
        $null = [Microsoft.SqlServer.Management.Smo.Server]
        $null = [Microsoft.SqlServer.Management.Common.ServerConnection]
        $smoLoaded = $true
    } catch { $smoLoaded = $false }

    if ($smoLoaded) { Write-Verbose "SMO assemblies already loaded."; return }

    if (Get-Module -ListAvailable -Name "SqlServer" -ErrorAction SilentlyContinue) {
        try { Import-Module SqlServer -DisableNameChecking -ErrorAction Stop; return }
        catch { Write-Warning "SqlServer module failed: $($_.Exception.Message)" }
    }
    if (Get-Module -ListAvailable -Name "SQLPS" -ErrorAction SilentlyContinue) {
        try { Import-Module SQLPS -DisableNameChecking -ErrorAction Stop; return }
        catch { Write-Warning "SQLPS module failed: $($_.Exception.Message)" }
    }
    foreach ($asm in @("Microsoft.SqlServer.Smo","Microsoft.SqlServer.ConnectionInfo",
                        "Microsoft.SqlServer.Management.Sdk.Sfc","Microsoft.SqlServer.SqlEnum")) {
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

# ---------------------------------------------------------------------------
#region  CONNECTION FACTORY
# ---------------------------------------------------------------------------
function Connect-SqlServer {
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
        } else {
            $conn.LoginSecure    = $false
            $conn.Login          = $Credential.UserName
            $conn.SecurePassword = $Credential.Password
        }
        $smo = New-Object Microsoft.SqlServer.Management.Smo.Server($conn)
        $ver = $smo.VersionString
        if ([string]::IsNullOrWhiteSpace($ver)) {
            throw "Server returned empty version — instance may be unavailable."
        }
        Write-Host ("  OK  {0}  [SQL Server {1}  |  Edition: {2}]" -f
            $ServerName, $ver, $smo.Edition) -ForegroundColor Green
        return $smo
    } catch [Microsoft.SqlServer.Management.Common.ConnectionFailureException] {
        Write-Error "Connection failure for '$ServerName': $($_.Exception.Message)"
        return $null
    } catch {
        Write-Error "Error connecting to '$ServerName': $($_.Exception.Message)"
        return $null
    }
}
#endregion

# ---------------------------------------------------------------------------
#region  DATABASE PROPERTY RETRIEVAL
# ---------------------------------------------------------------------------
function Get-DatabaseProperties {
    <#
    .NOTES
        Returns [PSCustomObject[]] directly — NO comma-operator wrapping.
        The caller wraps with @() which safely handles single-row results
        without creating a double-wrap that exposes System.Array properties.
    #>
    param(
        [Parameter(Mandatory)] [Microsoft.SqlServer.Management.Smo.Server]$SmoServer,
        [Parameter(Mandatory)] [string]$DatabaseName
    )

    $safeDb      = $DatabaseName.Replace("'","''")
    $whereClause = if ($DatabaseName -eq "All") { "WHERE d.database_id > 4" } `
                   else { "WHERE d.name = N'$safeDb'" }

    $query = @"
SELECT
    d.name                                          AS [DatabaseName],
    d.compatibility_level                           AS [CompatibilityLevel],
    d.collation_name                                AS [Collation],
    d.recovery_model_desc                           AS [RecoveryModel],
    d.state_desc                                    AS [State],
    d.user_access_desc                              AS [UserAccess],
    CAST(d.is_read_only              AS INT)        AS [ReadOnly],
    CAST(d.is_auto_close_on          AS INT)        AS [AutoClose],
    CAST(d.is_auto_shrink_on         AS INT)        AS [AutoShrink],
    CAST(d.is_auto_create_stats_on   AS INT)        AS [AutoCreateStats],
    CAST(d.is_auto_update_stats_on   AS INT)        AS [AutoUpdateStats],
    CAST(d.is_fulltext_enabled       AS INT)        AS [FullTextEnabled],
    d.page_verify_option_desc                       AS [PageVerify],
    d.log_reuse_wait_desc                           AS [LogReuseWait],
    CAST(d.is_encrypted              AS INT)        AS [Encrypted],
    CAST(d.is_trustworthy_on         AS INT)        AS [Trustworthy],
    CAST(d.is_db_chaining_on         AS INT)        AS [DBChaining],
    CAST(d.is_broker_enabled         AS INT)        AS [BrokerEnabled],
    d.snapshot_isolation_state_desc                 AS [SnapshotIsolation],
    CAST(d.is_read_committed_snapshot_on AS INT)    AS [ReadCommittedSnapshot],
    CAST(d.is_ansi_null_default_on   AS INT)        AS [ANSINullDefault],
    CAST(d.is_ansi_nulls_on          AS INT)        AS [ANSINulls],
    CAST(d.is_ansi_padding_on        AS INT)        AS [ANSIPadding],
    CAST(d.is_ansi_warnings_on       AS INT)        AS [ANSIWarnings],
    CAST(d.is_arithabort_on          AS INT)        AS [ArithAbort],
    CAST(d.is_concat_null_yields_null_on AS INT)    AS [ConcatNullYieldsNull],
    CAST(d.is_numeric_roundabort_on  AS INT)        AS [NumericRoundAbort],
    CAST(d.is_quoted_identifier_on   AS INT)        AS [QuotedIdentifier],
    CAST(d.is_recursive_triggers_on  AS INT)        AS [RecursiveTriggers],
    CAST(d.is_cursor_close_on_commit_on AS INT)     AS [CursorCloseOnCommit],
    CAST(d.is_local_cursor_default   AS INT)        AS [LocalCursorDefault],
    CAST(d.is_parameterization_forced AS INT)       AS [ForcedParameterization],
    d.create_date                                   AS [CreateDate],
    CAST(ISNULL((SELECT SUM(CAST(mf.size AS BIGINT))*8.0/1024
                 FROM sys.master_files mf
                 WHERE mf.database_id=d.database_id AND mf.type=0),0)
         AS DECIMAL(18,2))                          AS [DataSizeMB],
    CAST(ISNULL((SELECT SUM(CAST(mf.size AS BIGINT))*8.0/1024
                 FROM sys.master_files mf
                 WHERE mf.database_id=d.database_id AND mf.type=1),0)
         AS DECIMAL(18,2))                          AS [LogSizeMB]
FROM sys.databases d
$whereClause
ORDER BY d.name;
"@

    try {
        $ds    = $SmoServer.Databases["master"].ExecuteWithResults($query)
        $table = $ds.Tables[0]
        if ($table.Rows.Count -eq 0) {
            Write-Warning "No rows returned for '$DatabaseName' on '$($SmoServer.Name)'."
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
        Write-Error "Failed querying '$DatabaseName' on '$($SmoServer.Name)': $($_.Exception.Message)"
        return [PSCustomObject[]]@()
    }
}
#endregion

# ---------------------------------------------------------------------------
#region  COMPARISON ENGINE
# ---------------------------------------------------------------------------
function Compare-DatabaseProperties {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$SourceRow,
        [Parameter(Mandatory)] [PSCustomObject]$TargetRow,
        [Parameter(Mandatory)] [string]$SourceDbName,
        [Parameter(Mandatory)] [string]$TargetDbName
    )
    $rows      = [System.Collections.Generic.List[PSCustomObject]]::new()
    $diffCount = 0

    foreach ($prop in $SourceRow.PSObject.Properties.Name) {
        if ($script:ExcludeProperties.Contains($prop)) { continue }

        $sv = if ($null -ne $SourceRow.PSObject.Properties[$prop]) {
                  "$($SourceRow.PSObject.Properties[$prop].Value)" } else { "N/A" }
        $tv = if ($null -ne $TargetRow.PSObject.Properties[$prop])  {
                  "$($TargetRow.PSObject.Properties[$prop].Value)"  } else { "N/A" }

        $isInfo = $script:InfoOnlyProperties.Contains($prop)
        $isDiff = (-not $isInfo) -and ($sv -ne $tv)
        if ($isDiff) { $diffCount++ }

        $rows.Add([PSCustomObject]@{
            Property   = $prop
            Source     = $sv
            Target     = $tv
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
#region  HTML REPORT GENERATOR  (sample report style)
# ---------------------------------------------------------------------------
function New-HtmlReport {
    param(
        [string]$SourceServerName,
        [string]$TargetServerName,
        [object]$SourceSmo,
        [object]$TargetSmo,
        [System.Collections.Generic.List[PSCustomObject]]$ComparisonList,
        [System.Collections.Generic.List[PSCustomObject]]$Comments,
        [string]$ReportOutputPath
    )

    $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $reportFile = Join-Path $ReportOutputPath ("SqlDbComparison_" +
                  (Get-Date -Format "yyyyMMdd_HHmmss") + ".html")

    $totalDiffs  = 0; foreach ($c in $ComparisonList) { $totalDiffs += $c.DiffCount }
    $dbCount     = $ComparisonList.Count
    $dbsWithDiff = ($ComparisonList | Where-Object { $_.DiffCount -gt 0 } | Measure-Object).Count
    $dbsClean    = $dbCount - $dbsWithDiff

    $srcVer = if ($null -ne $SourceSmo) { $SourceSmo.VersionString } else { "Unknown" }
    $tgtVer = if ($null -ne $TargetSmo) { $TargetSmo.VersionString } else { "Unknown" }
    $srcEd  = if ($null -ne $SourceSmo) { $SourceSmo.Edition       } else { "Unknown" }
    $tgtEd  = if ($null -ne $TargetSmo) { $TargetSmo.Edition       } else { "Unknown" }

    # ── CSS matching the sample report style ──────────────────────────────
    $css = @'
/* ── Reset & Base ── */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: #f1f5f9;
    color: #1e293b;
    font-size: 14px;
    line-height: 1.6;
}

/* ── Header ── */
.rpt-header {
    background: linear-gradient(135deg, #0f172a 0%, #1e3a5f 50%, #1d4ed8 100%);
    color: #fff;
    padding: 32px 48px;
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    box-shadow: 0 4px 20px rgba(0,0,0,0.3);
}
.rpt-header-left h1 {
    font-size: 24px;
    font-weight: 700;
    letter-spacing: 0.3px;
    display: flex;
    align-items: center;
    gap: 10px;
}
.rpt-header-left .subtitle {
    font-size: 12px;
    color: #93c5fd;
    margin-top: 6px;
    letter-spacing: 0.3px;
}
.rpt-header-right {
    text-align: right;
    font-size: 12px;
    color: #bfdbfe;
    line-height: 2;
}
.rpt-header-right strong { color: #fff; }

/* ── Server Banner ── */
.srv-banner {
    display: grid;
    grid-template-columns: 1fr 1fr;
}
.srv-card {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 20px 48px;
    color: #fff;
}
.srv-card.src { background: #14532d; border-right: 1px solid #166534; }
.srv-card.tgt { background: #1e3a5f; }
.srv-icon {
    width: 48px; height: 48px;
    border-radius: 12px;
    display: flex; align-items: center; justify-content: center;
    font-size: 24px; flex-shrink: 0;
}
.srv-card.src .srv-icon { background: #166534; }
.srv-card.tgt .srv-icon { background: #1d4ed8; }
.srv-info-label {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 1.5px;
    color: rgba(255,255,255,0.6);
    margin-bottom: 3px;
}
.srv-info-name {
    font-size: 18px;
    font-weight: 700;
    color: #fff;
}
.srv-info-ver {
    font-size: 11px;
    color: rgba(255,255,255,0.55);
    margin-top: 3px;
}

/* ── Summary Strip ── */
.summary-strip {
    background: #fff;
    padding: 28px 48px;
    border-bottom: 1px solid #e2e8f0;
    box-shadow: 0 1px 3px rgba(0,0,0,0.05);
}
.summary-strip h2 {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1.5px;
    color: #64748b;
    margin-bottom: 16px;
    display: flex;
    align-items: center;
    gap: 8px;
}
.summary-cards {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 16px;
}
.s-card {
    border-radius: 12px;
    padding: 18px 22px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    border: 1px solid transparent;
}
.s-card.blue   { background: #eff6ff; border-color: #bfdbfe; }
.s-card.green  { background: #f0fdf4; border-color: #bbf7d0; }
.s-card.red    { background: #fef2f2; border-color: #fecaca; }
.s-card.orange { background: #fff7ed; border-color: #fed7aa; }
.s-card-label  { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; color: #64748b; }
.s-card-value  { font-size: 34px; font-weight: 800; line-height: 1; }
.s-card.blue   .s-card-value  { color: #1d4ed8; }
.s-card.green  .s-card-value  { color: #15803d; }
.s-card.red    .s-card-value  { color: #dc2626; }
.s-card.orange .s-card-value  { color: #ea580c; }

/* ── Main Content Area ── */
.content { padding: 32px 48px; }

/* ── Database Block ── */
.db-block {
    background: #fff;
    border: 1px solid #e2e8f0;
    border-radius: 16px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.06);
    margin-bottom: 28px;
    overflow: hidden;
}

/* DB Block Header */
.db-block-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 16px 24px;
    background: #f8fafc;
    border-bottom: 2px solid #e2e8f0;
}
.db-block-title {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 17px;
    font-weight: 700;
    color: #0f172a;
}
.db-block-title span.icon { font-size: 20px; }
.db-block-meta {
    display: flex;
    align-items: center;
    gap: 12px;
}
.prop-count {
    font-size: 12px;
    color: #94a3b8;
    font-weight: 500;
}
.badge {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 5px 14px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 700;
}
.badge-diff { background: #fee2e2; color: #b91c1c; border: 1px solid #fecaca; }
.badge-ok   { background: #dcfce7; color: #15803d; border: 1px solid #bbf7d0; }

/* ── Table ── */
table.cmp-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13.5px;
}
table.cmp-table thead tr {
    background: #f1f5f9;
    border-bottom: 2px solid #cbd5e1;
}
table.cmp-table thead th {
    padding: 12px 20px;
    text-align: left;
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: #475569;
    white-space: nowrap;
}
table.cmp-table thead th:first-child  { width: 26%; }
table.cmp-table thead th:nth-child(2) { width: 31%; }
table.cmp-table thead th:nth-child(3) { width: 31%; }
table.cmp-table thead th:last-child   { width: 12%; text-align: center; }

/* Section separator rows */
table.cmp-table tr.section-hdr td {
    padding: 7px 20px;
    background: #f1f5f9;
    font-size: 10.5px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1.3px;
    color: #64748b;
    border-top: 1px solid #e2e8f0;
    border-bottom: 1px solid #e2e8f0;
}

/* Normal rows */
table.cmp-table tbody tr.row-normal {
    border-bottom: 1px solid #f1f5f9;
    transition: background 0.1s;
}
table.cmp-table tbody tr.row-normal:hover { background: #f8fafc; }

/* Info rows */
table.cmp-table tbody tr.row-info {
    border-bottom: 1px solid #f1f5f9;
    background: #fafafa;
}
table.cmp-table tbody tr.row-info td:first-child {
    border-left: 3px solid #cbd5e1;
    padding-left: 17px;
}

/* Diff rows */
table.cmp-table tbody tr.row-diff {
    background: #fff5f5;
    border-bottom: 1px solid #fecaca;
}
table.cmp-table tbody tr.row-diff td:first-child {
    border-left: 3px solid #ef4444;
    padding-left: 17px;
}
table.cmp-table tbody tr.row-diff:hover { background: #fee2e2; }

/* Cells */
table.cmp-table td {
    padding: 10px 20px;
    vertical-align: middle;
}
.cell-prop {
    font-weight: 600;
    color: #334155;
    font-size: 13px;
}
.row-diff .cell-prop { color: #b91c1c; }
.row-info .cell-prop { color: #64748b; }

.cell-val {
    font-family: 'Consolas', 'Courier New', monospace;
    font-size: 12.5px;
    color: #1e293b;
    word-break: break-all;
}
.row-diff .cell-val  { color: #b91c1c; font-weight: 700; }
.row-info .cell-val  { color: #94a3b8; font-style: italic; }

.cell-status { text-align: center; font-size: 16px; }
.ico-match { color: #16a34a; font-weight: 700; }
.ico-diff  { color: #dc2626; font-weight: 700; }
.ico-info  { color: #cbd5e1; }

/* ── Legend ── */
.legend {
    display: flex;
    gap: 24px;
    padding: 10px 22px;
    background: #f8fafc;
    border-top: 1px solid #e2e8f0;
    font-size: 11.5px;
    color: #475569;
}
.legend-item { display: flex; align-items: center; gap: 7px; }
.legend-dot  { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
.legend-dot.d { background: #ef4444; }
.legend-dot.m { background: #22c55e; }
.legend-dot.i { background: #94a3b8; }

/* ── Notes Panel ── */
.notes-panel {
    background: #fff;
    border: 1px solid #e2e8f0;
    border-radius: 16px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.06);
    margin-bottom: 28px;
    overflow: hidden;
}
.notes-header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 16px 24px;
    background: #fffbeb;
    border-bottom: 1px solid #fde68a;
}
.notes-header h3 {
    font-size: 15px;
    font-weight: 700;
    color: #92400e;
}
.notes-header .pin-icon { font-size: 20px; }
.notes-body { padding: 4px 0; }
.note-row {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 11px 24px;
    border-bottom: 1px solid #f8fafc;
    transition: background 0.1s;
}
.note-row:last-child { border-bottom: none; }
.note-row:hover { background: #fffdf5; }
.note-icon { font-size: 15px; flex-shrink: 0; margin-top: 1px; }
.note-content { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px; }
.note-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 5px;
    font-size: 9.5px;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 0.6px;
    flex-shrink: 0;
}
.note-badge.success { background: #dcfce7; color: #166534; }
.note-badge.info    { background: #dbeafe; color: #1e40af; }
.note-badge.warning { background: #fef9c3; color: #854d0e; }
.note-badge.error   { background: #fee2e2; color: #991b1b; }
.note-text { font-size: 13px; color: #334155; line-height: 1.5; }

/* ── Footer ── */
.rpt-footer {
    text-align: center;
    padding: 24px 48px;
    font-size: 12px;
    color: #94a3b8;
    background: #fff;
    border-top: 1px solid #e2e8f0;
}
.rpt-footer strong { color: #64748b; }
'@

    $sb = [System.Text.StringBuilder]::new(2MB)

    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head>')
    [void]$sb.AppendLine('<meta charset="UTF-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1.0">')
    [void]$sb.AppendLine('<title>SQL Database Comparison Report</title>')
    [void]$sb.AppendLine("<style>$css</style>")
    [void]$sb.AppendLine('</head><body>')

    # ── Header ────────────────────────────────────────────────────────────
    [void]$sb.AppendLine(@"
<div class="rpt-header">
  <div class="rpt-header-left">
    <h1>&#128202; SQL Server Database Comparison Report</h1>
    <div class="subtitle">Property-level comparison &bull; SMO + sys.databases &bull; Compare-SqlDatabases.ps1</div>
  </div>
  <div class="rpt-header-right">
    <div>&#128197; Generated: <strong>$reportDate</strong></div>
    <div>Databases Compared: <strong>$dbCount</strong></div>
    <div>Script Version: <strong>1.0.0</strong></div>
  </div>
</div>
"@)

    # ── Server Banner ─────────────────────────────────────────────────────
    $encSrcName = ConvertTo-HtmlEncoded $SourceServerName
    $encTgtName = ConvertTo-HtmlEncoded $TargetServerName
    [void]$sb.AppendLine(@"
<div class="srv-banner">
  <div class="srv-card src">
    <div class="srv-icon">&#128190;</div>
    <div>
      <div class="srv-info-label">Source Server</div>
      <div class="srv-info-name">$encSrcName</div>
      <div class="srv-info-ver">SQL Server $srcVer &bull; $srcEd</div>
    </div>
  </div>
  <div class="srv-card tgt">
    <div class="srv-icon">&#127919;</div>
    <div>
      <div class="srv-info-label">Target Server</div>
      <div class="srv-info-name">$encTgtName</div>
      <div class="srv-info-ver">SQL Server $tgtVer &bull; $tgtEd</div>
    </div>
  </div>
</div>
"@)

    # ── Summary Cards ─────────────────────────────────────────────────────
    [void]$sb.AppendLine(@"
<div class="summary-strip">
  <h2>&#128200; Comparison Summary</h2>
  <div class="summary-cards">
    <div class="s-card blue">
      <div class="s-card-label">Databases Compared</div>
      <div class="s-card-value">$dbCount</div>
    </div>
    <div class="s-card green">
      <div class="s-card-label">Fully Matching</div>
      <div class="s-card-value">$dbsClean</div>
    </div>
    <div class="s-card red">
      <div class="s-card-label">Databases with Differences</div>
      <div class="s-card-value">$dbsWithDiff</div>
    </div>
    <div class="s-card orange">
      <div class="s-card-label">Total Property Differences</div>
      <div class="s-card-value">$totalDiffs</div>
    </div>
  </div>
</div>
"@)

    # ── Per-Database Comparison Blocks ────────────────────────────────────
    [void]$sb.AppendLine('<div class="content">')

    foreach ($comp in $ComparisonList) {
        $encSrc     = ConvertTo-HtmlEncoded $comp.SourceDatabase
        $encTgt     = ConvertTo-HtmlEncoded $comp.TargetDatabase
        $propCount  = $comp.Rows.Count
        $badgeCls   = if ($comp.DiffCount -gt 0) { "badge-diff" } else { "badge-ok" }
        $badgeTxt   = if ($comp.DiffCount -gt 0) {
            "&#9888;&nbsp;$($comp.DiffCount) Difference(s)"
        } else { "&#10003;&nbsp;Identical" }
        $dbLabel    = if ($encSrc -eq $encTgt) { $encSrc } else { "$encSrc &#8594; $encTgt" }

        [void]$sb.AppendLine(@"
<div class="db-block">
  <div class="db-block-header">
    <div class="db-block-title">
      <span class="icon">&#128451;</span>
      $dbLabel
    </div>
    <div class="db-block-meta">
      <span class="prop-count">$propCount properties compared</span>
      <span class="badge $badgeCls">$badgeTxt</span>
    </div>
  </div>
  <table class="cmp-table">
    <thead>
      <tr>
        <th>Property</th>
        <th>&#128190; Source &mdash; $encSrc</th>
        <th>&#127919; Target &mdash; $encTgt</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
"@)

        # Informational section
        $infoRows = $comp.Rows | Where-Object { $_.IsInfoOnly }
        if ($infoRows) {
            [void]$sb.AppendLine(@"
      <tr class="section-hdr"><td colspan="4">&#128202;&nbsp; Informational</td></tr>
"@)
            foreach ($r in $infoRows) {
                $ep = ConvertTo-HtmlEncoded $r.Property
                $es = ConvertTo-HtmlEncoded $r.Source
                $et = ConvertTo-HtmlEncoded $r.Target
                [void]$sb.AppendLine(@"
      <tr class="row-info">
        <td class="cell-prop">$ep</td>
        <td class="cell-val">$es</td>
        <td class="cell-val">$et</td>
        <td class="cell-status"><span class="ico-info">&#8212;</span></td>
      </tr>
"@)
            }
        }

        # Configuration Properties section
        $configRows = $comp.Rows | Where-Object { -not $_.IsInfoOnly }
        if ($configRows) {
            [void]$sb.AppendLine(@"
      <tr class="section-hdr"><td colspan="4">&#9881;&nbsp; Configuration Properties</td></tr>
"@)
            foreach ($r in $configRows) {
                $ep      = ConvertTo-HtmlEncoded $r.Property
                $es      = ConvertTo-HtmlEncoded $r.Source
                $et      = ConvertTo-HtmlEncoded $r.Target
                $rowCls  = if ($r.IsDiff) { "row-diff" } else { "row-normal" }
                $statIco = if ($r.IsDiff) {
                    "<span class='ico-diff'>&#10007;</span>"
                } else {
                    "<span class='ico-match'>&#10003;</span>"
                }
                [void]$sb.AppendLine(@"
      <tr class="$rowCls">
        <td class="cell-prop">$ep</td>
        <td class="cell-val">$es</td>
        <td class="cell-val">$et</td>
        <td class="cell-status">$statIco</td>
      </tr>
"@)
            }
        }

        [void]$sb.AppendLine(@"
    </tbody>
  </table>
  <div class="legend">
    <div class="legend-item"><span class="legend-dot d"></span> Mismatch</div>
    <div class="legend-item"><span class="legend-dot m"></span> Match</div>
    <div class="legend-item"><span class="legend-dot i"></span> Informational (not compared)</div>
  </div>
</div>
"@)
    }

    # ── Notes & Observations ──────────────────────────────────────────────
    if ($null -ne $Comments -and $Comments.Count -gt 0) {
        [void]$sb.AppendLine(@"
<div class="notes-panel">
  <div class="notes-header">
    <span class="pin-icon">&#128204;</span>
    <h3>Notes &amp; Observations ($($Comments.Count))</h3>
  </div>
  <div class="notes-body">
"@)
        foreach ($c in $Comments) {
            $ico = switch ($c.Type) {
                "error"   { "&#10060;" }
                "warning" { "&#9888;"  }
                "info"    { "&#8505;"  }
                "success" { "&#9989;"  }
                default   { "&#8226;"  }
            }
            $encodedMsg = ConvertTo-HtmlEncoded $c.Message
            $noteType   = $c.Type
            [void]$sb.AppendLine(@"
    <div class="note-row">
      <span class="note-icon">$ico</span>
      <div class="note-content">
        <span class="note-badge $noteType">$noteType</span>
        <span class="note-text">$encodedMsg</span>
      </div>
    </div>
"@)
        }
        [void]$sb.AppendLine("  </div></div>")
    }

    # ── Footer ────────────────────────────────────────────────────────────
    [void]$sb.AppendLine(@"
</div><!-- /content -->
<div class="rpt-footer">
  Generated by <strong>Compare-SqlDatabases.ps1</strong> &bull; $reportDate &bull;
  <strong>$encSrcName</strong> &rarr; <strong>$encTgtName</strong> &bull;
  $dbCount database(s) &bull; $totalDiffs total difference(s)
</div>
</body></html>
"@)

    try {
        [System.IO.File]::WriteAllText($reportFile, $sb.ToString(),
            [System.Text.Encoding]::UTF8)
        Write-Host "  Report saved: $reportFile" -ForegroundColor Green
        return $reportFile
    } catch {
        Write-Error "Failed to write report to '$reportFile': $($_.Exception.Message)"
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
        $comments.Add([PSCustomObject]@{ Type="error"
            Message="Failed to connect to source: $SourceServer" })
        Write-Error "Aborting — source connection failed."; exit 1
    }
    if ($null -eq $tgtSmo) {
        $comments.Add([PSCustomObject]@{ Type="error"
            Message="Failed to connect to target: $TargetServer" })
        Write-Error "Aborting — target connection failed."; exit 1
    }

    $comments.Add([PSCustomObject]@{ Type="info"
        Message="Source: $SourceServer — SQL Server $($srcSmo.VersionString), $($srcSmo.Edition)." })
    $comments.Add([PSCustomObject]@{ Type="info"
        Message="Target: $TargetServer — SQL Server $($tgtSmo.VersionString), $($tgtSmo.Edition)." })

    if ($srcSmo.VersionMajor -ne $tgtSmo.VersionMajor) {
        $comments.Add([PSCustomObject]@{ Type="warning"
            Message=("SQL Server major version mismatch — Source: $($srcSmo.VersionString) / " +
                     "Target: $($tgtSmo.VersionString). Some comparisons may be unreliable.") })
    }

    # 3 — Resolve DB list
    Write-Host "`n[3/4] Resolving database pairs..." -ForegroundColor Yellow

    function Resolve-DbList {
        param(
            [Microsoft.SqlServer.Management.Smo.Server]$Smo,
            [string]$DbParam,
            [string]$Role
        )
        if ($DbParam -eq "All") {
            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($db in $Smo.Databases) {
                if ((-not $db.IsSystemObject) -and
                    ($db.Status -eq [Microsoft.SqlServer.Management.Smo.DatabaseStatus]::Normal)) {
                    $names.Add($db.Name)
                }
            }
            $sorted = $names | Sort-Object
            Write-Host ("  $Role 'All': found {0} user database(s) on {1}" -f
                $names.Count, $Smo.Name) -ForegroundColor White
            return [string[]]$sorted
        }
        $found = $false
        foreach ($db in $Smo.Databases) {
            if ($db.Name -eq $DbParam) { $found = $true; break }
        }
        if (-not $found) { throw "Database '$DbParam' not found on $($Smo.Name)." }
        return [string[]]@($DbParam)
    }

    try {
        [string[]]$srcDbs = @(Resolve-DbList -Smo $srcSmo -DbParam $SourceDatabase -Role "Source")
        [string[]]$tgtDbs = @(Resolve-DbList -Smo $tgtSmo -DbParam $TargetDatabase -Role "Target")
    } catch {
        $comments.Add([PSCustomObject]@{ Type="error"; Message=$_.Exception.Message })
        Write-Error $_.Exception.Message; exit 1
    }

    # Build pairs
    $pairs = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($SourceDatabase -eq "All" -and $TargetDatabase -eq "All") {
        $all = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $srcDbs) { [void]$all.Add($n) }
        foreach ($n in $tgtDbs) { [void]$all.Add($n) }
        $sSet = [System.Collections.Generic.HashSet[string]]::new(
            $srcDbs, [System.StringComparer]::OrdinalIgnoreCase)
        $tSet = [System.Collections.Generic.HashSet[string]]::new(
            $tgtDbs, [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in ($all | Sort-Object)) {
            $inS = $sSet.Contains($n); $inT = $tSet.Contains($n)
            if ($inS -and $inT) { $pairs.Add([PSCustomObject]@{ Src=$n; Tgt=$n }) }
            elseif ($inS) {
                $m = "'$n' on source ($SourceServer) but NOT on target ($TargetServer) — skipped."
                $comments.Add([PSCustomObject]@{ Type="warning"; Message=$m }); Write-Warning $m }
            else {
                $m = "'$n' on target ($TargetServer) but NOT on source ($SourceServer) — skipped."
                $comments.Add([PSCustomObject]@{ Type="warning"; Message=$m }); Write-Warning $m }
        }
    } elseif ($SourceDatabase -eq "All") {
        foreach ($n in $srcDbs) { $pairs.Add([PSCustomObject]@{ Src=$n; Tgt=$TargetDatabase }) }
    } elseif ($TargetDatabase -eq "All") {
        foreach ($n in $tgtDbs) { $pairs.Add([PSCustomObject]@{ Src=$SourceDatabase; Tgt=$n }) }
    } else {
        $pairs.Add([PSCustomObject]@{ Src=$SourceDatabase; Tgt=$TargetDatabase })
    }

    if ($pairs.Count -eq 0) {
        Write-Warning "No comparable database pairs found."; exit 0 }

    # 4 — Compare
    Write-Host "`n[4/4] Comparing properties and generating report..." -ForegroundColor Yellow
    $allComparisons = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($pair in $pairs) {
        Write-Host ("  Comparing  [{0}]  vs  [{1}] ..." -f $pair.Src, $pair.Tgt) -ForegroundColor White

        # Direct return from Get-DatabaseProperties + @() wrapper = correct single-row indexing
        [PSCustomObject[]]$sp = @(Get-DatabaseProperties -SmoServer $srcSmo -DatabaseName $pair.Src)
        [PSCustomObject[]]$tp = @(Get-DatabaseProperties -SmoServer $tgtSmo -DatabaseName $pair.Tgt)

        if ($sp.Count -eq 0) {
            $comments.Add([PSCustomObject]@{ Type="error"
                Message="No data for '$($pair.Src)' on $SourceServer — skipped." })
            Write-Warning "  Skipped '$($pair.Src)' — no source data."; continue }
        if ($tp.Count -eq 0) {
            $comments.Add([PSCustomObject]@{ Type="error"
                Message="No data for '$($pair.Tgt)' on $TargetServer — skipped." })
            Write-Warning "  Skipped '$($pair.Tgt)' — no target data."; continue }

        $cmp = Compare-DatabaseProperties `
            -SourceRow    $sp[0]      -TargetRow    $tp[0] `
            -SourceDbName $pair.Src   -TargetDbName $pair.Tgt

        if ($cmp.DiffCount -gt 0) {
            $diffList = ($cmp.Rows | Where-Object { $_.IsDiff } |
                         Select-Object -ExpandProperty Property) -join ", "
            $comments.Add([PSCustomObject]@{ Type="warning"
                Message="$($pair.Src) — $($cmp.DiffCount) difference(s) in: $diffList" })
            Write-Host "    $($cmp.DiffCount) difference(s) found" -ForegroundColor Yellow
        } else {
            $comments.Add([PSCustomObject]@{ Type="success"
                Message="$($pair.Src) — all $($cmp.Rows.Count) compared properties are identical on both servers." })
            Write-Host "    All properties match" -ForegroundColor Green
        }
        $allComparisons.Add($cmp)
    }

    $reportPath = New-HtmlReport `
        -SourceServerName $SourceServer   -TargetServerName $TargetServer `
        -SourceSmo        $srcSmo         -TargetSmo        $tgtSmo       `
        -ComparisonList   $allComparisons  -Comments         $comments     `
        -ReportOutputPath $OutputPath

    if ($null -ne $reportPath) {
        $finalDiffs = 0; foreach ($c in $allComparisons) { $finalDiffs += $c.DiffCount }
        Write-Host "`n============================================" -ForegroundColor Cyan
        Write-Host ("  Done!  DBs compared: {0}  |  Total diffs: {1}" -f
            $allComparisons.Count, $finalDiffs) `
            -ForegroundColor $(if ($finalDiffs -gt 0) { "Yellow" } else { "Green" })
        Write-Host "  Report: $reportPath"  -ForegroundColor Green
        Write-Host "============================================`n" -ForegroundColor Cyan
        try { Start-Process $reportPath } catch { }
    }
}

Invoke-Main
#endregion
