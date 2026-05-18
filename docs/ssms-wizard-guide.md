# Guía paso a paso: usar el wizard de SSMS para crear el MI Link

> Esta es la vía **recomendada por Microsoft** y la que funciona out-of-the-box.
> Es lo que debe usar el cliente en su migración real.

## Prerrequisitos
- SSMS 19+ (descargar desde https://aka.ms/ssms).
- En el SQL Server origen (VM en este caso): Always On AG habilitado y SQL Server reiniciado.
- En la VM: BD origen en FULL recovery con full + log backup tomado.
- MI destino aprovisionada y en estado `Ready`.
- Conectividad bidireccional en TCP 5022 (NSG + Windows Firewall de la VM).
- Windows Firewall en la VM: regla inbound para 5022/TCP **explícita** (no basta con la regla NSG).
- Usuario AAD con permisos `Owner` o `Contributor` + `SQL Managed Instance Contributor` en la MI.

## Pasos

### 1. Conectar a ambos servidores en SSMS
- File → Connect Object Explorer → conectar al SQL Server de la VM (Windows Auth o SQL Auth).
- File → Connect Object Explorer → conectar a la MI con AAD interactive (FQDN + puerto 1433).

### 2. Abrir el wizard
- En el árbol del SQL Server origen, click derecho sobre la BD que quieres migrar (en nuestra demo: `DemoLink`).
- **Tasks → Azure SQL Managed Instance link → New…**
- Aparece el wizard.

### 3. Páginas del wizard
1. **Introduction**: Next.
2. **Specify Link Options**:
   - Link name: ej. `MILinkDAG`
   - Selecciona la BD `DemoLink`.
3. **Requirements**: el wizard hace 8-10 checks (HADR, FULL recovery, backup, network…). Si falla algo te lo dice y a veces lo arregla.
4. **Specify Secondary Replica**: selecciona la MI destino (usa AAD auth).
5. **Specify Distributed AG**: nombres por defecto OK.
6. **Validate**: el wizard prueba conectividad y permisos.
7. **Summary** → **Finish**.

### 4. Espera
- El wizard hace el seeding (5-15 min para una BD pequeña).
- Verás progress en SSMS.

### 5. Verificación
En el SQL Server origen:
```sql
SELECT ar.replica_server_name, drs.synchronization_state_desc, drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id;
```
Esperado: ambas réplicas en `SYNCHRONIZED` / `HEALTHY` (síncrono cuando el seeding termina y entra en mantenimiento normal pasa a Async commit pero `Synchronized` en término del DAG).

### 6. Inserta una fila en la VM y comprueba en MI
```sql
USE DemoLink;
INSERT INTO dbo.DemoRows (Origin, Note) VALUES ('VM-after-link', 'should replicate');
```
Conecta a la MI con AAD, query DemoLink, verás la fila.

### 7. Cutover (cuando estés listo)
- Detén escrituras en la app.
- Espera a que el log esté drenado (revisa `log_send_queue_size` = 0).
- En SSMS, click derecho sobre el link → **Failover**. En SQL 2017 esto es **break unidirectional** y deja la MI como standalone primary.
- Repunta la connection string de la app a la MI.

## Si el wizard falla

- **"Could not connect on port 5022"**: revisa NSG y Windows Firewall en la VM.
- **"Login failed for user 'NT AUTHORITY\\ANONYMOUS LOGON'"**: cert exchange fallido. El wizard te dará botón "Retry"; si persiste, recrear el endpoint con un cert nuevo.
- **"Distributed Availability Group creation failed"**: revisa que la VM esté registrada con SQL VM RP (`az sql vm create`) — sin eso, ciertos comportamientos del cert exchange fallan.

## Lo que hace el wizard por debajo (para curiosos)
1. Comprueba prereqs: HADR, FULL recovery, backups recientes, conectividad.
2. Crea/reutiliza master key en `master`.
3. Crea cert + endpoint `Hadr_endpoint` 5022 en SQL Server si no existen.
4. **Extrae** el cert del MI usando `EXEC sp_get_endpoint_certificate @endpoint_type = 4`.
5. **Push** del cert del SQL Server al MI con `serverTrustCertificates` PUT (Azure REST).
6. **Push** del cert del MI al SQL Server con `CREATE CERTIFICATE ... FROM BINARY = 0x…` + `CREATE LOGIN ... FROM CERTIFICATE` + `GRANT CONNECT ON ENDPOINT::Hadr_endpoint`.
7. Crea AG local clusterless en SQL Server (`CREATE AVAILABILITY GROUP ... WITH (CLUSTER_TYPE = NONE)`).
8. Crea el Distributed AG en MI con `PUT distributedAvailabilityGroups` (REST API).
9. **Polling** del estado con reintentos automáticos del handshake.
10. Verifica seeding y notifica.
