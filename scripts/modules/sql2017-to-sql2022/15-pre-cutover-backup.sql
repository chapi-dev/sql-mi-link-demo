/* =====================================================================
   15-pre-cutover-backup.sql
   Backup full + log de la BD T-24h antes del cutover, guardado en
   container 'cutover-backups'. Esto es la Capa 1 del plan de rollback.

   EJECUTAR EN vm-sql2017 EN T-24h.

   Pre-requisitos:
     - 03-create-storage.ps1 ejecutado (credential para 'cutover-backups')

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/rollback-plan.md (§5)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

-- <ACTION>: ajustar
DECLARE @DbName     sysname = N'AppDb';
DECLARE @StorageUrl nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/cutover-backups';
DECLARE @TimeStamp  nvarchar(20) = REPLACE(REPLACE(REPLACE(CONVERT(varchar(20), GETUTCDATE(), 120), '-', ''), ':', ''), ' ', '_');

DECLARE @FullUrl    nvarchar(500) = @StorageUrl + N'/' + @DbName + N'_PreCutover_' + @TimeStamp + N'_full.bak';
DECLARE @LogUrl     nvarchar(500) = @StorageUrl + N'/' + @DbName + N'_PreCutover_' + @TimeStamp + N'_log.trn';

-- BACKUP FULL con compresion y checksum
PRINT 'BACKUP FULL pre-cutover...';
DECLARE @sqlFull nvarchar(max) = N'
BACKUP DATABASE [' + @DbName + N']
TO URL = ''' + @FullUrl + N'''
WITH COMPRESSION, CHECKSUM, FORMAT,
     MAXTRANSFERSIZE = 4194304, BUFFERCOUNT = 64, STATS = 10,
     NAME = ''Pre-cutover full backup (Capa 1 rollback)'';';
EXEC sp_executesql @sqlFull;
PRINT 'Full backup: ' + @FullUrl;

-- BACKUP LOG
PRINT '';
PRINT 'BACKUP LOG pre-cutover...';
DECLARE @sqlLog nvarchar(max) = N'
BACKUP LOG [' + @DbName + N']
TO URL = ''' + @LogUrl + N'''
WITH COMPRESSION, CHECKSUM, FORMAT, STATS = 10,
     NAME = ''Pre-cutover log backup (Capa 1 rollback)'';';
EXEC sp_executesql @sqlLog;
PRINT 'Log backup: ' + @LogUrl;

-- Validacion: RESTORE VERIFYONLY
PRINT '';
PRINT 'Verifying backups...';
DECLARE @sqlVerifyFull nvarchar(max) = N'RESTORE VERIFYONLY FROM URL = ''' + @FullUrl + N''';';
DECLARE @sqlVerifyLog nvarchar(max) = N'RESTORE VERIFYONLY FROM URL = ''' + @LogUrl + N''';';
EXEC sp_executesql @sqlVerifyFull;
EXEC sp_executesql @sqlVerifyLog;

PRINT '';
PRINT '========== 15-pre-cutover-backup.sql COMPLETADO ==========';
PRINT 'URLs (GUARDAR para potencial rollback Capa 1):';
PRINT '  Full: ' + @FullUrl;
PRINT '  Log:  ' + @LogUrl;
PRINT '';
PRINT 'Siguiente paso: 16-pre-cutover-vm-snapshot.ps1 (Capa 2 rollback)';
