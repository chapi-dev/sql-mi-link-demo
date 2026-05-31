-- =====================================================================
-- Capa 3 — Procedimiento post-cutover en SQL Server PRIMARY
-- Ejecutar INMEDIATAMENTE después del cutover exitoso a MI
-- Pone la BD en READ_ONLY para servir como rollback inmediato
-- =====================================================================

USE master;
GO

-- 1. Verificar que YA NO existe el Distributed AG (el wizard lo borró tras failover)
SELECT name, is_distributed FROM sys.availability_groups;
-- En SQL 2017: 'demo-link' (distributed) NO debe aparecer post-cutover

-- 2. Si quedó residual, eliminar
-- DROP AVAILABILITY GROUP [demo-link];

-- 3. Cerrar conexiones existentes
ALTER DATABASE DemoLink SET SINGLE_USER WITH ROLLBACK IMMEDIATE;

-- 4. Poner en READ_ONLY (modo "frozen" = rollback ready)
ALTER DATABASE DemoLink SET READ_ONLY;
ALTER DATABASE DemoLink SET MULTI_USER;

-- 5. Auditing post-cutover (detectar accesos inesperados)
IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'Post_Cutover_Audit')
BEGIN
    EXEC xp_create_subdir 'C:\sqlbackups\audit';
    CREATE SERVER AUDIT [Post_Cutover_Audit]
        TO FILE (FILEPATH = 'C:\sqlbackups\audit\', MAXSIZE = 100 MB, MAX_ROLLOVER_FILES = 10)
        WITH (ON_FAILURE = CONTINUE);
    ALTER SERVER AUDIT [Post_Cutover_Audit] WITH (STATE = ON);
END
GO

USE DemoLink;
IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = 'DemoLink_Connections_Audit')
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION [DemoLink_Connections_Audit]
        FOR SERVER AUDIT [Post_Cutover_Audit]
        ADD (SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP),
        ADD (FAILED_DATABASE_AUTHENTICATION_GROUP)
    WITH (STATE = ON);
END
GO

-- 6. Verificar estado final
USE master;
SELECT name, state_desc, user_access_desc, is_read_only FROM sys.databases WHERE name = 'DemoLink';

PRINT '====================================';
PRINT 'POST-CUTOVER FROZEN STATE ACTIVATED';
PRINT '====================================';
PRINT 'DemoLink is now READ_ONLY (rollback ready)';
PRINT 'Auditing enabled to detect unexpected access';
PRINT '';
PRINT 'If rollback needed: ALTER DATABASE DemoLink SET READ_WRITE;';
PRINT '====================================';
