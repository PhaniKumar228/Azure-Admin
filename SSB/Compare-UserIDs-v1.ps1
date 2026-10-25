param(
    [Parameter(Mandatory)]
    [string]$UserListFile,

    [Parameter(Mandatory)]
    [string]$SourceFile,

    [string]$OutputHtml = ".\UserID_Audit_Report.html"
)

#--------------------------------------------------
# Helper Function
#--------------------------------------------------

function Normalize-ID {
    param([string]$ID)

    if ([string]::IsNullOrWhiteSpace($ID)) {
        return ""
    }

    return (
        $ID.ToString().
        Trim().
        ToUpper().
        Replace(" ","").
        Replace("`t","").
        Replace("`r","").
        Replace("`n","")
    )
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "User ID Validation Report Generator" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

#--------------------------------------------------
# Load IDs From Input File
#--------------------------------------------------

if (!(Test-Path $UserListFile)) {
    throw "Input file not found: $UserListFile"
}

$RequiredIDs = Get-Content $UserListFile |
ForEach-Object {
    Normalize-ID $_
} |
Where-Object {
    $_ -ne ""
} |
Sort-Object -Unique

Write-Host "Loaded $($RequiredIDs.Count) IDs from input file"
Write-Host ""

#--------------------------------------------------
# Load Export File
#--------------------------------------------------

$Extension = [System.IO.Path]::GetExtension($SourceFile).ToLower()

switch ($Extension)
{
    ".csv" {
        Write-Host "Reading CSV file..."
        $ExportData = Import-Csv $SourceFile
        break
    }

    ".txt" {

        Write-Host "Reading TXT file..."

        try
        {
            $ExportData = Import-Csv $SourceFile -Delimiter "`t"

            if (!$ExportData)
            {
                $ExportData = Import-Csv $SourceFile
            }
        }
        catch
        {
            $ExportData = Import-Csv $SourceFile
        }

        break
    }

    ".xlsx" {

        if (!(Get-Module -ListAvailable ImportExcel))
        {
            throw "ImportExcel module not installed. Run: Install-Module ImportExcel"
        }

        Write-Host "Reading Excel file..."

        $ExportData = Import-Excel $SourceFile
        break
    }

    default {
        throw "Unsupported file type: $Extension"
    }
}

if (!$ExportData)
{
    throw "No data loaded from source file."
}

#--------------------------------------------------
# Detect User ID Column
#--------------------------------------------------

$Columns = $ExportData[0].PSObject.Properties.Name

Write-Host ""
Write-Host "Available Columns:"
$Columns | ForEach-Object {
    Write-Host "  $_"
}

$UserIDColumn = $Columns |
Where-Object {
    $_ -match '(?i)user.*id|userid|user_id|employee.*id|login.*id|account.*id'
} |
Select-Object -First 1

if (!$UserIDColumn)
{
    Write-Host ""
    Write-Host "ERROR: Unable to detect User ID column." -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "Detected User ID Column: $UserIDColumn" -ForegroundColor Green

#--------------------------------------------------
# Build Source Lookup
#--------------------------------------------------

$ExistingIDs = @{}

foreach ($row in $ExportData)
{
    $SourceID = Normalize-ID $row.$UserIDColumn

    if ($SourceID)
    {
        $ExistingIDs[$SourceID] = $true
    }
}

Write-Host "Loaded $($ExistingIDs.Count) User IDs from source"
Write-Host ""

#--------------------------------------------------
# Compare IDs
#--------------------------------------------------

$Results = foreach ($ID in $RequiredIDs)
{
    if ($ExistingIDs.ContainsKey($ID))
    {
        [PSCustomObject]@{
            UserID = $ID
            Status = "Found"
        }
    }
    else
    {
        [PSCustomObject]@{
            UserID = $ID
            Status = "Missing"
        }
    }
}

#--------------------------------------------------
# Summary
#--------------------------------------------------

$FoundCount   = ($Results | Where-Object Status -eq "Found").Count
$MissingCount = ($Results | Where-Object Status -eq "Missing").Count

$MissingIDs = $Results |
Where-Object Status -eq "Missing"

$MissingIDs.UserID |
Set-Content ".\MissingIDs.txt"

#--------------------------------------------------
# HTML Report Rows
#--------------------------------------------------

$Rows = foreach ($Result in $Results)
{
    if ($Result.Status -eq "Missing")
    {
        $Color = "#F8D7DA"
    }
    else
    {
        $Color = "#D4EDDA"
    }

@"
<tr style='background-color:$Color'>
<td>$($Result.UserID)</td>
<td>$($Result.Status)</td>
</tr>
"@
}

#--------------------------------------------------
# Build HTML
#--------------------------------------------------

$Html = @"
<html>
<head>

<title>User ID Validation Report</title>

<style>

body{
font-family:Segoe UI;
padding:20px;
}

h1{
color:#2F5597;
}

table{
border-collapse:collapse;
width:60%;
}

th{
background:#2F5597;
color:white;
padding:10px;
border:1px solid #ddd;
}

td{
padding:8px;
border:1px solid #ddd;
}

.summary{
padding:15px;
background:#EAF2F8;
border-left:5px solid #2F5597;
margin-bottom:20px;
font-size:14px;
}

</style>

</head>

<body>

<h1>User ID Validation Report</h1>

<div class='summary'>

<b>Source File:</b> $SourceFile <br>
<b>User ID Column:</b> $UserIDColumn <br>
<b>Total IDs Checked:</b> $($RequiredIDs.Count) <br>
<b>Found:</b> $FoundCount <br>
<b>Missing:</b> $MissingCount <br>
<b>Generated:</b> $(Get-Date)

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

$Html | Out-File $OutputHtml -Encoding UTF8

#--------------------------------------------------
# Open Report
#--------------------------------------------------

WriteWrite-Host "Found    : $FoundCount" -ForegroundColor Green
Write-Host "Missing  : $MissingCount" -ForegroundColor Yellow
Write-Host ""

Write-Host "HTML Report : $OutputHtml" -ForegroundColor Cyan
Write-Host "Missing IDs : .\MissingIDs.txt" -ForegroundColor Cyan

Invoke-Item $OutputHtml


#.\Compare-UserIDs.ps1 `
#    -UserListFile "E:\DBA\MSSQL\SCRIPTS\UserID-imp.txt" `
#    -SourceFile "E:\DBA\MSSQL\SCRIPTS\UserExport.xlsx"
