/* =====================================================================
   18-cutover-planned.sql
   Protocolo del cutover paso a paso. EJECUTAR MANUALMENTE cada bloque,
   validando el resultado antes de pasar al siguiente.

   NO ejecutar todo de una vez con sqlcmd -i.

   Cada bloque tiene marcadores BEGIN/END y un comentario con el T+min
   esperado. Ejecutar UN BLOQUE A LA VEZ y validar antes de seguir.

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/cutover-plan.md (§4)
   ===================================================================== */

/* =====================================================================
   T+0 — STOP WRITES EN LA APP
   ===================================================================== */
-- OPCION A (recomendada): feature flag en la app (externamente).
--   En la app, activar "db_readonly_mode = true"
--
-- OPCION B: poner BD en RESTRICTED_USER (drastica, kicked all non-admin sessions)
-- ALTER DATABASE [AppDb] SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;
--
-- OPCION C: parar el frontend de la app (load balancer, service stop) externamente.

-- Verificar que no hay writes activos:
USE master;
SELECT
    SUM(CASE WHEN command IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE') THEN 1 ELSE 0 END) AS write_requests,
    COUNT(*) AS total_requests
FROM sys.dm_exec_requests
WHERE database_id = DB_ID('AppDb');
-- Esperar a write_requests = 0 antes de seguir.

/* =====================================================================
   T+1 — CAMBIAR DAG A SYNC COMMIT (en vm-sql2017)
   ===================================================================== */
ALTER AVAILABILITY GROUP [DAG_Migrate]
MODIFY AVAILABILITY GROUP ON 'AG_SpainC' WITH (
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT
);
GO

ALTER AVAILABILITY GROUP [DAG_Migrate]
MODIFY AVAILABILITY GROUP ON 'AG_NorthEU' WITH (
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT
);
GO

/* =====================================================================
   T+2 — WAIT SYNCHRONIZED (bucle hasta SYNCHRONIZED)
   ===================================================================== */
-- Ejecutar repetidamente (cada 5s) hasta que ambas replicas devuelvan SYNCHRONIZED
SELECT
    ag.name,
    ar.replica_server_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.last_hardened_lsn,
    drs.last_commit_time
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = 'DAG_Migrate';

-- NO continuar hasta que TODAS las filas muestren synchronization_state_desc = 'SYNCHRONIZED'
-- Si tarda > 120 segundos, investigar antes de seguir.

/* =====================================================================
   T+3 — VERIFICACION FINAL DE LSN PARIDAD
   ===================================================================== */
-- En vm-sql2017 (capturar):
DECLARE @primary_lsn numeric(25,0);
SELECT @primary_lsn = last_hardened_lsn
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE ar.replica_server_name = 'vm-sql2017' AND drs.is_local = 1;
PRINT 'Primary LSN: ' + CAST(@primary_lsn AS varchar(50));

-- Ir a vm-sql2022 y ejecutar:
-- DECLARE @forwarder_lsn numeric(25,0);
-- SELECT @forwarder_lsn = last_hardened_lsn FROM sys.dm_hadr_database_replica_states drs
-- JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
-- WHERE ar.replica_server_name = 'vm-sql2022' AND drs.is_local = 1;
-- PRINT 'Forwarder LSN: ' + CAST(@forwarder_lsn AS varchar(50));
--
-- AMBOS LSN DEBEN COINCIDIR. Si no, NO continuar.

/* =====================================================================
   T+3.5 — PLANNED FAILOVER DEL DAG (DESDE vm-sql2022)
   ===================================================================== */
-- ATENCION: este comando se ejecuta DESDE vm-sql2022 (el target del failover).
-- Conectarse a vm-sql2022 y ejecutar:

-- Esta es la forma planned (sin perdida) con SYNC commit:
ALTER AVAILABILITY GROUP [DAG_Migrate] FAILOVER;
GO

-- Verificar role
SELECT
    ag.name,
    ar.replica_server_name,
    drs.is_local,
    drs.role_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = 'DAG_Migrate';
-- vm-sql2022 debe aparecer como PRIMARY ahora.

/* =====================================================================
   T+4 — HABILITAR BD EN SpainC (MULTI_USER si estaba restricted)
   ===================================================================== */
-- En vm-sql2022:
ALTER DATABASE [AppDb] SET MULTI_USER;
GO

-- Verificar:
SELECT state_desc, user_access_desc FROM sys.databases WHERE name = 'AppDb';
-- Esperado: ONLINE / MULTI_USER

/* =====================================================================
   T+4.5 — APP REPOINT (externamente)
   ===================================================================== */
-- Cambiar configuracion de la app para apuntar a vm-sql2022:
--   - Connection string update (kubectl set env, etc.)
--   - O cambio de feature flag "active_db = spainc"
--   - O cambio de DNS CNAME

/* =====================================================================
   T+5 — REVERTIR EL MODO DE WRITE BLOCK
   ===================================================================== */
-- Si usaste RESTRICTED_USER en vm-sql2017, ya no hace falta tocarlo
-- (la BD ahi quedara en estado RESOLVING/RECOVERY_PENDING — esperado).
-- Si usaste read-only mode/feature flag, desactivarlo:
--   flag "db_readonly_mode = false"

-- Reactivar servicios de app si fueron parados.

/* =====================================================================
   T+5 — SMOKE TEST INMEDIATO
   ===================================================================== */
-- En vm-sql2022:
SELECT @@SERVERNAME, DB_NAME(), GETUTCDATE();
-- Esperado: vm-sql2022, master, time ahora

USE [AppDb];
SELECT COUNT(*) AS rows_in_table FROM <tabla_principal>;  -- <ACTION>: cambiar tabla
-- Esperado: count razonable, dentro de tolerancia vs pre-cutover

-- Test write trivial (con rollback):
BEGIN TRAN;
INSERT INTO <tabla_writeable> VALUES (...);  -- <ACTION>
ROLLBACK;
-- Esperado: success

/* =====================================================================
   FIN CUTOVER PROTOCOL
   ===================================================================== */
-- Siguiente paso: scripts 19, 20, 21 para gestionar jobs y validar.
-- Si TODO va bien: anunciar GO en el canal de Slack y empezar stabilization.
-- Si algo va mal: activar [`rollback-plan.md`](rollback-plan.md) inmediatamente.
