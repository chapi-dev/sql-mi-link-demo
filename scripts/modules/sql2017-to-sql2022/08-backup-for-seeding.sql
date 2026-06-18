/* =====================================================================
   08-backup-for-seeding.sql
   Backup full + log de la BD a migrar (en vm-sql2017), guardado en el
   container 'seeding' del Storage Account intermedio.
   Esto inicia el MANUAL seeding del DAG cross-version (obligatorio
   porque AUTOMATIC seeding no funciona 2017->2022 por error 946).

   Pre-requisitos:
     - 03-create-storage.ps1 ejecutado (Storage Account + SAS)
     - El SQL T-SQL generado por 03 (create-credentials.sql) ejecutado en
       vm-sql2017 (credential para container 'seeding' debe existir).

   Variables a personalizar (buscar <ACTION>):
     - @DbName: nombre de la BD a migrar
     - @StorageUrl: URL del container 'seeding'
     - @BackupNum: numero de stripes (paralelismo del backup)

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/architecture.md (§6)
   ===================================================================== */

USE master;
SET NOCOUNT ON;
GO

-- <ACTION>: configurar antes de ejecutar
DECLARE @DbName        sysname = N'AppDb';
DECLARE @StorageUrl    nvarchar(500) = N'https://stmilinkmig<XXX>.blob.core.windows.net/seeding';
DECLARE @TimeStamp     nvarchar(20) = REPLACE(REPLACE(REPLACE(CONVERT(varchar(20), GETUTCDATE(), 120), '-', ''), ':', ''), ' ', '_');

DECLARE @FullUrl1 nvarchar(500) = @StorageUrl + N'/' + @DbName + N'_seed_' + @TimeStamp + N'_1.bak';
DECLARE @FullUrl2 nvarchar(500) = @StorageUrl + N'/' + @DbName + N'_seed_' + @TimeStamp + N'_2.bak';
DECLARE @FullUrl3 nvarchar(500) = @StorageUrl + N'/' + @DbName + N'_seed_' + @TimeStamp + N'_3.bak';
DECLARE @FullUrl4 nvarchar(500) = @StorageUrl + N'/' + @DbName + N'_seed_' + @TimeStamp + N'_4.bak';
DECLARE @LogUrl   nvarchar(500) = @StorageUrl + N'/' + @DbName + N'_seed_' + @TimeStamp + N'.trn';

-- Verificar que la BD existe y esta en FULL recovery
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DbName)
BEGIN
    RAISERROR('Database %s does not exist. Aborting.', 16, 1, @DbName);
    RETURN;
END

DECLARE @recovery sysname;
SELECT @recovery = recovery_model_desc FROM sys.databases WHERE name = @DbName;
IF @recovery <> 'FULL'
BEGIN
    PRINT 'WARNING: database ' + @DbName + ' is in ' + @recovery + ' recovery mode.';
    PRINT 'Switching to FULL...';
    DECLARE @sqlAlter nvarchar(max) = N'ALTER DATABASE [' + @DbName + N'] SET RECOVERY FULL;';
    EXEC sp_executesql @sqlAlter;
END

-- ===== BACKUP FULL (striped a 4 files para mejor throughput) =====
PRINT 'Starting BACKUP FULL of ' + @DbName + '...';

DECLARE @sqlFull nvarchar(max) = N'
BACKUP DATABASE [' + @DbName + N']
TO URL = ''' + @FullUrl1 + N''',
   URL = ''' + @FullUrl2 + N''',
   URL = ''' + @FullUrl3 + N''',
   URL = ''' + @FullUrl4 + N'''
WITH COMPRESSION,
     CHECKSUM,
     FORMAT,
     MAXTRANSFERSIZE = 4194304,
     BUFFERCOUNT = 64,
     STATS = 5,
     NAME = ''Manual seed full backup for DAG migration'';';

EXEC sp_executesql @sqlFull;

PRINT 'Backup full completado. Archivos:';
PRINT '  ' + @FullUrl1;
PRINT '  ' + @FullUrl2;
PRINT '  ' + @FullUrl3;
PRINT '  ' + @FullUrl4;
PRINT '';

-- ===== BACKUP LOG =====
PRINT 'Starting BACKUP LOG of ' + @DbName + '...';

DECLARE @sqlLog nvarchar(max) = N'
BACKUP LOG [' + @DbName + N']
TO URL = ''' + @LogUrl + N'''
WITH COMPRESSION,
     CHECKSUM,
     FORMAT,
     MAXTRANSFERSIZE = 4194304,
     BUFFERCOUNT = 64,
     STATS = 5,
     NAME = ''Manual seed log backup for DAG migration'';';

EXEC sp_executesql @sqlLog;

PRINT 'Backup log completado: ' + @LogUrl;
PRINT '';

-- ===== Output para usar en 09-restore-for-seeding.sql =====
PRINT '========== COPIAR ESTAS VARIABLES A 09-restore-for-seeding.sql ==========';
PRINT 'DECLARE @FullUrl1 nvarchar(500) = N''' + @FullUrl1 + ''';';
PRINT 'DECLARE @FullUrl2 nvarchar(500) = N''' + @FullUrl2 + ''';';
PRINT 'DECLARE @FullUrl3 nvarchar(500) = N''' + @FullUrl3 + ''';';
PRINT 'DECLARE @FullUrl4 nvarchar(500) = N''' + @FullUrl4 + ''';';
PRINT 'DECLARE @LogUrl   nvarchar(500) = N''' + @LogUrl + ''';';
GO

PRINT '';
PRINT '========== 08-backup-for-seeding.sql COMPLETADO ==========';
PRINT 'Siguiente paso: copiar las URLs arriba al script 09-restore-for-seeding.sql';
PRINT 'y ejecutarlo en vm-sql2022.';
