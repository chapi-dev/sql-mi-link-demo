$ErrorActionPreference = 'Continue'
$masterKeyPwd = $env:MASTER_KEY_PWD
if (-not $masterKeyPwd) { throw "Set `$env:MASTER_KEY_PWD before running" }

New-Item -ItemType Directory -Path "C:\MILink" -Force | Out-Null

$sql = @"
USE master;
GO

PRINT '== Verificar HADR (Always On AG) =='
SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled;
GO

PRINT '== Trace flags 1800, 9567 ==';
DBCC TRACEON (1800, -1);
DBCC TRACEON (9567, -1);
GO

PRINT '== Master key ==';
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$masterKeyPwd';
GO

PRINT '== Drop existing endpoint and cert (clean state) ==';
IF EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = 'Hadr_endpoint')
    DROP ENDPOINT Hadr_endpoint;
GO
IF EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'MILinkCert')
    DROP CERTIFICATE MILinkCert;
GO

PRINT '== Create cert ==';
CREATE CERTIFICATE MILinkCert
    WITH SUBJECT = 'MI Link mirroring endpoint cert',
    EXPIRY_DATE = '2099-12-31';
GO

PRINT '== Backup cert to file ==';
BACKUP CERTIFICATE MILinkCert TO FILE = 'C:\MILink\MILinkCert.cer';
GO

PRINT '== Create endpoint 5022 ==';
CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        AUTHENTICATION = CERTIFICATE MILinkCert,
        ENCRYPTION = REQUIRED ALGORITHM AES,
        ROLE = ALL
    );
GO

PRINT '== Demo database ==';
IF DB_ID('DemoLink') IS NOT NULL BEGIN
    ALTER DATABASE DemoLink SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DemoLink;
END
GO
CREATE DATABASE DemoLink;
GO
ALTER DATABASE DemoLink SET RECOVERY FULL;
GO
USE DemoLink;
CREATE TABLE dbo.DemoRows (
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    Origin      NVARCHAR(50)  NOT NULL,
    Note        NVARCHAR(200) NOT NULL,
    InsertedAt  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
INSERT INTO dbo.DemoRows (Origin, Note) VALUES
('VM-SQL2017-FRA', 'Seed 1: written before link'),
('VM-SQL2017-FRA', 'Seed 2: written before link'),
('VM-SQL2017-FRA', 'Seed 3: written before link');
GO

USE master;
BACKUP DATABASE DemoLink TO DISK = 'C:\MILink\DemoLink.bak' WITH INIT, COMPRESSION, FORMAT;
BACKUP LOG      DemoLink TO DISK = 'C:\MILink\DemoLink.trn' WITH INIT, COMPRESSION, FORMAT;
GO

PRINT '== Resumen final ==';
SELECT 'Endpoint' AS Section, name COLLATE Latin1_General_CI_AS_KS_WS AS detail, state_desc COLLATE Latin1_General_CI_AS_KS_WS AS info FROM sys.tcp_endpoints WHERE name = 'Hadr_endpoint'
UNION ALL
SELECT 'Cert', name COLLATE Latin1_General_CI_AS_KS_WS, expiry_date::text COLLATE Latin1_General_CI_AS_KS_WS FROM sys.certificates WHERE name = 'MILinkCert'
UNION ALL
SELECT 'DemoDB', name COLLATE Latin1_General_CI_AS_KS_WS, recovery_model_desc COLLATE Latin1_General_CI_AS_KS_WS FROM sys.databases WHERE name = 'DemoLink';
GO
"@

# Note: T-SQL ::text isn't valid; use cast. Let me fix that.
$sql = $sql -replace "::text",""

$sql | Out-File "C:\MILink\setup.sql" -Encoding ASCII

Write-Output "=== Running SQL setup as SYSTEM (sysadmin) ==="
$out = & sqlcmd -S . -E -b -i "C:\MILink\setup.sql" 2>&1
Write-Output "Exit code: $LASTEXITCODE"
$out | ForEach-Object { Write-Output $_ }

Write-Output "`n=== Cert file as base64 (for pushing to MI) ==="
if (Test-Path "C:\MILink\MILinkCert.cer") {
    $bytes = [IO.File]::ReadAllBytes("C:\MILink\MILinkCert.cer")
    $b64 = [Convert]::ToBase64String($bytes)
    Write-Output "CERT_SIZE_BYTES: $($bytes.Length)"
    Write-Output "CERT_BASE64_START"
    Write-Output $b64
    Write-Output "CERT_BASE64_END"
} else {
    Write-Output "ERROR: Cert file missing"
}
