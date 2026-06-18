/* =====================================================================
   12-create-local-ag-spainc.sql
   Crea el Availability Group local "AG_SpainC" en vm-sql2022
   (single-replica, clusterless, CLUSTER_TYPE = NONE).
   Sin BD inicial - se anyade despues con SET HADR AVAILABILITY GROUP.

   Pre-requisitos:
     - vm-sql2022 con Always On habilitado (script 02)
     - Endpoint Hadr_endpoint creado (script 05)
     - Cert exchange completado (script 06)
     - BD <AppDb> ya restaurada con NORECOVERY (script 09)

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/architecture.md (§1)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

-- <ACTION>: ajustar
DECLARE @AgName     sysname = N'AG_SpainC';
DECLARE @ServerFqdn sysname = N'vm-sql2022.spaincentral.cloudapp.azure.com';

-- Verificar Always On
IF SERVERPROPERTY('IsHadrEnabled') <> 1
BEGIN
    RAISERROR('Always On Availability Groups not enabled.', 16, 1);
    RETURN;
END

-- Verificar endpoint
IF NOT EXISTS (SELECT 1 FROM sys.tcp_endpoints WHERE name = 'Hadr_endpoint' AND state = 0)
BEGIN
    RAISERROR('Endpoint Hadr_endpoint must exist and be STARTED.', 16, 1);
    RETURN;
END

-- ===== Crear AG local single-replica SIN BD (FOR REPLICA solo) =====
IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = @AgName)
BEGIN
    PRINT 'AG ' + @AgName + ' ya existe. Saltando creacion.';
END
ELSE
BEGIN
    -- AG sin BD: usar FOR REPLICA ON sin FOR DATABASE
    DECLARE @sqlAg nvarchar(max) = N'
CREATE AVAILABILITY GROUP [' + @AgName + N']
WITH (
    CLUSTER_TYPE = NONE,
    FAILOVER_MODE = MANUAL,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    DB_FAILOVER = OFF,
    DTC_SUPPORT = NONE,
    AUTOMATED_BACKUP_PREFERENCE = PRIMARY,
    REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0
)
FOR REPLICA ON N''' + @ServerFqdn + N''' WITH (
    ENDPOINT_URL = N''TCP://' + @ServerFqdn + N':5022'',
    FAILOVER_MODE = MANUAL,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    SEEDING_MODE = MANUAL,
    BACKUP_PRIORITY = 50,
    SECONDARY_ROLE (ALLOW_CONNECTIONS = NO)
);';

    PRINT 'Creating AG (without DB)...';
    PRINT @sqlAg;
    EXEC sp_executesql @sqlAg;
    PRINT 'AG ' + @AgName + ' creado.';
END

-- ===== Permiso para CREATE ANY DATABASE (necesario para el seeding del DAG) =====
PRINT 'Granting CREATE ANY DATABASE on AG_SpainC...';
DECLARE @sqlGrant nvarchar(max) = N'ALTER AVAILABILITY GROUP [' + @AgName + N'] GRANT CREATE ANY DATABASE;';
EXEC sp_executesql @sqlGrant;

-- ===== Verificacion =====
SELECT
    ag.name,
    ar.replica_server_name,
    ar.endpoint_url,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ar.seeding_mode_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
WHERE ag.name = @AgName;

PRINT '';
PRINT '========== 12-create-local-ag-spainc.sql COMPLETADO ==========';
PRINT 'Siguiente paso: 13-create-distributed-ag.sql en vm-sql2017';
