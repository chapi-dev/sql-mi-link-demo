-- =====================================================================
-- ROLLBACK desde BACKUP NATIVO (Capa 1)
-- Restore DB desde el blob al SQL Server primary
-- Usar si la BD primary se corrompió o se borró por error
-- =====================================================================

USE master;
GO

-- Si la BD existe, cerrarla
IF DB_ID('DemoLink') IS NOT NULL
BEGIN
    ALTER DATABASE DemoLink SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DemoLink;
END
GO

-- 1. Restore FULL con NORECOVERY (para poder aplicar LOG después)
RESTORE DATABASE DemoLink
    FROM URL = 'https://<storage_account>.blob.core.windows.net/<container>/DemoLink_FULL_<ts>.bak'
    WITH NORECOVERY,
         REPLACE,
         STATS = 10;
GO

-- 2. Restore LOG con RECOVERY (último log)
RESTORE LOG DemoLink
    FROM URL = 'https://<storage_account>.blob.core.windows.net/<container>/DemoLink_LOG_<ts>.trn'
    WITH RECOVERY,
         STATS = 10;
GO

-- 3. Verificar
SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name = 'DemoLink';
SELECT TOP 5 * FROM DemoLink.dbo.DemoRows ORDER BY Id DESC;

PRINT 'RESTORE COMPLETE';
