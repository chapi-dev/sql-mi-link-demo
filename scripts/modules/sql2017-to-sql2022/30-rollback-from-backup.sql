/* =====================================================================
   30-rollback-from-backup.sql
   CAPA 1 del rollback plan: restore desde backup pre-cutover en Blob.

   Aplica si:
     - AG_NorthEU ya fue tocado y no puedes usar Capa 3
     - Pasaron horas o dias desde el cutover
     - Necesitas restaurar el estado a pre-cutover

   EJECUTAR EN UNA VM SQL Server 2017 (la original si sigue, o una nueva).

   Pre-requisitos:
     - 15-pre-cutover-backup.sql ejecutado en T-24h (URLs del backup conocidas)
     - Credential 'cutover-backups' configurada

   Variables a personalizar:
     - @DbName
     - @FullUrl y @LogUrl (URLs del backup)
     - @DataPath y @LogPath

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/rollback-plan.md (§5)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

PRINT '========== ROLLBACK CAPA 1 — RESTORE FROM BACKUP ==========';
PRINT '';

-- <ACTION>: copiar las URLs exactas del output del script 15
DECLARE @DbName    sysname = N'AppDb';
DECLARE @FullUrl   nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/cutover-backups/AppDb_PreCutover_<TS>_full.bak';
DECLARE @LogUrl    nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/cutover-backups/AppDb_PreCutover_<TS>_log.trn';
DECLARE @DataPath  sysname = N'D:\Data\';
DECLARE @LogPath   sysname = N'L:\Log\';

-- Si BD existe, abort
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DbName)
BEGIN
    PRINT 'WARNING: Database ' + @DbName + ' already exists. Si seguro, DROP DATABASE primero.';
    RETURN;
END

-- ===== RESTORE FILELISTONLY para generar MOVE clauses =====
DECLARE @sqlFilelist nvarchar(max) = N'
RESTORE FILELISTONLY FROM URL = ''' + @FullUrl + N''';';

DECLARE @filelist TABLE (
    LogicalName nvarchar(128), PhysicalName nvarchar(260), Type char(1),
    FileGroupName nvarchar(128), Size bigint, MaxSize bigint, FileID bigint,
    CreateLSN numeric(25,0), DropLSN numeric(25,0), UniqueID uniqueidentifier,
    ReadOnlyLSN numeric(25,0), ReadWriteLSN numeric(25,0), BackupSizeInBytes bigint,
    SourceBlockSize int, FileGroupID int, LogGroupGUID uniqueidentifier,
    DifferentialBaseLSN numeric(25,0), DifferentialBaseGUID uniqueidentifier,
    IsReadOnly bit, IsPresent bit, TDEThumbprint varbinary(32), SnapshotURL nvarchar(360)
);

INSERT @filelist EXEC sp_executesql @sqlFilelist;

DECLARE @moveClauses nvarchar(max) = N'';
SELECT @moveClauses = @moveClauses +
    N'    MOVE N''' + LogicalName + N''' TO N''' +
    CASE WHEN Type = 'L' THEN @LogPath ELSE @DataPath END +
    LogicalName +
    CASE WHEN Type = 'L' THEN N'.ldf' ELSE N'.mdf' END +
    N''',' + CHAR(13) + CHAR(10)
FROM @filelist;
SET @moveClauses = SUBSTRING(@moveClauses, 1, LEN(@moveClauses) - 3);

-- ===== RESTORE FULL =====
PRINT 'Restoring full backup...';
DECLARE @sqlFullRestore nvarchar(max) = N'
RESTORE DATABASE [' + @DbName + N']
FROM URL = ''' + @FullUrl + N'''
WITH NORECOVERY, STATS = 10,
' + @moveClauses + N';';
EXEC sp_executesql @sqlFullRestore;
PRINT 'Full restore completado.';

-- ===== RESTORE LOG =====
PRINT 'Restoring log backup...';
DECLARE @sqlLogRestore nvarchar(max) = N'
RESTORE LOG [' + @DbName + N']
FROM URL = ''' + @LogUrl + N'''
WITH NORECOVERY, STATS = 10;';
EXEC sp_executesql @sqlLogRestore;
PRINT 'Log restore completado.';

-- ===== RECOVERY final =====
PRINT 'Recovery final...';
DECLARE @sqlRecovery nvarchar(max) = N'RESTORE DATABASE [' + @DbName + N'] WITH RECOVERY;';
EXEC sp_executesql @sqlRecovery;
PRINT 'Database online.';

-- Verificar
SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name = @DbName;

PRINT '';
PRINT '========== ROLLBACK CAPA 1 COMPLETADO ==========';
PRINT 'BD restaurada a estado T-24h pre-cutover.';
PRINT '';
PRINT 'PERDIDA: todas las tx desde el T-24h backup hasta el cutover.';
PRINT 'RTO: ~30-60 min para BDs medianas.';
PRINT '';
PRINT 'Siguiente:';
PRINT '  1. App repoint a esta VM (puede ser otra distinta a la original)';
PRINT '  2. Migrar logins/jobs/etc out-of-band (script 10 inverso)';
PRINT '  3. Validar funcionalidad';
PRINT '  4. Documentar el rollback en post-mortem';
