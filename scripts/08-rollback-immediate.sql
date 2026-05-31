-- =====================================================================
-- ROLLBACK INMEDIATO (Capa 3) - SQL Server primary
-- Usar cuando hay que volver al SQL Server primary en las primeras horas
-- y los datos escritos en MI son descartables / reconstruibles.
-- =====================================================================
-- IMPORTANTE:
--   1. Antes de ejecutar esto, asegurar que la app está parada / cortada.
--   2. Si la BD está en READ_ONLY (modo "frozen"), volver a READ_WRITE.
--   3. Después de esto, repointar la app al SQL Server primary.
-- =====================================================================

USE master;
GO

-- 1. Verificar estado actual de la BD
SELECT name, state_desc, user_access_desc, is_read_only, recovery_model_desc
FROM sys.databases
WHERE name = 'DemoLink';

-- 2. Cerrar conexiones existentes (si hay)
ALTER DATABASE DemoLink SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

-- 3. Volver a multi-user y read_write
ALTER DATABASE DemoLink SET READ_WRITE;
ALTER DATABASE DemoLink SET MULTI_USER;
GO

-- 4. Verificar AG/Distributed AG status
-- (tras el cutover el DAG ya no debería existir en SQL 2017 — el wizard lo borra)
SELECT name, is_distributed FROM sys.availability_groups;

-- 5. Si quedaba algún DAG residual, eliminarlo
-- DROP AVAILABILITY GROUP [demo-link];

-- 6. Si quedaba el AG local clusterless, decidir si dropearlo
-- DROP AVAILABILITY GROUP [MILinkAG];

-- 7. Smoke test de lectura/escritura
INSERT INTO DemoLink.dbo.DemoRows (CreatedAt, Payload)
VALUES (SYSUTCDATETIME(), 'ROLLBACK SMOKE TEST ' + CAST(NEWID() AS varchar(36)));

SELECT TOP 5 * FROM DemoLink.dbo.DemoRows ORDER BY Id DESC;

PRINT '=============================================';
PRINT 'ROLLBACK COMPLETED';
PRINT 'BD: DemoLink R/W en SQL Server primary';
PRINT 'NEXT: repoint app connection string a vm-sql2017';
PRINT '=============================================';
