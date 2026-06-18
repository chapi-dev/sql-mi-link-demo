/* =====================================================================
   21-post-cutover-validate.sql
   Suite de validacion post-cutover (Capas A, B, C de post-migration-validation.md)

   EJECUTAR EN vm-sql2022 EN T+5min A T+30min POST-CUTOVER.

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/post-migration-validation.md
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

PRINT '========== POST-CUTOVER VALIDATION ==========';
PRINT 'Time: ' + CONVERT(varchar(30), SYSDATETIMEOFFSET(), 121);
PRINT '';

-- ===== CAPA A — Smoke tests funcionales =====
PRINT '----- CAPA A: Smoke tests -----';

-- A.1 Conectividad basica
SELECT
    @@SERVERNAME AS server_name,
    @@VERSION AS version,
    SYSDATETIMEOFFSET() AS now_utc;

-- A.2 BD accesible
USE [AppDb];  -- <ACTION>: cambiar nombre de BD
SELECT
    DB_NAME() AS db,
    (SELECT COUNT(*) FROM sys.tables) AS tables,
    (SELECT COUNT(*) FROM sys.procedures) AS procs,
    (SELECT COUNT(*) FROM sys.views) AS views,
    (SELECT COUNT(*) FROM sys.indexes WHERE is_disabled = 0) AS indexes;

-- A.3 Estado BD
SELECT
    name, state_desc, recovery_model_desc, compatibility_level,
    is_read_committed_snapshot_on, snapshot_isolation_state_desc,
    is_query_store_on
FROM sys.databases WHERE name = 'AppDb';
PRINT '';

-- ===== CAPA B — Paridad de datos =====
PRINT '----- CAPA B: Data parity (counts por tabla principal) -----';
SELECT
    SCHEMA_NAME(t.schema_id) + '.' + t.name AS table_name,
    ps.row_count
FROM sys.tables t
JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
WHERE ps.index_id IN (0, 1)
ORDER BY ps.row_count DESC;
-- COMPARAR esto manualmente con el output equivalente en vm-sql2017 pre-cutover.
PRINT '';

-- B.4 Tx en transit (debe ser 0 o solo housekeeping)
PRINT '----- CAPA B: Tx abiertas residuales -----';
SELECT
    st.session_id, s.host_name, s.program_name,
    st.transaction_id, s.last_request_start_time
FROM sys.dm_tran_session_transactions st
JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id;
PRINT '';

-- ===== CAPA C — Paridad funcional (smoke queries de negocio) =====
PRINT '----- CAPA C: Smoke queries -----';

-- <ACTION>: anyadir aqui 5-10 queries criticas de la app
/*
-- Ejemplo 1: top customers by revenue
SET STATISTICS TIME ON;
SELECT TOP 10 customer_id, SUM(order_total) AS total
FROM orders
GROUP BY customer_id ORDER BY total DESC;
SET STATISTICS TIME OFF;

-- Ejemplo 2: SP critico
EXEC dbo.GetOrdersByCustomer @customer_id = 12345;

-- Ejemplo 3: constraint test (deberia fallar)
BEGIN TRY
    INSERT INTO orders (customer_id) VALUES (-1);
END TRY
BEGIN CATCH
    PRINT 'OK constraint funciona: ' + ERROR_MESSAGE();
END CATCH;
*/

PRINT 'CAPA C: ejecutar manualmente las queries criticas de la app.';
PRINT '';

-- ===== Estado del DAG post-failover =====
PRINT '----- DAG post-failover state -----';
SELECT
    ag.name AS dag_name,
    ar.replica_server_name,
    drs.is_local,
    drs.role_desc,
    drs.operational_state_desc,
    drs.connected_state_desc,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id;
-- Esperado: vm-sql2022 con role_desc = PRIMARY
PRINT '';

-- ===== Top waits ultimas horas (indicador de problemas) =====
PRINT '----- Top wait stats (excluir benigns) -----';
SELECT TOP 10
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'BROKER_TASK_STOP','CHECKPOINT_QUEUE','CLR_AUTO_EVENT','DBMIRROR_EVENTS_QUEUE',
    'DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE','FT_IFTSHC_MUTEX',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION','HADR_WORK_QUEUE','KSOURCE_WAKEUP',
    'LAZYWRITER_SLEEP','LOGMGR_QUEUE','ONDEMAND_TASK_QUEUE','PWAIT_ALL_COMPONENTS_INITIALIZED',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE','SERVER_IDLE_CHECK','SLEEP_TASK',
    'SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'WAIT_FOR_RESULTS','WAITFOR','XE_DISPATCHER_JOIN','XE_DISPATCHER_WAIT','XE_TIMER_EVENT'
)
AND wait_time_ms > 0
ORDER BY wait_time_ms DESC;
PRINT '';

-- ===== Error log scan ultimas 2 horas =====
PRINT '----- Errores recientes en errorlog -----';
DECLARE @errors TABLE (LogDate datetime, ProcessInfo nvarchar(50), Text nvarchar(max));
INSERT @errors EXEC xp_readerrorlog 0, 1, NULL, NULL, NULL, NULL, N'DESC';
SELECT TOP 20 * FROM @errors
WHERE LogDate > DATEADD(HOUR, -2, GETDATE())
  AND Text LIKE '%error%'
  OR Text LIKE '%failed%'
  OR Text LIKE '%severity%';
PRINT '';

PRINT '========== 21-post-cutover-validate.sql COMPLETADO ==========';
PRINT 'Si todo OK: continuar a stabilization (T+30min GO/NO-GO).';
PRINT 'Si algo critico fallo: activar rollback-plan.md inmediatamente.';
