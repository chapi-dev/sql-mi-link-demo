/* =====================================================================
   19-enable-jobs-spainc.sql
   Habilita los SQL Agent jobs en vm-sql2022 post-cutover.
   Los jobs estaban DISABLED desde la migracion (script 10).

   EJECUTAR EN vm-sql2022 EN T+5min POST-CUTOVER.
   ===================================================================== */

USE msdb;
SET NOCOUNT ON;
GO

-- Listar jobs disabled
PRINT '----- Jobs actualmente disabled -----';
SELECT name, enabled FROM dbo.sysjobs WHERE enabled = 0 ORDER BY name;
PRINT '';

-- Habilitar todos los jobs no-system
DECLARE @cmd nvarchar(max) = N'';
SELECT @cmd = @cmd +
    'EXEC msdb.dbo.sp_update_job @job_name = N''' + REPLACE(name, '''', '''''') + ''', @enabled = 1;' + CHAR(13)
FROM dbo.sysjobs
WHERE enabled = 0
  AND name NOT LIKE 'syspolicy_%'
  AND name NOT LIKE 'sysmail_%';

PRINT '----- SQL a ejecutar -----';
PRINT @cmd;
PRINT '';

-- Ejecutar
EXEC sp_executesql @cmd;

PRINT '';
PRINT '----- Estado final -----';
SELECT
    'Total jobs' AS metric, COUNT(*) AS value FROM dbo.sysjobs
UNION ALL
SELECT 'Enabled', SUM(CAST(enabled AS int)) FROM dbo.sysjobs;

PRINT '';
PRINT '========== 19-enable-jobs-spainc.sql COMPLETADO ==========';
PRINT 'Siguiente paso: 20-disable-jobs-northeu.sql en vm-sql2017';
PRINT 'para evitar que se ejecuten jobs duplicados.';
