.\Test-AzureMI-SPN.ps1 `
    -SqlMIName "sqlmi-prod.public.123456.database.windows.net" `
    -DatabaseName "master" `
    -TenantId "11111111-2222-3333-4444-555555555555" `
    -ServicePrincipalId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" `
    -ServicePrincipalSecret "xxxxxxxxxxxxxxxxxxxxxxxx"


    ##
    SQL MI FQDN
Database Name
Service Principal (Client ID)
Service Principal Secret
Tenant ID



# Test a specific MI with a specific SPN
.\Test-AzureMI-SPN.ps1 `
    -HostFqdn "ssc-gts-pfi-sub-prd-01-use2-sql-mi-1001.f5bb953edf71.database.windows.net" `
    -SPNName "azspn-pfi-reportlogin-linnational-prod-01" `
    -DatabaseName "MyDatabase"

# With a custom config path
.\Test-AzureMI-SPN.ps1 `
    -HostFqdn "ssc-gts-pfi-sub-prd-02-cne-sql-mi-1001.a3cd812fbe92.database.windows.net" `
    -SPNName "azspn-pfi-reportlogin-linnational-prod-02" `
    -DatabaseName "MyDatabase" `
    -ConfigFilePath "C:\configs\mi-config.json"
