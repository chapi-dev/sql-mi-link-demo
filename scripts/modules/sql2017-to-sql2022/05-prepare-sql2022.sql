/* =====================================================================
   05-prepare-sql2022.sql
   Prepara la VM vm-sql2022 para Distributed AG:
     - Database Master Key en master (para el cert del endpoint)
     - Server certificate SpainCCert
     - Endpoint Hadr_endpoint TCP 5022 con cert auth
     - Backup del cert publico a C:\certs\SpainCCert.cer
     - Configuracion basica de instancia (max memory, MAXDOP, cost threshold)
     - TempDB tuning basico (autogrowth, 4 files si solo hay 1)

   Pre-requisitos:
     - vm-sql2022 con SQL Server 2022 + Always On habilitado (script 02)
     - Carpeta C:\certs existe
     - sysadmin ejecutando este script

   Variables a personalizar (buscar <ACTION>):
     - MasterKeyPassword
     - CertSubject + ExpiryDate
     - MaxMemoryMB (calcular: total VM RAM - 4096 para SO - 2048 para overhead)

   Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/architecture.md (§5,§8)
   ===================================================================== */

USE master;
GO

-- ===== 1) DATABASE MASTER KEY en master =====
-- <ACTION>: cambiar el password antes de ejecutar
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'CambiarEsto-Por-Pwd-Fuerte!123';
    PRINT 'Master key creada.';
END
ELSE
BEGIN
    PRINT 'Master key ya existe. Saltando.';
END
GO

-- ===== 2) SERVER CERTIFICATE para el endpoint =====
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'SpainCCert')
BEGIN
    CREATE CERTIFICATE SpainCCert
        WITH SUBJECT = 'SpainC AG endpoint cert',
             START_DATE = '20260101',
             EXPIRY_DATE = '20360101';
    PRINT 'Cert SpainCCert creado.';
END
ELSE
BEGIN
    PRINT 'Cert SpainCCert ya existe. Saltando.';
END
GO

-- ===== 3) BACKUP del cert publico =====
-- Esto genera el .cer que se intercambiara con NorthEU
BACKUP CERTIFICATE SpainCCert
    TO FILE = 'C:\certs\SpainCCert.cer';
PRINT 'Cert publico exportado a C:\certs\SpainCCert.cer';
GO

-- ===== 4) ENDPOINT Hadr_endpoint TCP 5022 =====
IF NOT EXISTS (SELECT 1 FROM sys.tcp_endpoints WHERE name = 'Hadr_endpoint')
BEGIN
    CREATE ENDPOINT Hadr_endpoint
        STATE = STARTED
        AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
        FOR DATABASE_MIRRORING (
            AUTHENTICATION = CERTIFICATE SpainCCert,
            ENCRYPTION = REQUIRED ALGORITHM AES,
            ROLE = ALL
        );
    PRINT 'Endpoint Hadr_endpoint creado en 5022.';
END
ELSE
BEGIN
    PRINT 'Endpoint Hadr_endpoint ya existe.';
END
GO

-- Verificar estado
SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type = 4;
GO

-- ===== 5) CONFIGURACION DE INSTANCIA =====
-- Estos valores deben coincidir o ajustarse vs vm-sql2017.
-- Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/architecture.md (§8)

-- Show advanced options
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE WITH OVERRIDE;
GO

-- Max server memory: <ACTION> ajustar a (RAM_total_VM_MB - 4096 - 2048)
-- Para E4ads_v5 (32 GB RAM): max = 32768 - 4096 - 2048 = 26624 MB
DECLARE @max_memory_mb int = 26624;
EXEC sp_configure 'max server memory (MB)', @max_memory_mb;
RECONFIGURE WITH OVERRIDE;

-- Cost threshold for parallelism (default 5 es muy bajo para hardware moderno)
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE WITH OVERRIDE;

-- MAXDOP: <ACTION> copiar el del 2017 (no bajar a 1 por default)
-- Para 4 vCPU: MAXDOP = 4
EXEC sp_configure 'max degree of parallelism', 4;
RECONFIGURE WITH OVERRIDE;

-- Optimize for ad hoc workloads
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE WITH OVERRIDE;

-- Backup compression default
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE WITH OVERRIDE;

GO

-- ===== 6) TEMPDB TUNING (multiple files) =====
-- SQL 2022 por defecto crea 8 files de tempdb. Si solo hay 1, anyadir.
DECLARE @tempdb_files int = (SELECT COUNT(*) FROM tempdb.sys.database_files WHERE type_desc = 'ROWS');
DECLARE @num_cores int = (SELECT cpu_count FROM sys.dm_os_sys_info);
DECLARE @target_files int = CASE WHEN @num_cores < 8 THEN @num_cores ELSE 8 END;

PRINT CONCAT('TempDB files actuales: ', @tempdb_files, ' / target: ', @target_files);

-- Si faltan files, anyadirlos (8 GB cada uno por default, ajustar al storage disponible)
-- (Comentado por defecto - ejecutar manualmente segun layout)
/*
ALTER DATABASE tempdb ADD FILE (NAME = 'tempdev2', FILENAME = 'D:\Data\tempdb2.ndf', SIZE = 8192MB, FILEGROWTH = 1024MB);
ALTER DATABASE tempdb ADD FILE (NAME = 'tempdev3', FILENAME = 'D:\Data\tempdb3.ndf', SIZE = 8192MB, FILEGROWTH = 1024MB);
ALTER DATABASE tempdb ADD FILE (NAME = 'tempdev4', FILENAME = 'D:\Data\tempdb4.ndf', SIZE = 8192MB, FILEGROWTH = 1024MB);
*/
GO

-- ===== 7) TRACE FLAGS RECOMENDADOS =====
DBCC TRACEON (1800, -1);  -- 4K sector alignment para AGs
-- DBCC TRACEON (9567, -1); -- log compression para AGs (validar en POC, puede aumentar CPU)
GO

-- ===== 8) VERIFICACION FINAL =====
SELECT 'IsHadrEnabled' AS prop, SERVERPROPERTY('IsHadrEnabled') AS val;
SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type = 4;
SELECT name, expiry_date FROM sys.certificates WHERE name = 'SpainCCert';
SELECT name, value_in_use FROM sys.configurations WHERE name IN (
    'max server memory (MB)',
    'cost threshold for parallelism',
    'max degree of parallelism',
    'optimize for ad hoc workloads',
    'backup compression default'
);
DBCC TRACESTATUS(-1);

PRINT '';
PRINT '========== 05-prepare-sql2022.sql COMPLETADO ==========';
PRINT 'Siguiente paso: scripts/modules/sql2017-to-sql2022/06-cert-exchange.ps1';
PRINT '  para intercambiar certs entre vm-sql2017 y vm-sql2022';
