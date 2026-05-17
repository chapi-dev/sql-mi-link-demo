/* =====================================================================
   04-cutover.sql
   Cutover unidireccional para SQL Server 2017 -> MI.
   En SQL 2017 no existe "managed failover" (solo SQL 2022+).
   El proceso:
     1) Poner DB en read-only / detener escrituras desde la app
     2) Esperar a que el log drain este al dia (delay = 0)
     3) Romper el Distributed AG (DROP en SQL Server)
     4) En la MI ya queda como BD primaria standalone
     5) Repuntar la app al endpoint de la MI
   ===================================================================== */

USE master;
GO

-- 1) Comprobar latencia de replicacion antes del cutover
SELECT
    ar.replica_server_name,
    drs.synchronization_state_desc,
    drs.log_send_queue_size,
    drs.redo_queue_size,
    drs.last_hardened_lsn
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE drs.database_id = DB_ID('DemoLink');
GO

-- 2) Poner BD en READ_ONLY para detener escrituras (opcional pero recomendado)
-- ALTER DATABASE DemoLink SET READ_ONLY WITH ROLLBACK IMMEDIATE;
-- GO

-- 3) Romper el DAG (SQL Server lado)
-- ATENCION: esto es UNIDIRECCIONAL en SQL 2017 - no hay vuelta atras gestionada
ALTER AVAILABILITY GROUP MILinkDAG REMOVE AVAILABILITY GROUP MILinkAG;
GO
DROP AVAILABILITY GROUP MILinkDAG;
GO

-- 4) Quitar la DB del AG local (queda solo en MI)
ALTER AVAILABILITY GROUP MILinkAG REMOVE DATABASE DemoLink;
GO

-- 5) Validar
SELECT name, state_desc FROM sys.databases WHERE name = 'DemoLink';
PRINT 'Cutover completado. La MI es ahora la primaria. Repuntar la app al endpoint de MI.';
GO
