param(
    [string]$UserListFile = ".\UserID-imp.txt",
    [string]$SourceFile   = ".\Export.xlsx",
    [string]$OutputHtml   = ".\UserID_Audit_Report.html"
)

#-------------------------------------------------------------
# Load User IDs to validate
#-------------------------------------------------------------
$RequiredIDs = Get-Content $UserListFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne "" } |
    Select-Object -Unique

Write-Host "Loaded $($RequiredIDs.Count) IDs from input file"

#-------------------------------------------------------------
# Read Source File
#-------------------------------------------------------------
$ExportData = @()

switch ([System.IO.Path]::GetExtension($SourceFile).ToLower())
{
    ".csv" {
        $ExportData = Import-Csv $SourceFile
    }

    ".txt" {
        # Assumes tab-delimited export
        $ExportData = Import-Csv $SourceFile -Delimiter "`t"
    }

    ".xlsx" {
        if (-not (Get-Module -ListAvailable ImportExcel))
        {
            Write-Error "ImportExcel module required. Install-Module ImportExcel"
            exit
        }

        $ExportData = Import-Excel $SourceFile
    }

    default {
        Write-Error "Unsupported file type"
        exit
    }
}

#-------------------------------------------------------------
# Detect User ID column
#-------------------------------------------------------------
$UserIDColumn = $null

$PossibleColumns = @(
    "User ID",
    "UserID",
    "Userid",
    "User_Id",
    "ID"
)

foreach($col in $PossibleColumns)
{
    if($ExportData[0].PSObject.Properties.Name -contains $col)
    {
        $UserIDColumn = $col
        break
    }
}

if(!$UserIDColumn)
{
    Write-Error "Could not locate User ID column."
    exit
}

Write-Host "Using column: $UserIDColumn"

#-------------------------------------------------------------
# Build Lookup
#-------------------------------------------------------------
$ExistingIDs = @{}

foreach($row in $ExportData)
{
    $id = ($row.$UserIDColumn).ToString().Trim()

    if($id)
    {
        $ExistingIDs[$id] = $true
    }
}

#-------------------------------------------------------------
# Compare IDs
#-------------------------------------------------------------
$Results = foreach($id in $RequiredIDs)
{
    [PSCustomObject]@{
        UserID = $id
        Status = if($ExistingIDs.ContainsKey($id))
        {
            "Found"
        }
        else
        {
            "Missing"
        }
    }
}

$MissingCount = ($Results | Where-Object Status -eq "Missing").Count
$FoundCount   = ($Results | Where-Object Status -eq "Found").Count

#-------------------------------------------------------------
# HTML Report
#-------------------------------------------------------------
$Rows = foreach($row in $Results)
{
    $color = if($row.Status -eq "Missing")
    {
        "#ffcccc"
    }
    else
    {
        "#ccffcc"
    }

@"
<tr style='background-color:$color'>
<td>$($row.UserID)</td>
<td>$($row.Status)</td>
</tr>
"@
}

$Html = @"
<html>
<head>
<title>User ID Audit Report</title>
<style>
body {
    font-family: Segoe UI;
    margin:20px;
}

table {
    border-collapse:collapse;
    width:60%;
}

th {
    background-color:#4472C4;
    color:white;
    padding:8px;
}

td {
    border:1px solid #ccc;
    padding:6px;
}

.summary{
    font-size:16px;
    margin-bottom:15px;
    font-weight:bold;
}
</style>
</head>

<body>

<h2>User ID Validation Report</h2>

<div class='summary'>
Total IDs Checked : $($RequiredIDs.Count)<br>
Found : $FoundCount<br>
Missing : $MissingCount
</div>

<table>
<tr>
<th>User ID</th>
<th>Status</th>
</tr>

$($Rows -join "`n")

</table>

</body>
</html>
"@

$Html | Set-Content $OutputHtml -Encoding UTF8

Write-Host ""
Write-Host "Report Generated : $OutputHtml"
Write-Host "Found   : $FoundCount"
Write-Host "Missing : $MissingCount"


#-------------------------------------------------------------
# .\Compare-UserIDs.ps1 `
#    -UserListFile D:\Input\UserID-imp.txt `
#    -SourceFile D:\Input\UserExport.xlsx `
#    -OutputHtml D:\Reports\UserAudit.html
#-------------------------------------------------------------
