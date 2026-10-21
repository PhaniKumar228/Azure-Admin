param(
    [Parameter(Mandatory)]
    [string]$SqlMIName,

    [Parameter(Mandatory)]
    [string]$DatabaseName,

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory)]
    [string]$ServicePrincipalSecret
)

try
{
    Write-Host "Acquiring Azure AD Token..." -ForegroundColor Cyan

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ServicePrincipalId
        client_secret = $ServicePrincipalSecret
        scope         = "https://database.windows.net/.default"
    }

    $tokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $body `
        -ContentType "application/x-www-form-urlencoded"

    $accessToken = $tokenResponse.access_token

    if (-not $accessToken)
    {
        throw "Failed to acquire access token."
    }

    Write-Host "Token acquired successfully." -ForegroundColor Green

    $connectionString = "Server=tcp:$SqlMIName,1433;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = $connectionString
    $conn.AccessToken = $accessToken

    Write-Host "Opening SQL connection..." -ForegroundColor Cyan
    $conn.Open()

    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
SELECT
    @@SERVERNAME AS ServerName,
    DB_NAME() AS DatabaseName,
    SUSER_SNAME() AS LoginName,
    GETDATE() AS CurrentTime;
"@

    $reader = $cmd.ExecuteReader()

    while ($reader.Read())
    {
        Write-Host "`nConnection Successful" -ForegroundColor Green
        Write-Host "Server   : $($reader['ServerName'])"
        Write-Host "Database : $($reader['DatabaseName'])"
        Write-Host "Login    : $($reader['LoginName'])"
        Write-Host "Time     : $($reader['CurrentTime'])"
    }

    $reader.Close()
    $conn.Close()

    Write-Host "`nSQL MI authentication using Service Principal succeeded." -ForegroundColor Green
}
catch
{
    Write-Host "`nConnection Failed" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow

    if ($_.Exception.InnerException)
    {
        Write-Host $_.Exception.InnerException.Message -ForegroundColor Yellow
    }
}
