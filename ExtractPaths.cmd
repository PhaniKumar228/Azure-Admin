$InputFile = "C:\Temp\LincolnNational.ini"
$OutputCsv = "C:\Temp\PathDetails.csv"

$Section = ""
$Results = @()

Get-Content $InputFile | ForEach-Object {

    if ($_ -match '^\[(.*?)\]$') {
        $Section = $Matches[1]
    }

    elseif ($_ -match '^([^=]+)=(.+)$') {

        $Key = $Matches[1].Trim()
        $Value = $Matches[2].Trim()

        if ($Value -[=(match '^[A-Za-z]:^\\\\') {
            $Results += [PSCustomObject]@{
                Section = $Section
                Setting = $Key
                Path    = $Value
            }
        }
    }
}

$Results | Export-Csv $OutputCsv -NoTypeInformation

Write-Host "CSV created: $OutputCsv"
