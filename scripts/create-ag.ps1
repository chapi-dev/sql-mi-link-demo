$ErrorActionPreference = 'Continue'

$sql = @"
USE master;
GO

PRINT '== Comprobar HADR =='
SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled, @@SERVERNAME AS Server;
GO

PRINT '== Drop AG existente si lo hubiera =='
IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = 'MILinkAG')
    DROP AVAILABILITY GROUP MILinkAG;
GO

PRINT '== Crear AG local single-replica (clusterless) ==';
CREATE AVAILABILITY GROUP [MILinkAG]
WITH (CLUSTER_TYPE = NONE)
FOR DATABASE [DemoLink]
REPLICA ON 
    N'VM-SQL2017' WITH (
        ENDPOINT_URL = N'TCP://10.10.1.4:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL),
        PRIMARY_ROLE (ALLOW_CONNECTIONS = ALL)
    );
GO

PRINT '== Verificar AG ==';
SELECT ag.name AS AG, ar.replica_server_name, ar.endpoint_url, ar.availability_mode_desc, ar.seeding_mode_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id;
GO

PRINT '== Estado DBs en AG ==';
SELECT ag.name AS AG, db.database_name, drs.synchronization_state_desc, drs.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_databases_cluster db ON db.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.group_id = ag.group_id AND drs.database_id = DB_ID(db.database_name);
GO
"@

$sql | Out-File "C:\MILink\create-ag.sql" -Encoding ASCII

Write-Output "=== Running CREATE AG ==="
$out = & sqlcmd -S . -E -b -i "C:\MILink\create-ag.sql" 2>&1
Write-Output "Exit code: $LASTEXITCODE"
$out | ForEach-Object { Write-Output $_ }
