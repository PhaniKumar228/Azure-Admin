param(
    [string]$RootPath = "C:\Your\Path\Here",
    [string]$OutputCsv = "C:\Temp\Config_Scan_Output.csv"
)

Write-Host "Scanning path: $RootPath" -ForegroundColor Cyan

# Create empty array
$results = @()

# Get all .config and .ini files recursively
$files = Get-ChildItem -Path $RootPath -Recurse -Include *.config, *.ini -ErrorAction SilentlyContinue

foreach ($file in $files) {
    try {
        $content = Get-Content $file.FullName -ErrorAction SilentlyContinue

        # Extract UNC paths (\\server\share...)
        $uncMatches = Select-String -InputObject $content -Pattern '\\\\[A-Za-z0-9\.\-_]+\\[A-Za-z0-9\$\-_\\\.]+' -AllMatches

        $uncPaths = ($uncMatches.Matches.Value | Select-Object -Unique) -join "; "

        # If no UNC found, mark as NONE
        if (-not $uncPaths) {
            $uncPaths = "NONE"
        }

        $results += [PSCustomObject]@{
            FolderPath     = $file.DirectoryName
            FileName       = $file.Name
            FullPath       = $file.FullName
            SharedPaths    = $uncPaths
        }
    }
    catch {
        Write-Warning "Error reading file: $($file.FullName)"
    }
}

# Export to CSV
$results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "Scan completed. Output saved to: $OutputCsv" -ForegroundColor Green


##.\Scan_Config.ps1 -RootPath "\\your\shared\path" -OutputCsv "C:\Temp\output.csv"
