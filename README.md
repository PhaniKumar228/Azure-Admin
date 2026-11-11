The restore failed due to active transactions from the application. I can see that the database files were already copied successfully; however, the restore process was unable to acquire the required database lock because of ongoing application connections and transactions.

Please confirm if we can proceed with terminating all active sessions and transactions so that we can perform the refresh. The database will be unavailable for approximately 15 minutes during the restore process. Once the restore is completed, application connectivity can be resumed.
