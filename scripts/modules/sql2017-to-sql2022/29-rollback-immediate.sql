/* =====================================================================
   29-rollback-immediate.sql
   CAPA 3 del rollback plan: rollback inmediato post-failover.

   Aplica si estas en T+4.5min a T+1h. AG_NorthEU local sigue intacto
   con BD en estado RESTORING/RESOLVING. La BD nueva en SpainC ya
   recibio writes.

   EJECUTAR EN vm-sql2017.

   PERDIDA DE DATOS: las tx escritas en SpainC entre el failover y
   este rollback. Recuperarlas manualmente desde Query Store/log de
   SpainC (ver rollback-plan.md §4).

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/rollback-plan.md (§4)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

PRINT '========== ROLLBACK CAPA 3 — IMMEDIATE ROLLBACK ==========';
PRINT 'Pre-requisito: AG_NorthEU local intacto desde pre-cutover.';
PRINT '';

-- ===== Paso 1: capturar las tx escritas en SpainC para recovery manual =====
PRINT 'Paso 1: capturar tx escritas en SpainC desde el failover...';
PRINT '  Ir a vm-sql2022 y ejecutar:';
PRINT '    USE [AppDb];';
PRINT '    SELECT TOP 100';
PRINT '      qsq.query_id, qst.query_sql_text, qsrs.last_execution_time';
PRINT '    FROM sys.query_store_query qsq';
PRINT '    JOIN sys.query_store_query_text qst ON qst.query_text_id = qsq.query_text_id';
PRINT '    JOIN sys.query_store_runtime_stats qsrs ON qsrs.plan_id IN (';
PRINT '      SELECT plan_id FROM sys.query_store_plan WHERE query_id = qsq.query_id';
PRINT '    )';
PRINT '    WHERE qsrs.last_execution_time > <timestamp del failover>';
PRINT '    ORDER BY qsrs.last_execution_time DESC;';
PRINT '';
PRINT '  Guardar el output. Puede recuperarse manualmente si las tx son criticas.';
PRINT '';

-- ===== Paso 2: en vm-sql2022, congelar BD para evitar split-brain =====
PRINT 'Paso 2: en vm-sql2022, congelar BD:';
PRINT '  ALTER DATABASE [AppDb] SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;';
PRINT '  ALTER DATABASE [AppDb] SET READ_ONLY;';
PRINT '';

-- ===== Paso 3: sacar BD del AG_NorthEU =====
PRINT 'Paso 3: sacar BD del AG_NorthEU (estaba en estado RESTORING/RESOLVING)';
ALTER AVAILABILITY GROUP [AG_NorthEU]
REMOVE DATABASE [AppDb];
GO

-- ===== Paso 4: RECOVERY de la BD legacy =====
PRINT 'Paso 4: RESTORE WITH RECOVERY';
RESTORE DATABASE [AppDb] WITH RECOVERY;
GO

-- ===== Paso 5: verificar BD legacy ONLINE =====
SELECT name, state_desc, recovery_model_desc, user_access_desc
FROM sys.databases WHERE name = 'AppDb';
-- Esperado: ONLINE / MULTI_USER

-- ===== Paso 6: validar datos =====
USE [AppDb];
SELECT
    'AppDb on vm-sql2017' AS source,
    (SELECT COUNT(*) FROM sys.tables) AS table_count,
    GETUTCDATE() AS check_time;
GO

PRINT '';
PRINT '========== ROLLBACK CAPA 3 COMPLETADO ==========';
PRINT '';
PRINT 'Acciones manuales pendientes:';
PRINT '  1. App repoint de vuelta a vm-sql2017';
PRINT '  2. Re-enable jobs en vm-sql2017 (script reverso de 20-disable-jobs-northeu.sql)';
PRINT '  3. Documentar tx perdidas y comunicar al business';
PRINT '  4. Considerar recovery manual de tx criticas via Query Store/log de SpainC';
PRINT '';
PRINT 'RPO: tx escritas en SpainC entre failover y rollback (segundos-minutos)';
PRINT 'RTO: ~10-20 min total';
