# ──────────────────────────────────────────────────
# HELPER: Safely resolve the MI FQDN without duplication
# ──────────────────────────────────────────────────
function Get-MiFqdn {
    param (
        [string]$ServerName,   # e.g. "ssc-gts-pfi-sub-prd-02-use2-sql-mi-1001"
        [string]$FqdnSuffix    # e.g. "f5bb953edf71.database.windows.net"
                               # OR full FQDN already stored in config
    )

    # ✅ If FqdnSuffix already starts with the ServerName, it's already a full FQDN
    if ($FqdnSuffix -like "$ServerName.*") {
        Write-Verbose "FQDN already fully qualified — using as-is: $FqdnSuffix"
        return $FqdnSuffix
    }

    # ✅ If FqdnSuffix already ends with database.windows.net and contains dots, treat as full FQDN
    if ($FqdnSuffix -match "^[^.]+\..+\.database\.windows\.net$") {
        Write-Verbose "FqdnSuffix appears to be a full FQDN — using as-is: $FqdnSuffix"
        return $FqdnSuffix
    }

    # ✅ Otherwise, build: ServerName + "." + Suffix
    $resolved = "$ServerName.$FqdnSuffix"
    Write-Verbose "Constructed FQDN: $resolved"
    return $resolved
}

# ──────────────────────────────────────────────────
# BEFORE FIX (likely what your code looks like ~line 155-162):
# ──────────────────────────────────────────────────

# ❌ Old — blindly concatenates, causing duplication
# $fqdn = "$($server.Name).$($server.HostFqdn)"
# $connStr = "Server=$fqdn,1433;..."

# ──────────────────────────────────────────────────
# AFTER FIX — replace your connection block with this:
# ──────────────────────────────────────────────────

foreach ($server in @($primaryServer, $secondaryServer)) {

    # ✅ Safely resolve FQDN
    $fqdn = Get-MiFqdn -ServerName $server.Name -FqdnSuffix $server.HostFqdn

    Write-Host "[INFO] Connecting to: $fqdn" -ForegroundColor Cyan

    $connStr = "Server=$fqdn,1433;" +
               "Database=master;" +
               "Authentication=Active Directory Access Token;" +
               "Encrypt=True;" +
               "TrustServerCertificate=False;" +
               "Connection Timeout=30;"

    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = $connStr
    $conn.AccessToken = $server.AccessToken   # token acquired earlier

    try {
        $conn.Open()   # ← was line 162
        Write-Host "[SUCCESS] Connected to $($server.Name)" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] Connection failed to '$fqdn': $_" -ForegroundColor Red
        # Optional: continue to next server instead of terminating
        continue
    }
    finally {
        # Always close, even on error
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}
