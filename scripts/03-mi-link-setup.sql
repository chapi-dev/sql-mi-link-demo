/* =====================================================================
   03-mi-link-setup.sql
   Configura el lado SQL Server 2017 del MI Link.
   Ejecutar DESPUES de:
     - SQL Server 2017 con CU31 instalado
     - Always On AG habilitado y servicio reiniciado
     - 01-prepare-sql.sql (master key, cert MILinkCert, endpoint)
     - 02-restore-sample-db.sql (DemoLink en FULL recovery con backup)
     - MI ya creada y en estado Ready
     - Certificado de la MI importado en SQL Server (ver runbook paso 6)

   Esto crea el Availability Group local de un solo nodo (necesario para
   despues unirlo via Distributed AG a la MI).
   ===================================================================== */

USE master;
GO

-- 1) Anadir la DB al Availability Group local (single-replica)
-- Si ya existe el AG, ALTER en su lugar.
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = 'MILinkAG')
BEGIN
    CREATE AVAILABILITY GROUP MILinkAG
    WITH (
        CLUSTER_TYPE = NONE,            -- clusterless (no WSFC)
        FAILOVER_MODE = MANUAL,
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        SEEDING_MODE = AUTOMATIC
    )
    FOR DATABASE DemoLink
    REPLICA ON N'$(LocalServerName)' WITH (
        ENDPOINT_URL = N'TCP://$(LocalServerName):5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)
    );
END
GO

-- 2) Crear el Distributed AG que enlaza el AG local con la MI
-- El AG de la MI se llama por convencion '<MIName>'
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = 'MILinkDAG')
BEGIN
    CREATE AVAILABILITY GROUP MILinkDAG
    WITH (DISTRIBUTED)
    AVAILABILITY GROUP ON
        N'MILinkAG' WITH (
            LISTENER_URL = N'TCP://$(LocalServerName):5022',
            AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
            FAILOVER_MODE = MANUAL,
            SEEDING_MODE = AUTOMATIC
        ),
        N'$(MIName)' WITH (
            LISTENER_URL = N'tcp://$(MIName).$(MIDnsZone).database.windows.net:5022;Server=[$(MIName)]',
            AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
            FAILOVER_MODE = MANUAL,
            SEEDING_MODE = AUTOMATIC
        );
END
GO

-- 3) Verificar estado
SELECT ag.name AS ag, ar.replica_server_name, drs.synchronization_state_desc, drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id;
GO
