SELECT name, state_desc, port, role_desc, connection_auth_desc, encryption_algorithm_desc
FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING';
 
SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled;
 
-- Who has CONNECT on the endpoint
SELECT sp.name AS grantee, pe.permission_name, pe.state_desc
FROM sys.server_permissions pe
JOIN sys.endpoints e ON pe.major_id = e.endpoint_id
JOIN sys.server_principals sp ON pe.grantee_principal_id = sp.principal_id
WHERE e.type_desc = 'DATABASE_MIRRORING';
