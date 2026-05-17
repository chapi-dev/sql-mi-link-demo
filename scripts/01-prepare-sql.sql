USE master;
GO

/* =====================================================================
   01-prepare-sql.sql
   Prepara SQL Server 2017 (CU20+) como ORIGEN para Managed Instance link.
   Requisitos previos: SQL Server reiniciado con Always On AG feature ENABLED
   (esto lo hace el script 00-enable-alwayson.ps1 antes de este SQL).
   ===================================================================== */

-- 1) Trace flags requeridos para MI Link (persistentes)
DBCC TRACEON (1800, -1);
DBCC TRACEON (9567, -1);
GO

-- 2) Crear master key en master (si no existe)
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$(MasterKeyPwd)';
END
GO

-- 3) Crear certificado para autenticar el endpoint de mirroring
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'MILinkCert')
BEGIN
    CREATE CERTIFICATE MILinkCert
    WITH SUBJECT = 'MI Link mirroring endpoint cert',
    EXPIRY_DATE = '2099-12-31';
END
GO

-- 4) Exportar el certificado para subirlo a la MI mas tarde
BACKUP CERTIFICATE MILinkCert
TO FILE = 'C:\MILink\MILinkCert.cer';
GO

-- 5) Crear endpoint de Database Mirroring en 5022 (auth por cert)
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = 'Hadr_endpoint')
BEGIN
    CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        AUTHENTICATION = CERTIFICATE MILinkCert,
        ENCRYPTION = REQUIRED ALGORITHM AES,
        ROLE = ALL
    );
END
GO

-- 6) Verificar
SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE name = 'Hadr_endpoint';
SELECT @@VERSION AS SqlVersion, SERVERPROPERTY('ProductLevel') AS CU;
GO
