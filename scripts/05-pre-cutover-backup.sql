-- =====================================================================
-- Pre-cutover backup script
-- Ejecutar en SQL Server PRIMARY justo antes del planned failover
-- Genera FULL + LOG backup COPY_ONLY a Azure Blob (no rompe la chain)
-- =====================================================================

-- Parámetros (sustituir antes de ejecutar)
--   <storage_account> : ej. stsqlmilinkbackup
--   <container>       : ej. sqlbackups
--   <sas_token>       : token SAS sin el '?' inicial (sp=rwdl&...)

USE master;
GO

-- 1. Crear credential apuntando al container (idempotente)
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = 'https://<storage_account>.blob.core.windows.net/<container>')
    DROP CREDENTIAL [https://<storage_account>.blob.core.windows.net/<container>];
GO

CREATE CREDENTIAL [https://<storage_account>.blob.core.windows.net/<container>]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET   = '<sas_token>';  -- sin el '?' inicial
GO

-- 2. Backup FULL COPY_ONLY (no rompe la cadena del Link)
DECLARE @ts varchar(20) = REPLACE(REPLACE(CONVERT(varchar(19), GETDATE(), 120), ' ', '_'), ':', '');
DECLARE @url_full nvarchar(500) = N'https://<storage_account>.blob.core.windows.net/<container>/DemoLink_FULL_' + @ts + N'.bak';
DECLARE @url_log  nvarchar(500) = N'https://<storage_account>.blob.core.windows.net/<container>/DemoLink_LOG_'  + @ts + N'.trn';

PRINT 'Backup FULL to: ' + @url_full;
DECLARE @sql_full nvarchar(max) = N'BACKUP DATABASE DemoLink TO URL = ''' + @url_full + N''' WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 10, FORMAT, INIT;';
EXEC sp_executesql @sql_full;

-- 3. Backup LOG (no COPY_ONLY para capturar gap completo si fuera necesario; pero como hay AG, mejor COPY_ONLY)
PRINT 'Backup LOG to: ' + @url_log;
DECLARE @sql_log nvarchar(max) = N'BACKUP LOG DemoLink TO URL = ''' + @url_log + N''' WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 10, FORMAT, INIT;';
EXEC sp_executesql @sql_log;

PRINT '=============================================';
PRINT 'BACKUPS COMPLETE';
PRINT 'FULL: ' + @url_full;
PRINT 'LOG:  ' + @url_log;
PRINT 'Guarda estas URLs para el rollback';
PRINT '=============================================';
GO

-- 4. Verificar header del backup (smoke test)
-- RESTORE HEADERONLY FROM URL = '<full_url>';
-- RESTORE VERIFYONLY FROM URL = '<full_url>';

-- 5. Verificar tamaños en blob (ejecutar desde Azure CLI):
--    az storage blob list --container-name sqlbackups --account-name <stg> --auth-mode login --query "[].{name:name, sizeMB:to_number(properties.contentLength)/1024/1024}" -o table
