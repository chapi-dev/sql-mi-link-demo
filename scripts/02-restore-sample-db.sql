USE master;
GO

/* =====================================================================
   02-restore-sample-db.sql
   Crea la base de datos demo y la deja lista (FULL recovery + backup full).
   MI Link requiere FULL recovery model y al menos un FULL backup previo.
   ===================================================================== */

IF DB_ID('DemoLink') IS NOT NULL
BEGIN
    ALTER DATABASE DemoLink SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DemoLink;
END
GO

CREATE DATABASE DemoLink;
GO

ALTER DATABASE DemoLink SET RECOVERY FULL;
GO

USE DemoLink;
GO

CREATE TABLE dbo.DemoRows (
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    Origin      NVARCHAR(50)  NOT NULL,
    Note        NVARCHAR(200) NOT NULL,
    InsertedAt  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

INSERT INTO dbo.DemoRows (Origin, Note) VALUES
('VM-SQL2017-FRA', 'Initial seed row before MI Link'),
('VM-SQL2017-FRA', 'Second seed row'),
('VM-SQL2017-FRA', 'Third seed row');
GO

USE master;
GO
BACKUP DATABASE DemoLink TO DISK = 'C:\MILink\DemoLink.bak' WITH INIT, COMPRESSION;
BACKUP LOG DemoLink     TO DISK = 'C:\MILink\DemoLink.trn' WITH INIT, COMPRESSION;
GO

SELECT name, recovery_model_desc, state_desc FROM sys.databases WHERE name = 'DemoLink';
