# ==================================================================================
# Generate SQL Restore Scripts from .BAK Files
# Uses SQLPS / SMO
# ==================================================================================

param(
    [string]$BackupFolder = "H:\Backups",
    [string]$DataFolder   = "D:\SQLData",
    [string]$LogFolder    = "L:\SQLLogs",
    [string]$OutputFile   = "C:\Temp\RestoreScripts.sql"
)

# Load SQLPS
Import-Module SQLPS -DisableNameChecking

# SMO Server Object
$server = New-Object Microsoft.SqlServer.Management.Smo.Server "(local)"

$RestoreScripts = @()

Get-ChildItem $BackupFolder -Filter "*.bak" | Sort-Object Name | ForEach-Object {

    $BackupFile  = $_.FullName
    $DatabaseName = $_.BaseName

    # Optional: remove trailing _YYYYMMDD if present
    if ($DatabaseName -match '^(.*)_\d{8}$') {
        $DatabaseName = $Matches[1]
    }

    Write-Host "Processing $($_.Name)" -ForegroundColor Cyan

    $restore = New-Object Microsoft.SqlServer.Management.Smo.Restore

    $device = New-Object Microsoft.SqlServer.Management.Smo.BackupDeviceItem(
        $BackupFile,
        [Microsoft.SqlServer.Management.Smo.DeviceType]::File
    )

    $restore.Devices.Add($device)

    try {

        $fileList = $restore.ReadFileList($server)

        $MoveClauses = @()
        $DataFileCounter = 0

        foreach ($file in $fileList.Rows) {

            $logicalName = $file["LogicalName"]
            $fileType    = $file["Type"]

            if ($fileType -eq "D") {

                $DataFileCounter++

                if ($DataFileCounter -eq 1) {
                    $PhysicalName = Join-Path $DataFolder "$DatabaseName.mdf"
                }
                else {
                    $PhysicalName = Join-Path $DataFolder "$DatabaseName" + "_$DataFileCounter.ndf"
                }

            }
            elseif ($fileType -eq "L") {

                $PhysicalName = Join-Path $LogFolder "$DatabaseName`_Log.ldf"
            }

            $MoveClauses += "    MOVE N'$logicalName' TO N'$PhysicalName'"
        }

        $Script = @"
RESTORE DATABASE [$DatabaseName]
FROM DISK = N'$BackupFile'
WITH
$($MoveClauses -join ",`r`n"),
    REPLACE,
    RECOVERY,
    STATS = 10;
GO

"@

        $RestoreScripts += $Script
    }
    catch {
        Write-Warning "Failed reading backup: $BackupFile"
        Write-Warning $_.Exception.Message
    }
}

$RestoreScripts | Out-File $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "Restore script generated successfully." -ForegroundColor Green
Write-Host "Output file: $OutputFile" -ForegroundColor Yellow
