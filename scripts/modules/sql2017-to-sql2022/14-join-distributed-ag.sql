/* =====================================================================
   14-join-distributed-ag.sql
   Une AG_SpainC al Distributed AG "DAG_Migrate" y anyade la BD ya
   restaurada con NORECOVERY al AG_SpainC para empezar a recibir log.

   EJECUTAR EN vm-sql2022.

   Pre-requisitos:
     - DAG creado en vm-sql2017 (script 13)
     - AG_SpainC ya creado (script 12)
     - BD <AppDb> restaurada con NORECOVERY (script 09)

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/architecture.md (§6)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

-- <ACTION>: ajustar
DECLARE @DbName         sysname = N'AppDb';
DECLARE @DagName        sysname = N'DAG_Migrate';
DECLARE @AgNE           sysname = N'AG_NorthEU';
DECLARE @AgSC           sysname = N'AG_SpainC';
DECLARE @FqdnNE         sysname = N'vm-sql2017.northeurope.cloudapp.azure.com';
DECLARE @FqdnSC         sysname = N'vm-sql2022.spaincentral.cloudapp.azure.com';

-- Verificar BD restaurada con NORECOVERY
DECLARE @state sysname;
SELECT @state = state_desc FROM sys.databases WHERE name = @DbName;
IF @state IS NULL
BEGIN
    RAISERROR('Database %s does not exist. Ejecutar 09-restore-for-seeding.sql primero.', 16, 1, @DbName);
    RETURN;
END
IF @state <> 'RESTORING'
BEGIN
    RAISERROR('Database %s must be in RESTORING state. Actual: %s', 16, 1, @DbName, @state);
    RETURN;
END

-- ===== JOIN AG_SpainC al DAG =====
PRINT 'Joining AG_SpainC al DAG...';

DECLARE @sqlJoin nvarchar(max) = N'
ALTER AVAILABILITY GROUP [' + @DagName + N']
JOIN AVAILABILITY GROUP ON
    N''' + @AgNE + N''' WITH (
        LISTENER_URL = N''TCP://' + @FqdnNE + N':5022'',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = MANUAL
    ),
    N''' + @AgSC + N''' WITH (
        LISTENER_URL = N''TCP://' + @FqdnSC + N':5022'',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = MANUAL
    );';

PRINT @sqlJoin;
EXEC sp_executesql @sqlJoin;
PRINT 'AG_SpainC joined to DAG.';

-- ===== Anyadir la BD al AG_SpainC =====
-- La BD ya esta restaurada con NORECOVERY. Ahora la unimos al AG local.
PRINT '';
PRINT 'Adding database ' + @DbName + ' to AG_SpainC...';

DECLARE @sqlAddDb nvarchar(max) = N'
ALTER DATABASE [' + @DbName + N'] SET HADR AVAILABILITY GROUP = [' + @AgSC + N'];';

PRINT @sqlAddDb;
EXEC sp_executesql @sqlAddDb;
PRINT 'Database added to AG_SpainC.';

-- ===== Verificacion =====
-- Esperar unos segundos para que el DAG empiece a sincronizar
WAITFOR DELAY '00:00:10';

SELECT
    ag.name AS group_name,
    ag.is_distributed,
    ar.replica_server_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.connected_state_desc,
    drs.log_send_queue_size AS log_send_kb,
    drs.redo_queue_size AS redo_kb
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.replica_id = ar.replica_id;

PRINT '';
PRINT '========== 14-join-distributed-ag.sql COMPLETADO ==========';
PRINT '';
PRINT 'Ahora el DAG deberia empezar a sincronizar.';
PRINT 'Esperar 1-2 minutos y volver a ejecutar el SELECT anterior.';
PRINT '';
PRINT 'Estado esperado:';
PRINT '  synchronization_state_desc = SYNCHRONIZING (ASYNC)';
PRINT '  synchronization_health_desc = HEALTHY';
PRINT '  log_send_queue_size estabilizandose en valores bajos';
PRINT '';
PRINT 'Si despues de 5 min el estado es NOT SYNCHRONIZING:';
PRINT '  - revisar conectividad (Test-NetConnection puerto 5022)';
PRINT '  - revisar dm_hadr_automatic_seeding';
PRINT '  - revisar errorlog en ambas VMs';
PRINT '';
PRINT 'Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/troubleshooting.md';
