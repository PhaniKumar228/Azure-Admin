# ==================================================================================
# Generate Restore Scripts from Backup Files
# Uses SQL Server SMO only
# ==================================================================================

param (
    [string]$BackupFolder = "H:\SQLBackups",
    [string]$DataPath     = "L:\SQLData",
    [string]$LogPath      = "M:\SQLLogs",
    [string]$OutputFile   = "C:\Temp\Generated_Restore_Scripts.sql"
)

# Load SMO Assemblies
Add-Type -AssemblyName "Microsoft.SqlServer.Smo"
Add-Type -AssemblyName "Microsoft.SqlServer.SmoExtended"
Add-Type -AssemblyName "Microsoft.SqlServer.ConnectionInfo"

# Temporary SQL Instance
# Required by SMO Restore object
$Server = New-Object Microsoft.SqlServer.Management.Smo.Server("localhost")

$RestoreCommands = New-Object System.Collections.Generic.List[string]

Get-ChildItem -Path $BackupFolder -Filter "*.bak" | Sort-Object Name | ForEach-Object {

    $BakFile = $_.FullName

    Write-Host "Processing $($_.Name)" -ForegroundColor Cyan

    # Remove .bak extension
    $DatabaseName = $_.BaseName

    # Remove date suffix if format is DBNAME_YYYYMMDD
    if ($DatabaseName -match '^(.*)_\d{8}$')
    {
        $DatabaseName = $Matches[1]
    }

    $Restore = New-Object Microsoft.SqlServer.Management.Smo.Restore
    $Device = New-Object Microsoft.SqlServer.Management.Smo.BackupDeviceItem(
                    $BakFile,
                    [Microsoft.SqlServer.Management.Smo.DeviceType]::File)

    $Restore.Devices.Add($Device)

    try
    {
        $FileList = $Restore.ReadFileList($Server)

        $SQL = @()
        $SQL += ""
        $SQL += "-- ========================================================================"
        $SQL += "-- Database : $DatabaseName"
        $SQL += "-- Backup   : $BakFile"
        $SQL += "-- ========================================================================"
        $SQL += "RESTORE DATABASE [$DatabaseName]"
        $SQL += "FROM DISK = N'$BakFile'"
        $SQL += "WITH"

        $Moves = @()

        foreach ($File in $FileList)
        {
            $LogicalName = $File.LogicalName
            $Type        = $File.Type

            if ($Type -eq "D")
            {
                $PhysicalFile =
                    Join-Path $DataPath ($DatabaseName + ".mdf")
            }
            elseif ($Type -eq "L")
            {
                $PhysicalFile =
                    Join-Path $LogPath ($DatabaseName + "_Log.ldf")
            }
            else
            {
                $Extension =
                    [System.IO.Path]::GetExtension($File.PhysicalName)

                if ([string]::IsNullOrWhiteSpace($Extension))
                {
                    $Extension = ".ndf"
                }

                $PhysicalFile =
                    Join-Path $DataPath ($LogicalName + $Extension)
            }

            $Moves += "    MOVE N'$LogicalName' TO N'$PhysicalFile'"
        }

        $SQL += ($Moves -join ",`r`n")
        $SQL += ",    REPLACE"
        $SQL += ",    RECOVERY"
        $SQL += ",    STATS = 10;"
        $SQL += "GO"
        $SQL += ""

        $RestoreCommands.Add(($SQL -join "`r`n"))
    }
    catch
    {
        Write-Warning "Unable to read backup file $BakFile"
        Write-Warning $_.Exception.Message
    }
}

$RestoreCommands | Out-File -FilePath $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "Restore script generated successfully" -ForegroundColor Green
Write-Host "Output File: $OutputFile" -ForegroundColor Yellow
