/* =====================================================================
   09-restore-for-seeding.sql
   Restaura el backup full + log en vm-sql2022 con NORECOVERY para
   prepararlo para unirse al Distributed AG con manual seeding.

   Pre-requisitos:
     - 08-backup-for-seeding.sql ya ejecutado (.bak y .trn en Blob)
     - Credential para container 'seeding' creada en vm-sql2022
     - Master key existe en master DB de vm-sql2022

   Variables a personalizar (copiar del output del script 08):
     - @DbName
     - @FullUrl1..4 (las 4 URLs del backup striped)
     - @LogUrl
     - @DataPath y @LogPath (donde van los .mdf/.ldf)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

-- <ACTION>: copiar las URLs exactas del output del script 08
DECLARE @DbName        sysname = N'AppDb';
DECLARE @FullUrl1      nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/seeding/AppDb_seed_<TS>_1.bak';
DECLARE @FullUrl2      nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/seeding/AppDb_seed_<TS>_2.bak';
DECLARE @FullUrl3      nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/seeding/AppDb_seed_<TS>_3.bak';
DECLARE @FullUrl4      nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/seeding/AppDb_seed_<TS>_4.bak';
DECLARE @LogUrl        nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/seeding/AppDb_seed_<TS>.trn';

-- <ACTION>: ajustar paths segun disk layout de vm-sql2022
DECLARE @DataPath sysname = N'D:\Data\';
DECLARE @LogPath  sysname = N'L:\Log\';

-- ===== Si la BD ya existe en destino, ABORT (no sobrescribir por accidente) =====
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DbName)
BEGIN
    PRINT 'Database ' + @DbName + ' already exists in vm-sql2022.';
    PRINT 'Si es una iteracion de testing, DROP DATABASE primero (con cuidado).';
    PRINT 'Si es la primera vez, algo va mal. Investigar antes de continuar.';
    RAISERROR('Aborting to avoid overwriting existing DB.', 16, 1);
    RETURN;
END

-- ===== RESTORE FILELISTONLY para ver los logical names y MOVE clauses =====
PRINT 'Reading filelist from backup to compose MOVE clauses...';
DECLARE @sqlFilelist nvarchar(max) = N'
RESTORE FILELISTONLY FROM URL = ''' + @FullUrl1 + ''',
                          URL = ''' + @FullUrl2 + ''',
                          URL = ''' + @FullUrl3 + ''',
                          URL = ''' + @FullUrl4 + ''';';

DECLARE @filelist TABLE (
    LogicalName nvarchar(128), PhysicalName nvarchar(260), Type char(1),
    FileGroupName nvarchar(128), Size bigint, MaxSize bigint, FileID bigint,
    CreateLSN numeric(25,0), DropLSN numeric(25,0), UniqueID uniqueidentifier,
    ReadOnlyLSN numeric(25,0), ReadWriteLSN numeric(25,0), BackupSizeInBytes bigint,
    SourceBlockSize int, FileGroupID int, LogGroupGUID uniqueidentifier,
    DifferentialBaseLSN numeric(25,0), DifferentialBaseGUID uniqueidentifier,
    IsReadOnly bit, IsPresent bit, TDEThumbprint varbinary(32), SnapshotURL nvarchar(360)
);

INSERT @filelist
EXEC sp_executesql @sqlFilelist;

-- Generar las MOVE clauses dinamicamente
DECLARE @moveClauses nvarchar(max) = N'';
SELECT @moveClauses = @moveClauses +
    N'    MOVE N''' + LogicalName + N''' TO N''' +
    CASE WHEN Type = 'L' THEN @LogPath ELSE @DataPath END +
    LogicalName +
    CASE WHEN Type = 'L' THEN N'.ldf' ELSE N'.mdf' END +
    N''',' + CHAR(13) + CHAR(10)
FROM @filelist;

-- Quitar la coma+CRLF final
SET @moveClauses = SUBSTRING(@moveClauses, 1, LEN(@moveClauses) - 3);

PRINT 'MOVE clauses generated:';
PRINT @moveClauses;

-- ===== RESTORE FULL con NORECOVERY =====
PRINT '';
PRINT 'Starting RESTORE DATABASE WITH NORECOVERY...';

DECLARE @sqlFullRestore nvarchar(max) = N'
RESTORE DATABASE [' + @DbName + N']
FROM URL = ''' + @FullUrl1 + N''',
     URL = ''' + @FullUrl2 + N''',
     URL = ''' + @FullUrl3 + N''',
     URL = ''' + @FullUrl4 + N'''
WITH NORECOVERY,
     STATS = 5,
' + @moveClauses + N';';

PRINT 'Executing:';
PRINT @sqlFullRestore;
EXEC sp_executesql @sqlFullRestore;

PRINT 'RESTORE FULL completado.';

-- ===== RESTORE LOG con NORECOVERY =====
PRINT '';
PRINT 'Starting RESTORE LOG WITH NORECOVERY...';

DECLARE @sqlLogRestore nvarchar(max) = N'
RESTORE LOG [' + @DbName + N']
FROM URL = ''' + @LogUrl + N'''
WITH NORECOVERY, STATS = 5;';

PRINT 'Executing:';
PRINT @sqlLogRestore;
EXEC sp_executesql @sqlLogRestore;

PRINT 'RESTORE LOG completado.';

-- ===== Verificar estado =====
SELECT name, state_desc, recovery_model_desc, compatibility_level
FROM sys.databases
WHERE name = @DbName;

PRINT '';
PRINT '========== 09-restore-for-seeding.sql COMPLETADO ==========';
PRINT 'Database ' + @DbName + ' restaurada en vm-sql2022 con NORECOVERY.';
PRINT 'Estado esperado: RESTORING';
PRINT '';
PRINT 'Siguiente paso: scripts 10-12 para crear AGs locales + DAG, y luego';
PRINT 'ejecutar ALTER DATABASE ... SET HADR AVAILABILITY GROUP = AG_SpainC;';
PRINT 'para unir esta BD al AG.';
