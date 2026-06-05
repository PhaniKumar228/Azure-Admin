function Get-AppSetting {
    param (
        [xml]$Config,
        [string]$Key
    )

    return ($Config.configuration.appSettings.add |
            Where-Object { $_.key -eq $Key }).value
}

function Get-ConnectionString {
    param (
        [xml]$Config,
        [string]$Name
    )

    return ($Config.configuration.connectionStrings.add |
            Where-Object { $_.name -eq $Name }).connectionString
}


$config = Read-ConfigXml "C:\app.config"

$env = Get-AppSetting -Config $config -Key "Environment"
$db  = Get-ConnectionString -Config $config -Name "DBConn"

Write-Host "Environment: $env"
Write-Host "DB Connection: $db"
