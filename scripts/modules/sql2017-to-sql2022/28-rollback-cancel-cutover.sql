/* =====================================================================
   28-rollback-cancel-cutover.sql
   CAPA 0 del rollback plan: cancelar el cutover ANTES del FAILOVER.

   Aplica si estas en T+0 a T+4.5min y aun NO ejecutaste
   ALTER ... FAILOVER. La BD nueva en SpainC todavia es secundaria.

   EJECUTAR EN vm-sql2017.

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/rollback-plan.md (§3)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

PRINT '========== ROLLBACK CAPA 0 — CANCEL CUTOVER ==========';
PRINT 'Pre-requisito: NO se ejecuto FAILOVER aun.';
PRINT '';

-- Devolver DAG a ASYNC (estado original)
ALTER AVAILABILITY GROUP [DAG_Migrate]
MODIFY AVAILABILITY GROUP ON 'AG_SpainC' WITH (
    AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT
);
GO

ALTER AVAILABILITY GROUP [DAG_Migrate]
MODIFY AVAILABILITY GROUP ON 'AG_NorthEU' WITH (
    AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT
);
GO

-- Sacar BD de RESTRICTED_USER si se aplico
ALTER DATABASE [AppDb] SET MULTI_USER;
GO

-- Verificar
SELECT
    ag.name, ar.replica_server_name,
    ar.availability_mode_desc,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_database_replica_states drs ON drs.replica_id = ar.replica_id;

SELECT name, state_desc, user_access_desc FROM sys.databases WHERE name = 'AppDb';

PRINT '';
PRINT '========== ROLLBACK CAPA 0 COMPLETADO ==========';
PRINT 'Estado restaurado al pre-cutover.';
PRINT 'Reactivar la app (feature flag, services start, etc).';
PRINT 'RPO = 0, RTO = ~3 min.';
