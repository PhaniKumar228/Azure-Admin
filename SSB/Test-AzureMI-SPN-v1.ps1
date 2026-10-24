param(
    [Parameter(Mandatory)]
    [string]$HostFqdn,

    [Parameter(Mandatory)]
    [string]$SPNName,

    [Parameter(Mandatory)]
    [string]$DatabaseName,

    [Parameter()]
    [string]$ConfigFilePath = ".\mi-config.json"
)

# ──────────────────────────────────────────────
# Load & Validate Config
# ──────────────────────────────────────────────
if (-not (Test-Path $ConfigFilePath))
{
    Write-Host "`nConfig file not found: $ConfigFilePath" -ForegroundColor Red
    exit 1
}

try
{
    $config = Get-Content -Raw -Path $ConfigFilePath | ConvertFrom-Json
}
catch
{
    Write-Host "`nFailed to parse config file: $_" -ForegroundColor Red
    exit 1
}

# ──────────────────────────────────────────────
# Resolve Server from FQDN
# ──────────────────────────────────────────────
$server = $config.Servers | Where-Object { $_.HostFqdn -eq $HostFqdn }

if (-not $server)
{
    Write-Host "`nNo server found in config matching FQDN: $HostFqdn" -ForegroundColor Red
    Write-Host "Available FQDNs:" -ForegroundColor Yellow
    $config.Servers | ForEach-Object { Write-Host "  - $($_.HostFqdn)" -ForegroundColor Yellow }
    exit 1
}

# ──────────────────────────────────────────────
# Resolve SPN Credential by Name
# ──────────────────────────────────────────────
$credential = $config.Credentials | Where-Object { $_.Name -eq $SPNName }

if (-not $credential)
{
    Write-Host "`nNo credential found in config matching SPN name: $SPNName" -ForegroundColor Red
    Write-Host "Available SPNs:" -ForegroundColor Yellow
    $config.Credentials | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Yellow }
    exit 1
}

$tenantId            = $config.TenantId
$servicePrincipalId  = $credential.ClientId
$servicePrincipalSecret = $credential.ClientSecret
$port                = if ($server.Port) { $server.Port } else { 1433 }

# ──────────────────────────────────────────────
# Print Test Summary
# ──────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Azure SQL MI - SPN Authentication Test"  -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "Server   : $($server.Name)"
Write-Host "FQDN     : $HostFqdn"
Write-Host "Role     : $($server.Role)  |  Set: $($server.Set)"
Write-Host "Database : $DatabaseName"
Write-Host "SPN      : $SPNName"
Write-Host "ClientId : $servicePrincipalId"
Write-Host "TenantId : $tenantId`n"

# ──────────────────────────────────────────────
# Acquire Azure AD Token
# ──────────────────────────────────────────────
try
{
    Write-Host "Acquiring Azure AD Token..." -ForegroundColor Cyan

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $servicePrincipalId
        client_secret = $servicePrincipalSecret
        scope         = "https://database.windows.net/.default"
    }

    $tokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $body `
        -ContentType "application/x-www-form-urlencoded"

    $accessToken = $tokenResponse.access_token

    if (-not $accessToken)
    {
        throw "Token response received but access_token was empty."
    }

    Write-Host "Token acquired successfully." -ForegroundColor Green

    # ──────────────────────────────────────────────
    # Open SQL Connection
    # ──────────────────────────────────────────────
    $connectionString = "Server=tcp:$HostFqdn,$port;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = $connectionString
    $conn.AccessToken = $accessToken

    Write-Host "Opening SQL connection..." -ForegroundColor Cyan
    $conn.Open()

    # ──────────────────────────────────────────────
    # Run Diagnostic Query
    # ──────────────────────────────────────────────
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
SELECT
    @@SERVERNAME  AS ServerName,
    DB_NAME()     AS DatabaseName,
    SUSER_SNAME() AS LoginName,
    GETDATE()     AS CurrentTime;
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
