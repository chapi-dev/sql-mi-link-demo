/* =====================================================================
   20-disable-jobs-northeu.sql
   Deshabilita los SQL Agent jobs en vm-sql2017 post-cutover.
   Previene que se ejecuten jobs duplicados (NorthEU + SpainC).

   EJECUTAR EN vm-sql2017 EN T+5min POST-CUTOVER.
   ===================================================================== */

USE msdb;
SET NOCOUNT ON;
GO

-- Listar jobs enabled
PRINT '----- Jobs actualmente enabled (a deshabilitar) -----';
SELECT name, enabled FROM dbo.sysjobs WHERE enabled = 1 ORDER BY name;
PRINT '';

-- Deshabilitar todos los jobs (excepto system housekeeping)
DECLARE @cmd nvarchar(max) = N'';
SELECT @cmd = @cmd +
    'EXEC msdb.dbo.sp_update_job @job_name = N''' + REPLACE(name, '''', '''''') + ''', @enabled = 0;' + CHAR(13)
FROM dbo.sysjobs
WHERE enabled = 1
  AND name NOT LIKE 'syspolicy_%'
  AND name NOT LIKE 'sysmail_%'
  AND name NOT LIKE 'syscollector_%';

PRINT '----- SQL a ejecutar -----';
PRINT @cmd;
PRINT '';

-- Ejecutar
EXEC sp_executesql @cmd;

-- Estado final
PRINT '----- Estado final -----';
SELECT 'Enabled jobs in NorthEU' AS metric, SUM(CAST(enabled AS int)) AS value FROM dbo.sysjobs;

PRINT '';
PRINT '========== 20-disable-jobs-northeu.sql COMPLETADO ==========';
PRINT 'Jobs en NorthEU disabled. No se ejecutaran duplicados.';
PRINT 'NOTA: si rollback Capa 3 fuera necesario, re-habilitar manualmente.';
