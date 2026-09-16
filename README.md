Subject: Assistance Required: Upgrade.ini Review and SPN Authentication Testing

Hi Team,

We need your help reviewing the Upgrade.ini configuration.

During the PROD upgrade, we used an Azure SQL Login, which was enabled at that time, and the upgrade completed successfully. However, in BUAT, SQL authentication has now been disabled, and our testing is failing even though the same shortcut and configuration file structure are being used.

After disabling SQL Authentication in Azure, we tested the following authentication methods in the Upgrade.ini file, but none were successful:

Username & Password with hardcoded SPN ID and password
Username & Password with hardcoded SPN ID and BIN file
PAMUSERID & DBCredentials with hardcoded SPN ID and password
PAMUSERID & DBCredentials with hardcoded SPN ID and BIN file

Unfortunately, none of these approaches worked. At this point, it appears there may be a compatibility issue between the Upgrade.ini authentication mechanism and SPN-based authentication.

We have already worked with several team members to troubleshoot this, but have not been able to identify a solution.

Would you be available sometime today or tomorrow to help review and test this with us? Your expertise would be greatly appreciated.
