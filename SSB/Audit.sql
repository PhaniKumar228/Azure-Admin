Use Master
go
SELECT   sp.name as Account
,sp.[principal_id] as 'Account Principal ID'
      ,sp.[sid] as 'Account SID'
      ,sp.[type_desc] as 'Account Type'
      ,sp.[is_disabled] as 'Account Disabled'
      ,sl.denylogin as 'Account Deny Login'
      ,sl.hasaccess as 'Has Access'
      ,sp.[create_date] as 'Account Create Date'
      ,sp.[modify_date] as 'Account Modify Date'
      , LOGINPROPERTY(sp.name,'PasswordLastSetTime') as 'Account Last Password Change Date'
      ,sp.is_policy_checked as 'Enforce Windows Password Policies?'
      , sp.is_expiration_checked as 'Enforce Windows Expiration Policies?'
      , case when (PWDCOMPARE('',sp.password_hash)=1) then 'Yes' Else 'No' End as 'Blank Password?'
       FROM master.sys.sql_logins as sp LEFT JOIN
       master.sys.syslogins as sl
       on (sp.sid = sl.sid);

Use Master
go
SELECT  sp.name as Grantee
,sp.[principal_id] as 'Grantee Principal ID'
      ,sp.[sid] as 'Grantee SID'
      ,sp.[type_desc] as 'Grantee Type'
      ,sp.[is_disabled] as 'Grantee Disabled'
      ,sl.denylogin as 'Grantee Deny Login'
      ,sl.hasaccess as 'Has Access'
      ,sp.[create_date] as 'Grantee Create Date'
      ,sp.[modify_date] as 'Account Modify Date'
      , LOGINPROPERTY(sp.name,'PasswordLastSetTime') as 'Account Last Password Change Date'
      ,srm.permission_name as 'Granted Permission'
      , srm.class_desc as 'Securable Type'
      , Case when srm.class = 101 Then SUSER_NAME(srm.major_id) END as 'Securable'
      , srm.state_desc as 'State'
       FROM master.sys.server_permissions as srm, master.sys.server_principals as sp LEFT JOIN
       master.sys.syslogins as sl
       on (sp.sid = sl.sid)
WHERE (sp.[principal_id] = srm.grantee_principal_id);

----------------------------------------------------------------------------------------------------------
---------------------- Database Level 
----------------------------------------------------------------------------------------------------------

USE DBA
SELECT  sp3.name as 'Grantee Login'
,sp.name as Grantee
,sp.[principal_id] as 'Grantee Principal ID'
      ,sp.[sid] as 'Grantee SID'
      ,sp.[type_desc] as 'Grantee Type'
      ,sp3.[is_disabled] as 'Grantee Disabled'
      ,sl.denylogin as 'Grantee Deny Login'
      ,sl.hasaccess as 'Has Access'
      ,sp.[create_date] as 'Grantee Create Date'
      ,sp.[modify_date] as 'Account Modify Date'
      , LOGINPROPERTY(sp3.name,'PasswordLastSetTime') as 'Account Last Password Change Date'
      ,CASE WHEN su.islogin = 0 THEN 'N\A - Role'
      WHEN su.[hasdbaccess] = 0 THEN 'No'
      WHEN su.[hasdbaccess] = 1 THEN 'Yes' END as 'Has Database Access'
      ,sp2.name as 'Granted Role'
,sp2.[principal_id] as 'Role Principal ID'
      ,sp2.[sid] as 'Role SID'
      ,sp2.[create_date] as 'Role Create Date'
      ,sp2.[modify_date] as 'Role Modify Date'
       FROM sys.database_role_members as srm, sys.database_principals as sp2, sys.sysusers as su, sys.database_principals as sp LEFT JOIN
       master.sys.syslogins as sl
       on (sp.sid = sl.sid)
    LEFT JOIN master.sys.server_principals as sp3
    on (sp.sid = sp3.sid)
WHERE ((sp.[principal_id] = srm.member_principal_id) AND
(sp2.principal_id = srm.role_principal_id) AND
(sp.principal_id = su.uid));



USE dba
 SELECT  sp3.name as 'Grantee Login'
,sp.name as Grantee
,sp.[principal_id] as 'Grantee Principal ID'
      ,sp.[sid] as 'Grantee SID'
      ,sp.[type_desc] as 'Grantee Type'
      ,sp3.[is_disabled] as 'Grantee Disabled'
      ,sl.denylogin as 'Grantee Deny Login'
      ,sl.hasaccess as 'Has Access'
      ,sp.[create_date] as 'Grantee Create Date'
      ,sp.[modify_date] as 'Account Modify Date'
      , LOGINPROPERTY(sp3.name,'PasswordLastSetTime') as 'Account Last Password Change Date'
      ,CASE WHEN su.islogin = 0 THEN 'N\A - Role'
      WHEN su.[hasdbaccess] = 0 THEN 'No'
      WHEN su.[hasdbaccess] = 1 THEN 'Yes' END as 'Has Database Access'
      ,database_permissions.permission_name as 'Permission'
      ,database_permissions.state_desc as 'Permission State'
      ,CASE WHEN class = 0 THEN DB_NAME() WHEN class = 1
then case when minor_id = 0 then object_name(major_id) else (SELECT  object_name(object_id) + '.'+ name FROM sys.columns where object_id = database_permissions.major_id and column_id = database_permissions.minor_id)
end WHEN class = 3 THEN SCHEMA_NAME(major_id)
WHEN class = 4 THEN USER_NAME(major_id) END [Securable]
      ,CASE When ((database_permissions.class= 1) AND (database_permissions.minor_id <> 0)) then 'Column'
      WHEN ((database_permissions.class= 1) AND (database_permissions.minor_id = 0)) then 'Object'
      else database_permissions.class_desc END 'Securable Description'
       FROM sys.database_permissions database_permissions, sys.sysusers as su, sys.database_principals as sp LEFT JOIN
       master.sys.syslogins as sl
       on (sp.sid = sl.sid)
    LEFT JOIN master.sys.server_principals as sp3
    on (sp.sid = sp3.sid)
WHERE ((sp.[principal_id] = database_permissions.grantee_principal_id) AND
(sp.principal_id = su.uid));



USE dba
SELECT  sp.name as 'Database Owner'
,sp.[principal_id] as 'Database Owner Principal ID'
      ,sp.[sid] as 'Database Owner SID'
      ,sp.[type_desc] as 'Database Owner Type'
      ,sp.[is_disabled] as 'Database Owner Disabled'
      ,sl.denylogin as 'Database Owner Deny Login'
      ,sl.hasaccess as 'Has Access'
      ,sp.[create_date] as 'Database Owner Create Date'
      ,sp.[modify_date] as 'Database Owner Account Modify Date'
      , LOGINPROPERTY(sp.name,'PasswordLastSetTime') as 'Account Last Password Change Date'
      , db.name as 'Database'
       FROM master.sys.databases as db, master.sys.server_principals as sp LEFT JOIN
       master.sys.syslogins as sl
       on (sp.sid = sl.sid)
WHERE (db.owner_sid = sl.sid);



USE DBA
SELECT  sc.name as 'Schema Name'
    ,sc.schema_id as 'Schema ID'
    ,sp3.name as 'Schema Owner Login'
    ,sp.name as 'Schema Owner'
    ,sp.[principal_id] as 'Schema Owner Principal ID'
      ,sp.[sid] as 'Schema Owner SID'
      ,sp.[type_desc] as 'Schema Owner Type'
      ,sp3.[is_disabled] as 'Schema Owner Disabled'
      ,sl.denylogin as 'Schema Owner Deny Login'
      ,sl.hasaccess as 'Schema Owner Has Access'
      ,sp.[create_date] as 'Account Create Date'
      ,sp.[modify_date] as 'Account Modify Date'
      , LOGINPROPERTY(sp3.name,'PasswordLastSetTime') as 'Account Last Password Change Date'
      ,CASE WHEN su.islogin = 0 THEN 'N\A - Role'
      WHEN su.[hasdbaccess] = 0 THEN 'No'
      WHEN su.[hasdbaccess] = 1 THEN 'Yes' END as 'Has Database Access'
       FROM sys.schemas as sc  INNER JOIN sys.database_principals as sp ON sc.[principal_id] = sp.[principal_id]
        INNER JOIN sys.sysusers as su ON sp.[principal_id] = su.uid 
        LEFT JOIN sys.syslogins as sl on (sp.sid = sl.sid)
    LEFT JOIN master.sys.server_principals as sp3 on (sp.sid = sp3.sid);


