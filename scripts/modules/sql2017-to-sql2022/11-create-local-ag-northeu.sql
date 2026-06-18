/* =====================================================================
   11-create-local-ag-northeu.sql
   Crea el Availability Group local "AG_NorthEU" en vm-sql2017
   (single-replica, clusterless, CLUSTER_TYPE = NONE).
   Este AG sirve solo como contenedor para que el Distributed AG pueda
   referenciar la BD.

   Pre-requisitos:
     - vm-sql2017 con Always On habilitado
     - Endpoint Hadr_endpoint creado (5022, cert auth) - asume modulo MI Link existente
     - BD <AppDb> en FULL recovery con al menos un backup full hecho

   IMPORTANTE: si ya existe AG "MILinkAG" del modulo MI Link, NO usarlo.
   Crear uno separado o pausar MI Link durante esta migracion.

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/architecture.md (§1)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

-- <ACTION>: ajustar
DECLARE @DbName     sysname = N'AppDb';
DECLARE @AgName     sysname = N'AG_NorthEU';
DECLARE @ServerFqdn sysname = N'vm-sql2017.northeurope.cloudapp.azure.com';

-- Verificar que la BD esta en FULL recovery
DECLARE @rec sysname;
SELECT @rec = recovery_model_desc FROM sys.databases WHERE name = @DbName;
IF @rec <> 'FULL'
BEGIN
    RAISERROR('Database %s must be in FULL recovery mode. Actual: %s', 16, 1, @DbName, @rec);
    RETURN;
END

-- Verificar Always On
IF SERVERPROPERTY('IsHadrEnabled') <> 1
BEGIN
    RAISERROR('Always On Availability Groups not enabled on this instance.', 16, 1);
    RETURN;
END

-- Verificar endpoint
IF NOT EXISTS (SELECT 1 FROM sys.tcp_endpoints WHERE name = 'Hadr_endpoint' AND state = 0)
BEGIN
    RAISERROR('Endpoint Hadr_endpoint must exist and be STARTED.', 16, 1);
    RETURN;
END

-- ===== Crear AG local single-replica =====
IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = @AgName)
BEGIN
    PRINT 'AG ' + @AgName + ' ya existe. Saltando creacion.';
END
ELSE
BEGIN
    DECLARE @sqlAg nvarchar(max) = N'
CREATE AVAILABILITY GROUP [' + @AgName + N']
WITH (
    CLUSTER_TYPE = NONE,
    FAILOVER_MODE = MANUAL,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    DB_FAILOVER = OFF,
    DTC_SUPPORT = NONE,
    AUTOMATED_BACKUP_PREFERENCE = PRIMARY
)
FOR DATABASE [' + @DbName + N']
REPLICA ON N''' + @ServerFqdn + N''' WITH (
    ENDPOINT_URL = N''TCP://' + @ServerFqdn + N':5022'',
    FAILOVER_MODE = MANUAL,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    SEEDING_MODE = MANUAL,
    BACKUP_PRIORITY = 50,
    SECONDARY_ROLE (ALLOW_CONNECTIONS = NO)
);';

    PRINT 'Creating AG...';
    PRINT @sqlAg;
    EXEC sp_executesql @sqlAg;
    PRINT 'AG ' + @AgName + ' creado.';
END

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

SELECT
    ag.name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.dm_hadr_database_replica_states drs ON drs.group_id = ag.group_id
WHERE ag.name = @AgName;

PRINT '';
PRINT '========== 11-create-local-ag-northeu.sql COMPLETADO ==========';
PRINT 'Siguiente paso: 12-create-local-ag-spainc.sql en vm-sql2022';
