---- Step 2 - Extract Server Logins

EXEC master.dbo.sp_SrvPermissions
     @IncludeMSShipped = 0,
     @Output = 'CreateOnly'

---- Step 4 - Extract Specific Login

EXEC master.dbo.sp_SrvPermissions
     @Principal='AppUser'

--- Step 5 - Extract All Database Permissions

EXEC master.dbo.sp_DBPermissions
     @DBName='SalesDB'

--- Step 6 - Generate Migration Scripts Only

EXEC master.dbo.sp_DBPermissions
     @DBName='SalesDB',
     @Output='CreateOnly'

---- Step 7 - Migrate Single User

EXEC master.dbo.sp_DBPermissions
     @DBName='SalesDB',
     @Principal='AppUser'

---- Step 8 - Copy Permissions to New Login

EXEC master.dbo.sp_DBPermissions
     @DBName='SalesDB',
     @Principal='DOMAIN\AppOld',
     @CopyTo='DOMAIN\AppNew'

--- Step 9 - Extract All Security from Entire Instance

EXEC master.dbo.sp_DBPermissions
     @DBName='All',
     @Output='Report'

---- Step 10 - Generate Complete Security Migration Package

EXEC master.dbo.sp_SrvPermissions
     @IncludeMSShipped=0,
     @Output='CreateOnly'

EXEC master.dbo.sp_DBPermissions
     @DBName='SalesDB',
     @Output='CreateOnly'

--- Orphaned User Detection (Very Useful After Restore)
EXEC master.dbo.sp_DBPermissions
     @DBName='SalesDB',
     @ShowOrphans=1




