/* =====================================================================
   13-create-distributed-ag.sql
   Crea el Distributed AG "DAG_Migrate" entre AG_NorthEU (global primary)
   y AG_SpainC (forwarder), con MANUAL seeding (obligatorio cross-version
   2017->2022 segun MS Learn).

   EJECUTAR EN vm-sql2017 (global primary del DAG).

   Pre-requisitos:
     - AG_NorthEU creado con BD (script 11)
     - AG_SpainC creado SIN BD pero con GRANT CREATE ANY DATABASE (script 12)
     - BD restaurada con NORECOVERY en vm-sql2022 (script 09)
     - Cert exchange completado (script 06)

   Modo: ASYNCHRONOUS_COMMIT (recomendado, ver rpo-options.md modo A).
         Para SYNC, cambiar AVAILABILITY_MODE en ambas replicas.

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/official-microsoft-guidance.md (§2)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

-- <ACTION>: ajustar
DECLARE @DagName        sysname = N'DAG_Migrate';
DECLARE @AgNE           sysname = N'AG_NorthEU';
DECLARE @AgSC           sysname = N'AG_SpainC';
DECLARE @FqdnNE         sysname = N'vm-sql2017.northeurope.cloudapp.azure.com';
DECLARE @FqdnSC         sysname = N'vm-sql2022.spaincentral.cloudapp.azure.com';

-- Verificar pre-requisitos
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = @AgNE)
BEGIN
    RAISERROR('Local AG %s does not exist in this instance. Ejecutar script 11 primero.', 16, 1, @AgNE);
    RETURN;
END

-- ===== Crear Distributed AG =====
IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = @DagName)
BEGIN
    PRINT 'DAG ' + @DagName + ' ya existe. Saltando creacion.';
END
ELSE
BEGIN
    DECLARE @sqlDag nvarchar(max) = N'
CREATE AVAILABILITY GROUP [' + @DagName + N']
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
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

    PRINT 'Creating Distributed AG...';
    PRINT @sqlDag;
    EXEC sp_executesql @sqlDag;
    PRINT 'DAG ' + @DagName + ' creado.';
END

-- ===== Verificacion =====
SELECT
    ag.name AS dag_name,
    ag.is_distributed,
    ar.replica_server_name,
    ar.endpoint_url,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ar.seeding_mode_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
WHERE ag.is_distributed = 1;

PRINT '';
PRINT '========== 13-create-distributed-ag.sql COMPLETADO ==========';
PRINT '';
PRINT 'IMPORTANTE: El DAG esta creado pero AG_SpainC aun NO esta unido.';
PRINT 'Siguiente paso: 14-join-distributed-ag.sql en vm-sql2022 para unir AG_SpainC al DAG.';
