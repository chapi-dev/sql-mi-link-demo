# Validación post-migración

Suite de verificaciones que confirman que **vm-sql2022 funciona como o mejor que vm-sql2017**
después del cutover. Sin esta validación, no se puede declarar el cutover exitoso ni iniciar
las acciones de [`post-cutover-strategies.md`](post-cutover-strategies.md).

> 📘 Ejecutar **T+1h, T+24h, T+72h** post-cutover. Documentar resultados en el log de
> migración.

---

## 1. Estructura de la validación

| Capa | Qué valida | Cuándo | Bloqueante |
|---|---|---|---|
| **A** Smoke tests funcionales | "La app conecta y responde" | T+5min | 🔴 sí |
| **B** Paridad de datos | "Los datos están todos" | T+30min | 🔴 sí |
| **C** Paridad funcional | "Las features de la app funcionan" | T+1h | 🔴 sí |
| **D** Performance baseline | "No estamos peor que antes" | T+4h | 🟠 mid |
| **E** Out-of-band objects | "Logins/jobs/linked servers funcionan" | T+24h | 🔴 sí |
| **F** Validación extendida | "Tras 72h sigue todo OK" | T+72h | 🟡 ratificación |

Solo cuando **A, B, C, E** pasan completamente, se declara el cutover exitoso.

---

## 2. Capa A — Smoke tests funcionales (T+5min)

### A.1 Conectividad básica

```sql
-- Desde sqlcmd o SSMS conectado a vm-sql2022:
SELECT @@SERVERNAME AS server,
       @@VERSION AS version,
       SYSDATETIMEOFFSET() AS now_utc,
       DB_NAME() AS current_db;
-- Esperado:
-- server = vm-sql2022
-- version contiene 'Microsoft SQL Server 2022'
-- current_db = master (o lo que se haya seteado en la conexion)
```

### A.2 Base de datos accesible

```sql
USE [AppDb];
SELECT @@SERVERNAME, DB_NAME(),
       (SELECT COUNT(*) FROM sys.tables) AS table_count,
       (SELECT COUNT(*) FROM sys.procedures) AS proc_count,
       (SELECT COUNT(*) FROM sys.views) AS view_count;
```

Esperado: counts iguales o muy próximos a los de vm-sql2017.

### A.3 Estado de la BD

```sql
SELECT
    name,
    state_desc,
    recovery_model_desc,
    compatibility_level,
    is_read_committed_snapshot_on,
    snapshot_isolation_state_desc,
    is_query_store_on
FROM sys.databases
WHERE name = 'AppDb';
```

Esperado:
- `state_desc = ONLINE`
- `recovery_model_desc = FULL`
- `compatibility_level = 140` (heredado del 2017 — **NO subir** en T+5min, esperar T+72h+)
- Otros parámetros: igual al original.

### A.4 La app reconecta

Desde un endpoint de la app (HTTP, etc.):
```bash
curl -i https://<app>.com/health
# Esperado: 200 OK
```

O conectarse al SQL desde la app:
```bash
# Si la app tiene un cli de prueba
app-cli ping-db
# Esperado: respuesta sub-segundo
```

---

## 3. Capa B — Paridad de datos (T+30min)

### B.1 Conteos de filas por tabla principal

```sql
-- En vm-sql2022 (destino):
USE [AppDb];
SELECT
    SCHEMA_NAME(t.schema_id) + '.' + t.name AS table_name,
    ps.row_count
FROM sys.tables t
JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
WHERE ps.index_id IN (0, 1)
ORDER BY ps.row_count DESC;
```

Comparar con el output equivalente en vm-sql2017 **pre-cutover** (capturado durante T-1h
del [`cutover-plan.md`](cutover-plan.md)).

**Tolerancia**: tablas activas pueden diferir en ±10-100 filas (tx finales antes del drain).
Diferencia mayor → investigar.

### B.2 Checksums por tabla crítica

Para tablas más importantes (top 10 por criticidad de negocio):

```sql
-- Genera un checksum agregado (no perfecto, pero detecta divergencias)
SELECT
    'CRC' = SUM(CAST(BINARY_CHECKSUM(*) AS BIGINT)),
    'cnt' = COUNT(*)
FROM <schema>.<tabla_critica>;
```

Capturar en NorthEU pre-cutover y en SpainC post-cutover. Deben coincidir exactamente.

### B.3 Última transacción aplicada

```sql
-- En vm-sql2022
SELECT
    MAX([timestamp_col]) AS last_tx_destino
FROM <tabla_con_timestamp>;
```

Comparar con vm-sql2017:
- Si SpainC tiene **timestamps más recientes** → algo va mal (replicación dual?).
- Si SpainC tiene **timestamps anteriores al cutover** → falta drain de log; investigar.
- Si SpainC tiene **timestamps justo en el cutover** → ✅ correcto.

### B.4 Filas en transit (validación negativa)

```sql
-- En vm-sql2022 — buscar sesiones con tx abiertas residuales
SELECT
    st.session_id, s.host_name, s.program_name,
    st.transaction_id,
    s.last_request_start_time
FROM sys.dm_tran_session_transactions st
JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id;
```

Esperado: vacío o solo tx de mantenimiento de SQL Server.

---

## 4. Capa C — Paridad funcional (T+1h)

### C.1 Suite de queries de negocio

Ejecutar las **5-10 queries críticas** de la app:

```sql
-- Ejemplo: top customers
SELECT TOP 10 customer_id, SUM(order_total) AS total
FROM orders
GROUP BY customer_id
ORDER BY total DESC;

-- Comparar resultados Y tiempo de ejecucion con el baseline pre-cutover.
```

Aceptable:
- Resultados **idénticos** (mismas filas, mismos valores).
- Tiempo dentro de **2× baseline**.

### C.2 Stored procedures críticos

```sql
-- Ejecutar los SPs mas usados con parametros realistas
EXEC dbo.GetOrdersByCustomer @customer_id = 12345;
EXEC dbo.CalculateInvoice @order_id = 67890;
```

Esperado: ejecutan sin error, devuelven mismo output, en tiempo similar.

### C.3 Triggers funcionan

```sql
-- Hacer una insertion/update/delete que debería disparar triggers
BEGIN TRAN;
INSERT INTO <tabla_con_trigger> VALUES (...);
-- Verificar efecto del trigger
SELECT * FROM <tabla_audit> WHERE op_timestamp >= GETUTCDATE() - <hora>;
ROLLBACK;
```

### C.4 Constraints funcionan

```sql
-- Probar constraint violation deliberada (deberia fallar)
BEGIN TRY
    INSERT INTO <tabla_con_FK> (cliente_id) VALUES (-1);  -- FK invalida
    PRINT '❌ FAIL: constraint no aplicada';
END TRY
BEGIN CATCH
    PRINT '✅ OK: constraint funciona — ' + ERROR_MESSAGE();
END CATCH;
```

### C.5 Computed columns / Indexed views

```sql
-- Si existen, validar que computan correctamente
SELECT TOP 5 id, <computed_column> FROM <tabla> WHERE <computed_column> IS NOT NULL;
```

### C.6 Funcionalidad de aplicación end-to-end

Coordinarse con el owner de la app para ejecutar el **happy path** completo:
1. Login de usuario.
2. Operación principal (create order, etc.).
3. Lectura.
4. Logout.

Si tiene **smoke test suite automatizada**, ejecutarla. Ejemplos:
- pytest -m smoke
- npm run test:smoke
- jenkins build pipeline "smoke"

---

## 5. Capa D — Performance baseline (T+4h)

### D.1 Query Store — comparación pre/post

```sql
-- En vm-sql2022 (Query Store ON desde el cutover):
USE [AppDb];
WITH recent AS (
    SELECT
        qsq.query_id,
        qst.query_sql_text,
        AVG(qsrs.avg_duration / 1000.0) AS avg_ms,
        MAX(qsrs.max_duration / 1000.0) AS max_ms,
        SUM(qsrs.count_executions) AS execs
    FROM sys.query_store_query qsq
    JOIN sys.query_store_query_text qst ON qst.query_text_id = qsq.query_text_id
    JOIN sys.query_store_plan qsp ON qsp.query_id = qsq.query_id
    JOIN sys.query_store_runtime_stats qsrs ON qsrs.plan_id = qsp.plan_id
    WHERE qsrs.last_execution_time > DATEADD(hour, -4, GETUTCDATE())
    GROUP BY qsq.query_id, qst.query_sql_text
)
SELECT TOP 20 *
FROM recent
WHERE execs > 10
ORDER BY avg_ms DESC;
```

Si tenías Query Store en el 2017, exporta esos stats y comparados (avg, max, count).

**Umbral aceptable**: `avg_ms_post / avg_ms_pre < 2.0` para queries críticas.

### D.2 Wait stats

```sql
-- Top waits en las ultimas 4h
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'BROKER_TASK_STOP', 'CHECKPOINT_QUEUE', 'CLR_AUTO_EVENT',
    'DBMIRROR_EVENTS_QUEUE', 'DIRTY_PAGE_POLL', 'DISPATCHER_QUEUE_SEMAPHORE',
    'FT_IFTSHC_MUTEX', 'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'HADR_WORK_QUEUE', 'KSOURCE_WAKEUP', 'LAZYWRITER_SLEEP', 'LOGMGR_QUEUE',
    'ONDEMAND_TASK_QUEUE', 'PWAIT_ALL_COMPONENTS_INITIALIZED', 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', 'REQUEST_FOR_DEADLOCK_SEARCH',
    'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK', 'SLEEP_BPOOL_FLUSH', 'SLEEP_DBSTARTUP',
    'SLEEP_DCOMSTARTUP', 'SLEEP_MASTERDBREADY', 'SLEEP_MASTERMDREADY',
    'SLEEP_MASTERUPGRADED', 'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK',
    'SLEEP_TASK', 'SLEEP_TEMPDBSTARTUP', 'SNI_HTTP_ACCEPT',
    'SP_SERVER_DIAGNOSTICS_SLEEP', 'SQLTRACE_BUFFER_FLUSH',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'SQLTRACE_WAIT_ENTRIES',
    'WAIT_FOR_RESULTS', 'WAITFOR', 'WAITFOR_TASKSHUTDOWN', 'WAIT_XTP_HOST_WAIT',
    'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', 'WAIT_XTP_CKPT_CLOSE', 'XE_DISPATCHER_JOIN',
    'XE_DISPATCHER_WAIT', 'XE_TIMER_EVENT'
)
ORDER BY wait_time_ms DESC;
```

Esperado:
- No aparece `HADR_*` waits significativos (DAG sano).
- No aparece `PAGEIOLATCH_*` extremo (storage sano).
- `LCK_*` similar al baseline NorthEU.

### D.3 CPU / Memory / IO (a nivel VM)

```powershell
# Desde Azure Monitor o portal
az monitor metrics list --resource <vm-sql2022-id> `
    --metric "Percentage CPU,Available Memory Bytes,Disk Read Bytes,Disk Write Bytes" `
    --interval PT1M --start-time (Get-Date).AddHours(-4).ToString("yyyy-MM-ddTHH:mm:ssZ") `
    -o table
```

Comparar con baseline NorthEU mismo periodo (capturado pre-cutover).

### D.4 Latencia I/O por archivo

```sql
SELECT
    DB_NAME(vfs.database_id) AS db,
    mf.name AS file_name,
    mf.physical_name,
    vfs.num_of_reads,
    vfs.io_stall_read_ms,
    CAST(vfs.io_stall_read_ms / NULLIF(vfs.num_of_reads, 0) AS DECIMAL(10,2)) AS avg_read_ms,
    vfs.num_of_writes,
    vfs.io_stall_write_ms,
    CAST(vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(10,2)) AS avg_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
WHERE DB_NAME(vfs.database_id) = 'AppDb'
ORDER BY avg_read_ms DESC;
```

Umbral aceptable: avg_read_ms < 10 ms, avg_write_ms < 5 ms (para Premium SSD v2).

---

## 6. Capa E — Out-of-band objects (T+24h)

Re-ejecutar el **checklist final** de [`out-of-band-objects.md`](out-of-band-objects.md) §17.

Lo crítico:

```sql
-- Logins (count + spot check de SIDs)
SELECT COUNT(*) FROM sys.server_principals WHERE type IN ('S','U','G');

-- Jobs (count + enabled)
SELECT COUNT(*), SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END) AS enabled
FROM msdb.dbo.sysjobs;

-- Linked servers (count + test connection)
SELECT COUNT(*) FROM sys.servers WHERE is_linked = 1;
-- Para cada uno: EXEC sp_testlinkedserver '<name>';

-- Credentials
SELECT COUNT(*) FROM sys.credentials;

-- Database Mail (test)
EXEC msdb.dbo.sp_send_dbmail @profile_name='<>', @recipients='<>', @subject='post-cutover test', @body='ok';
```

### E.1 Jobs ejecutados con éxito

```sql
-- Ver historial de jobs en las ultimas 24h
SELECT TOP 50
    j.name,
    jh.run_date, jh.run_time,
    jh.run_duration / 100 AS duration_sec,
    CASE jh.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Cancelled'
        WHEN 4 THEN 'In Progress'
    END AS status,
    jh.message
FROM msdb.dbo.sysjobhistory jh
JOIN msdb.dbo.sysjobs j ON j.job_id = jh.job_id
WHERE jh.step_id = 0  -- job-level result
  AND CONVERT(datetime, CAST(jh.run_date AS varchar(8)) + ' ' + STUFF(STUFF(RIGHT('000000' + CAST(jh.run_time AS varchar(6)), 6), 5, 0, ':'), 3, 0, ':'))
      > DATEADD(hour, -24, GETDATE())
ORDER BY jh.run_date DESC, jh.run_time DESC;
```

Esperado: jobs críticos ejecutándose en su schedule, con `Succeeded`.

---

## 7. Capa F — Validación extendida (T+72h)

### F.1 Tendencia de errores

Revisar:
- Application Insights / app logs: ¿tasa de errores 5xx vuelve al baseline?
- SQL Error Log: ¿errores nuevos no vistos antes?
```sql
EXEC xp_readerrorlog 0, 1;  -- ver errorlog actual
```

### F.2 Query regressions (Query Store)

```sql
-- Queries con regresion clara post-cutover
WITH after AS (
    SELECT qsq.query_id, AVG(qsrs.avg_duration) AS avg_after
    FROM sys.query_store_query qsq
    JOIN sys.query_store_plan qsp ON qsp.query_id = qsq.query_id
    JOIN sys.query_store_runtime_stats qsrs ON qsrs.plan_id = qsp.plan_id
    WHERE qsrs.last_execution_time > DATEADD(hour, -24, GETUTCDATE())
    GROUP BY qsq.query_id
),
baseline AS (
    SELECT qsq.query_id, AVG(qsrs.avg_duration) AS avg_baseline
    FROM sys.query_store_query qsq
    JOIN sys.query_store_plan qsp ON qsp.query_id = qsq.query_id
    JOIN sys.query_store_runtime_stats qsrs ON qsrs.plan_id = qsp.plan_id
    WHERE qsrs.last_execution_time BETWEEN DATEADD(hour, -72, GETUTCDATE()) AND DATEADD(hour, -24, GETUTCDATE())
    GROUP BY qsq.query_id
)
SELECT TOP 20
    qst.query_sql_text,
    b.avg_baseline / 1000.0 AS baseline_ms,
    a.avg_after / 1000.0 AS after_ms,
    (a.avg_after - b.avg_baseline) / NULLIF(b.avg_baseline, 0) * 100.0 AS pct_change
FROM after a
JOIN baseline b ON b.query_id = a.query_id
JOIN sys.query_store_query qsq ON qsq.query_id = a.query_id
JOIN sys.query_store_query_text qst ON qst.query_text_id = qsq.query_text_id
WHERE a.avg_after > b.avg_baseline * 1.5  -- regresion > 50%
ORDER BY pct_change DESC;
```

Si hay regresiones, considerar:
- `ALTER DATABASE [AppDb] SET QUERY_STORE ... FORCE_LAST_GOOD_PLAN = ON;`
- O forzar plan específico via `sp_query_store_force_plan`.

### F.3 Disk space trend

```sql
SELECT
    DB_NAME(database_id) AS db,
    name,
    size * 8 / 1024 AS size_mb,
    FILEPROPERTY(name, 'SpaceUsed') * 8 / 1024 AS used_mb,
    (size - FILEPROPERTY(name, 'SpaceUsed')) * 8 / 1024 AS free_mb
FROM sys.master_files
WHERE database_id = DB_ID('AppDb');
```

Monitorizar crecimiento. Si grows abruptamente post-cutover, investigar (¿algún job
descontrolado? ¿auto-shrink desactivado?).

### F.4 Backups regulares funcionan

```sql
-- Ultimos backups por tipo
SELECT
    bs.database_name,
    bs.type,  -- D=full, I=diff, L=log
    MAX(bs.backup_finish_date) AS last_backup
FROM msdb.dbo.backupset bs
WHERE bs.database_name = 'AppDb'
GROUP BY bs.database_name, bs.type;
```

- Full: dentro de las últimas 24h o según política.
- Log: dentro de las últimas 1h o según política.

### F.5 Decisión: ratificar GO

War room T+72h:
- ¿Métricas estables o mejoran?
- ¿Ningún incidente crítico?
- ¿Negocio reporta funcionamiento normal?

Si todo ✅:
- **Ratificar GO** del cutover.
- Empezar a ejecutar la estrategia post-cutover elegida ([`post-cutover-strategies.md`](post-cutover-strategies.md)).
- Considerar subir `compatibility_level` a 160 (SQL 2022) — opcional, ver below.

---

## 8. (Opcional) Subir compatibility level a 160

A T+72h+ y con todo estable, puede considerarse:

```sql
ALTER DATABASE [AppDb] SET COMPATIBILITY_LEVEL = 160;
```

**Beneficios**:
- Intelligent Query Processing features (memory grant feedback persistence, etc.).
- Parameter sensitive plan optimization.
- Optimized plan forcing.

**Riesgos**:
- Plans pueden recompilarse y elegir nuevos plans subóptimos.
- Algunos behavioral changes pueden afectar queries específicas.

**Mitigación**:
1. Hacer baseline de Query Store **antes** de subir.
2. Subir el compat level.
3. Monitorizar 24h con `FORCE_LAST_GOOD_PLAN` activado (rollback automático de plans
   peores).
4. Si todo OK, dejar permanente.

> ⚠️ **No subir antes de T+72h**. Si necesitas rollback Capa 4 (BACPAC), un compat level 160
> dificulta importar en SQL 2017.

---

## 9. Plantilla de reporte final de validación

```markdown
# Reporte de validación post-cutover SQL 2017→2022

Fecha cutover: <YYYY-MM-DD HH:MM>
Fecha reporte: <YYYY-MM-DD HH:MM>
Cliente: <...>

## Resumen ejecutivo
| Capa | Resultado |
|---|---|
| A — Smoke | ✅ / ❌ |
| B — Datos | ✅ / ❌ |
| C — Funcional | ✅ / ❌ |
| D — Performance | ✅ / ⚠️ / ❌ |
| E — OOB | ✅ / ❌ |
| F — Extendida 72h | ✅ / ⚠️ / ❌ |

**Decisión: GO / NO-GO**

## Métricas clave
- Cutover real: <X> min (objetivo: 5 min)
- Errores HTTP post-cutover: <Y>% (umbral: < 5%)
- Latencia P95 query critica: <Z> ms (pre: <A> ms, factor: <Z/A>x)
- Jobs ejecutados con exito: <N>/<Total>
- Logins migrados: <N>/<Total>

## Issues encontrados
| Severity | Descripción | Resolución |
|---|---|---|
| ... | ... | ... |

## Acciones de seguimiento
- ...

## Estrategia post-cutover ejecutándose
- A) Decommission / B) Upgrade in-place / C) Pivot MI / D) UAT
```

---

## Referencias

- [`out-of-band-objects.md`](out-of-band-objects.md) — para Capa E
- [`cutover-plan.md`](cutover-plan.md) — para baseline pre-cutover
- [Query Store usage scenarios](https://learn.microsoft.com/sql/relational-databases/performance/query-store-usage-scenarios)
- [Post-migration validation guide](https://learn.microsoft.com/sql/relational-databases/post-migration-validation-and-optimization-guide)
- [DBCC CHECKDB](https://learn.microsoft.com/sql/t-sql/database-console-commands/dbcc-checkdb-transact-sql) — para validación de integridad
