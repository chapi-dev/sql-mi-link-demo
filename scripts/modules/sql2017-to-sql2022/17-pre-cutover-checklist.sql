/* =====================================================================
   17-pre-cutover-checklist.sql
   Health checks T-1h pre-cutover. Si CUALQUIER check falla, POSPONER
   el cutover.

   EJECUTAR EN vm-sql2017 EN T-1h.

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/cutover-plan.md (§3 T-1h)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

-- <ACTION>: ajustar
DECLARE @DbName     sysname = N'AppDb';
DECLARE @DagName    sysname = N'DAG_Migrate';

PRINT '========== PRE-CUTOVER CHECKLIST ==========';
PRINT 'Database: ' + @DbName;
PRINT 'DAG:      ' + @DagName;
PRINT 'Time:     ' + CONVERT(varchar(30), SYSDATETIMEOFFSET(), 121);
PRINT '';

-- ===== Check 1: DAG state =====
PRINT '----- CHECK 1: DAG state -----';
DECLARE @dagHealth sysname;
SELECT @dagHealth = synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = @DagName AND drs.is_local = 0;

SELECT
    'DAG state' AS check_name,
    ag.name,
    ar.replica_server_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.connected_state_desc,
    drs.log_send_queue_size AS send_kb,
    drs.redo_queue_size AS redo_kb,
    drs.last_commit_time,
    DATEDIFF(SECOND, drs.last_commit_time, GETUTCDATE()) AS lag_seconds
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id;

IF @dagHealth <> 'HEALTHY'
    PRINT 'WARNING: DAG NOT HEALTHY: ' + ISNULL(@dagHealth, 'NULL');
ELSE
    PRINT 'OK: DAG HEALTHY';
PRINT '';

-- ===== Check 2: Log send queue =====
PRINT '----- CHECK 2: Log send queue size -----';
DECLARE @sendKb bigint;
SELECT @sendKb = MAX(log_send_queue_size)
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 0;
IF @sendKb > 50000
    PRINT 'WARNING: log_send_queue_size = ' + CAST(@sendKb AS varchar(20)) + ' KB (umbral 50000)';
ELSE
    PRINT 'OK: log_send_queue_size = ' + ISNULL(CAST(@sendKb AS varchar(20)), '0') + ' KB';
PRINT '';

-- ===== Check 3: BD recovery model + state =====
PRINT '----- CHECK 3: Database state -----';
SELECT name, state_desc, recovery_model_desc, user_access_desc
FROM sys.databases WHERE name = @DbName;

DECLARE @state sysname;
SELECT @state = state_desc FROM sys.databases WHERE name = @DbName;
IF @state <> 'ONLINE'
    PRINT 'CRITICAL: Database state = ' + @state + ' (expected ONLINE)';
ELSE
    PRINT 'OK: Database ONLINE';
PRINT '';

-- ===== Check 4: Disk space (log + data) =====
PRINT '----- CHECK 4: Disk space -----';
SELECT
    mf.name AS file_name,
    mf.physical_name,
    mf.size * 8 / 1024 AS size_mb,
    FILEPROPERTY(mf.name, 'SpaceUsed') * 8 / 1024 AS used_mb,
    (mf.size - FILEPROPERTY(mf.name, 'SpaceUsed')) * 8 / 1024 AS free_mb,
    mf.growth, mf.is_percent_growth
FROM sys.master_files mf
JOIN sys.databases d ON d.database_id = mf.database_id
WHERE d.name = @DbName;
PRINT '';

-- ===== Check 5: Active sessions =====
PRINT '----- CHECK 5: Active sessions -----';
SELECT
    s.host_name, s.program_name, s.login_name,
    COUNT(*) AS session_count
FROM sys.dm_exec_sessions s
WHERE s.database_id = DB_ID(@DbName) AND s.is_user_process = 1
GROUP BY s.host_name, s.program_name, s.login_name
ORDER BY session_count DESC;
PRINT '';

-- ===== Check 6: Open transactions =====
PRINT '----- CHECK 6: Long-running transactions -----';
SELECT
    s.session_id, s.host_name, s.program_name, s.login_name,
    st.transaction_id,
    DATEDIFF(SECOND, st.transaction_begin_time, GETDATE()) AS tx_age_sec
FROM sys.dm_tran_session_transactions st
JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
WHERE s.database_id = DB_ID(@DbName)
  AND DATEDIFF(SECOND, st.transaction_begin_time, GETDATE()) > 60
ORDER BY st.transaction_begin_time;
PRINT '';

-- ===== Check 7: Backup history reciente =====
PRINT '----- CHECK 7: Recent backups (Capa 1 rollback) -----';
SELECT TOP 5
    bs.database_name,
    bs.type,
    bs.backup_finish_date,
    bmf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.database_name = @DbName
ORDER BY bs.backup_finish_date DESC;
PRINT '';

-- ===== Decision =====
PRINT '----- DECISION -----';
IF @dagHealth = 'HEALTHY' AND @sendKb < 50000 AND @state = 'ONLINE'
BEGIN
    PRINT '*** READY FOR CUTOVER ***';
    PRINT 'Siguiente paso: ejecutar protocolo de cutover (script 18-cutover-planned.sql).';
END
ELSE
BEGIN
    PRINT '*** NOT READY - POSPONER CUTOVER ***';
    PRINT 'Resolver issues arriba y re-ejecutar este check.';
END
