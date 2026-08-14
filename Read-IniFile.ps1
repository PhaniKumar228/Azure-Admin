function Read-IniFile {
    param([string]$Path)

    $ini = @{}
    $section = ""

    foreach ($line in Get-Content $Path) {

        $line = $line.Trim()

        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1]
            continue
        }

        if ($line -match '^(.+?)=(.*)$') {
            $key = "$section.$($matches[1].Trim())"
            $value = $matches[2].Trim()
            $ini[$key] = $value
        }
    }

    return $ini
}

$File1 = "C:\Temp\LINCPAM.ini"
$File2 = "C:\Temp\LINCPAM_New.ini"
$Report = "C:\Temp\IniComparison.html"

$Ini1 = Read-IniFile $File1
$Ini2 = Read-IniFile $File2

$Results = foreach ($Key in ($Ini1.Keys + $Ini2.Keys | Sort-Object -Unique)) {

    $Value1 = $Ini1[$Key]
    $Value2 = $Ini2[$Key]

    if ($Value1 -ne $Value2) {
        [PSCustomObject]@{
            Setting  = $Key
            OldValue = $Value1
            NewValue = $Value2
        }
    }
}

$Html = @"
<html>
<head>
<style>
body { font-family: Arial; font-size: 12px; }
table { border-collapse: collapse; width: 100%; }
th { background-color: #4472C4; color: white; padding: 8px; }
td { border: 1px solid #d3d3d3; padding: 6px; }
tr:nth-child(even) { background-color: #f2f2f2; }
.old { background-color: #FFC7CE; }
.new { background-color: #C6EFCE; }
</style>
</head>
<body>

<h2>INI File Comparison Report</h2>

<table>
<tr>
<th>Setting</th>
<th>Old Value</th>
<th>New Value</th>
</tr>

$(
$Results | ForEach-Object {
@"
<tr>
<td>$($_.Setting)</td>
<td class='old'>$($_.OldValue)</td>
<td class='new'>$($_.NewValue)</td>
</tr>
"@
}
)

</table>

</body>
</html>
"@

$Html | Set-Content $Report

Write-Host "Report Generated: $Report"
