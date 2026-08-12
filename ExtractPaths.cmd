$Section=""

Get-Content "C:\Temp\LincolnNational.ini" | ForEach-Object {

    if ($_ -match '^\[(.+)\]$') {
        $Section = $Matches[1]
    }

    elseif ($_ -match '^(.+?)=(.+)$') {

        $Name  = $Matches[1]
        $Value = $Matches[2]

        if ($Value -like "\\*" -or $Value -match "^[A-Za-z]:\\") {

            [PSCustomObject]@{
                Section = $Section
                Property = $Name
                Path = $Value
            }
        }
    }

} | Export-Csv "C:\Temp\PathDetails.csv" -NoTypeInformation
