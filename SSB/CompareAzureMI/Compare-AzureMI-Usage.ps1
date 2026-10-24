.\Compare-AzureMI.ps1 -PrimaryMI "mi-prod-eastus-01" -SecondaryMI "mi-dr-eastus-01"

# Custom config + output path
.\Compare-AzureMI.ps1 -PrimaryMI "mi-prod-eastus-01" `
                      -SecondaryMI "mi-dr-eastus-01" `
                      -ConfigFilePath "C:\Configs\mi-config.json" `
                      -OutputPath "C:\Reports\audit.html"