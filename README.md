
# Check SQL encryption settings
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*\MSSQLServer\SuperSocketNetLib'

# List server certificates
Get-ChildItem Cert:\LocalMachine\My |
Select Subject,Issuer,Thumbprint,NotAfter

# Check root CA trust
Get-ChildItem Cert:\LocalMachine\Root |
Select Subject

Get-ChildItem Cert:\LocalMachine\My |
Select Subject,Issuer,Thumbprint,NotAfter

Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*\MSSQLServer\SuperSocketNetLib'
