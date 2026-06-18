# Troubleshooting cross-version (SQL 2017 → SQL 2022) Distributed AG

Errores típicos durante la migración con sus causas y resoluciones. Ordenado por **fase
del flujo**.

> 📘 Si tu error no está aquí, mira primero la guía oficial:
> [Distributed AG troubleshooting](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/troubleshoot-availability-groups-configuration-sql-server).

---

## 1. Fase de preparación

### Error: "AlwaysOn Availability Groups feature is disabled"
**Causa**: Always On no habilitado en la instancia.

**Resolución**:
```powershell
# En la VM
Enable-SqlAlwaysOn -ServerInstance "<vm>\MSSQLSERVER" -Force
Restart-Service MSSQLSERVER -Force
```

Verificar:
```sql
SELECT SERVERPROPERTY('IsHadrEnabled');  -- debe devolver 1
```

### Error: "Endpoint creation failed: cannot create cert"
**Causa**: Falta el Master Key en `master`.

**Resolución**:
```sql
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<pwd-fuerte>';
```

---

## 2. Fase de cert exchange

### Error: "Server certificate ... was not found"
**Causa**: cert del otro lado no importado correctamente, o el archivo .cer está corrupto/erróneo.

**Resolución**:
```sql
-- En el lado donde falla, verificar certs presentes
SELECT name, expiry_date, thumbprint FROM sys.certificates;
```

Si el cert esperado no está, re-importar:
```sql
CREATE CERTIFICATE [<OtraCert>] AUTHORIZATION [<user>]
    FROM FILE = 'C:\certs\<OtraCert>.cer';
```

### Error: "Login failed for user ... (cert mismatch)"
**Causa**: el login mapeado al cert del otro lado **no tiene CONNECT** al endpoint.

**Resolución**:
```sql
GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [<login_otro_lado>];
```

### Error: cert expirado
**Causa**: `EXPIRY_DATE` del cert ya pasó.

**Resolución** (renovar el cert):
```sql
-- Drop el login, drop el cert (orden importante)
DROP LOGIN [<login>];
DROP CERTIFICATE [<cert>];

-- Crear cert nuevo con expiry futuro
CREATE CERTIFICATE [<cert>]
    WITH SUBJECT = '...', EXPIRY_DATE = '20360101';

-- Exportar y intercambiar con el otro lado
BACKUP CERTIFICATE [<cert>] TO FILE = 'C:\certs\<cert>.cer';
```

---

## 3. Fase de creación de AGs locales

### Error: "There are not enough condition predicates"
**Causa**: faltan campos requeridos en `CREATE AVAILABILITY GROUP`.

**Resolución**: revisar sintaxis. Para clusterless:
```sql
CREATE AVAILABILITY GROUP [AG_Name]
WITH (
    CLUSTER_TYPE = NONE,       -- requerido
    FAILOVER_MODE = MANUAL,    -- requerido para CLUSTER_TYPE = NONE
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT
)
FOR DATABASE [DBName]
REPLICA ON N'<server>' WITH (...);
```

### Error: "The endpoint URL ... is not valid"
**Causa**: FQDN no resoluble, o puerto bloqueado.

**Resolución**:
1. Validar resolución DNS: `Resolve-DnsName <fqdn>`.
2. Validar puerto: `Test-NetConnection <fqdn> -Port 5022`.
3. Validar que el endpoint Hadr_endpoint **está STARTED**:
   ```sql
   SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type = 4;
   ```

---

## 4. Fase de Distributed AG

### Error 946: "Cannot open database 'DistributionAG' version 904"
**Causa**: ⚠️ **El error específico de cross-version**. Se usó AUTOMATIC seeding con
versiones distintas. SQL Server intenta crear la BD destino con metadata del 2017 y el 2022
rechaza abrirla.

**Resolución obligatoria**: usar **MANUAL seeding**.

```sql
-- DROP el DAG existente
DROP AVAILABILITY GROUP [DAG_Migrate];

-- Reseed manual (ver architecture.md §6)
-- 1) Backup full y log en NorthEU
-- 2) Restore con NORECOVERY en SpainC
-- 3) Crear DAG con SEEDING_MODE = MANUAL en ambas replicas
```

### Error: "Distributed availability group cannot be created. The primary AG is in synchronous commit but the global primary needs ALTER AVAILABILITY GROUP GRANT CREATE ANY DATABASE"
**Causa**: falta permiso en el forwarder.

**Resolución**:
```sql
-- En el AG del lado forwarder (SpainC)
ALTER AVAILABILITY GROUP [AG_SpainC] GRANT CREATE ANY DATABASE;
```

### Error: "Database join failed"
**Causa**: al hacer `ALTER DATABASE ... SET HADR AVAILABILITY GROUP = ...`, la BD no
estaba en estado `RESTORING` o no hizo match el LSN.

**Resolución**:
1. Verificar estado BD: `SELECT name, state_desc FROM sys.databases WHERE name='AppDb';`
2. Si está ONLINE: hay que sacarla del estado online y re-restaurar con NORECOVERY:
   ```sql
   ALTER DATABASE [AppDb] SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;
   -- (Si la BD se queda inutilizable, restore desde backup)
   ```
3. Re-aplicar logs hasta alcanzar LSN actual del primario:
   ```sql
   RESTORE LOG [AppDb] FROM URL = '...' WITH NORECOVERY;
   ```
4. Reintentar join.

### Error: "The remote copy of database is not recovered far enough to enable this database for synchronization"
**Causa**: el secundario está con LSN anterior al inicio del log que el primario tiene
disponible.

**Resolución**: hacer log backup del primario más reciente, restore en secundario con
NORECOVERY, y reintentar.

---

## 5. Fase de seeding / sincronización

### Estado: `NOT SYNCHRONIZING / RECOVERY_PENDING` permanente
**Causa**: el DAG no logra sincronizar — varias posibles.

**Diagnóstico**:
```sql
-- Ver detalles del estado
SELECT
    ag.name AS ag, ar.replica_server_name, drs.synchronization_state_desc,
    drs.synchronization_health_desc, drs.last_hardened_lsn, drs.last_commit_time,
    drs.log_send_queue_size, drs.redo_queue_size, drs.connected_state_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id;

-- Ver mensajes de seeding
SELECT * FROM sys.dm_hadr_automatic_seeding;
```

Posibles causas y solución:
- **`connected_state_desc = DISCONNECTED`** → problema de red. Validar §1 de [`networking.md`](networking.md).
- **`current_state = FAILED` en `dm_hadr_automatic_seeding`** → revisar `error_message`.
- **`log_send_queue_size` crece sin parar** → primario produce log más rápido que la red. Bajar carga o aumentar bandwidth.

### Performance pobre del seeding
**Causa**: throughput limitado por RTT (problema típico cross-region).

**Resolución**: usar **MANUAL seeding** (ver §6 de [`architecture.md`](architecture.md)):
- Backup striped + compresión + tunables (`MAXTRANSFERSIZE=4194304, BUFFERCOUNT=64`).
- Restore con paralelismo.

---

## 6. Fase de cutover

### Error: "The operation requires the availability group to be in a synchronized state"
**Causa**: intentaste `ALTER AG FAILOVER` con el DAG en ASYNC y `NOT_SYNCHRONIZED`.

**Resolución**: seguir el protocolo de [`cutover-plan.md`](cutover-plan.md):
1. Cambiar el DAG a SYNC.
2. Esperar `SYNCHRONIZED`.
3. Entonces failover.

### Error: "Cannot failover or revoke role"
**Causa**: el failover requiere ejecutarse desde el lado al que vas a hacer failover
(el "target" del failover).

**Resolución**: conectarse a **vm-sql2022** (el destino) y ejecutar el comando ahí.

### Error: app no reconecta tras failover
**Causa**: connection string no actualizada, o cache DNS.

**Resolución**:
1. Validar que el deployment de la app **realmente** tiene la nueva connection string.
2. Si usa DNS CNAME: `ipconfig /flushdns` en clientes Windows.
3. Si la app tiene connection pooling agresivo: forzar restart de la app.

---

## 7. Fase post-cutover

### BD en SpainC permanece `RESOLVING` post-failover
**Causa**: el AG no completó la transición de roles.

**Resolución**:
```sql
-- Verificar role actual
SELECT ag.name, ar.replica_server_name, drs.is_local, drs.role_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id;
```

Si role_desc no es `PRIMARY` en SpainC, reintento de failover:
```sql
-- En vm-sql2022
ALTER AVAILABILITY GROUP [DAG_Migrate] FAILOVER;
```

### Logins de aplicación no funcionan post-cutover
**Causa**: o no se migraron, o se migraron sin preservar SIDs (users huérfanos).

**Resolución**: ver [`out-of-band-objects.md`](out-of-band-objects.md) §3 "Reparar usuarios
huérfanos":
```sql
USE [AppDb];
EXEC sp_change_users_login 'Report';  -- lista huerfanos
EXEC sp_change_users_login 'Auto_Fix', '<user>';  -- repara uno
```

### Jobs no se ejecutan post-cutover
**Causa**: jobs migraron disabled y no se reactivaron.

**Resolución**:
```sql
USE msdb;
-- Listar y habilitar todos
SELECT name, enabled FROM dbo.sysjobs;
EXEC sp_update_job @job_name = N'<JobName>', @enabled = 1;
```

### Performance degradada post-cutover
**Causa**: plans recompilados subóptimos, falta de estadísticas, cache vacío.

**Resolución**:
1. **Actualizar estadísticas** (workaround temporal):
   ```sql
   EXEC sp_updatestats;
   ```
2. **Forzar último plan bueno** vía Query Store:
   ```sql
   ALTER DATABASE [AppDb] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, ...);
   ALTER DATABASE [AppDb] SET QUERY_STORE = ON (DATA_FLUSH_INTERVAL_SECONDS = 60);
   ```
3. **Warm cache**: ejecutar las queries críticas para llenar buffer pool.
4. **Validar config de instancia**: `max server memory`, `cost threshold for parallelism`,
   `MAXDOP` — copiar del 2017.

---

## 8. Errores específicos cross-version 2017 → 2022

### Assemblies CLR fallan al cargar
**Causa**: SQL 2022 tiene `clr strict security = 1` por default. Assemblies sin asymmetric
key firmada no cargan.

**Resolución**:
```sql
-- Opcion A: desactivar strict (NO recomendado, baja seguridad)
EXEC sp_configure 'clr strict security', 0;
RECONFIGURE;

-- Opcion B (recomendada): firmar el assembly con asymmetric key
USE master;
CREATE ASYMMETRIC KEY [<key>] FROM EXECUTABLE FILE = 'C:\<assembly>.dll';
CREATE LOGIN [<login>] FROM ASYMMETRIC KEY [<key>];
GRANT UNSAFE ASSEMBLY TO [<login>];
```

### "TLS protocol is not supported" desde clientes viejos
**Causa**: SQL 2022 desactiva TLS 1.0/1.1 por default. Clientes con SQL Native Client
viejo (SNAC11) o sqlncli antiguos fallan.

**Resolución**: actualizar drivers de cliente a **OLE DB Driver 19+** o **ODBC Driver 18+**.

### Cursores con `FAST_FORWARD` cambian comportamiento
**Causa**: SQL 2022 tiene Intelligent Query Processing que puede cambiar planes de
cursores en algunos casos edge.

**Resolución**: bajar `compatibility_level` temporal a `140` (lo de 2017) hasta validar.
```sql
ALTER DATABASE [AppDb] SET COMPATIBILITY_LEVEL = 140;
```

### Algunas vistas del sistema cambiaron
Algunos DMVs/DMFs añadieron columnas en 2022. Si tu monitoring extrae columnas concretas
de DMVs, **validar que tu código no asuma orden ordinal**:
```sql
-- Mal:
SELECT *, COL_1 = (SELECT col FROM sys.dm_xxx) FROM ...

-- Bien:
SELECT *, COL_1 = (SELECT <col_name> FROM sys.dm_xxx) FROM ...
```

---

## 9. Comandos de diagnóstico útiles

### Estado general del AG/DAG
```sql
-- Dashboard textual
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    drs.is_local,
    drs.role_desc,
    drs.operational_state_desc,
    drs.connected_state_desc,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    DB_NAME(drs.database_id) AS db,
    drs.last_hardened_lsn,
    drs.last_commit_time,
    drs.log_send_queue_size AS send_kb,
    drs.redo_queue_size AS redo_kb
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id;
```

### Errores recientes en error log
```sql
EXEC xp_readerrorlog 0, 1, N'always', NULL, NULL, NULL, N'DESC';
```

### Estado del endpoint
```sql
SELECT name, state_desc, port, ip_address
FROM sys.tcp_endpoints WHERE type = 4;  -- DATABASE_MIRRORING
```

### Auto-seeding history
```sql
SELECT
    start_time, completion_time, is_source, current_state, failure_state,
    failure_state_desc, error_code, performed_seeding
FROM sys.dm_hadr_physical_seeding_stats;
```

### Tráfico DAG en curso
```sql
SELECT
    cluster_name, replica_server_name, database_name,
    log_send_rate, redo_rate
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE drs.is_local = 0;
```

---

## 10. Cuándo escalar a Microsoft Support

Si después de aplicar las resoluciones de este doc el problema persiste, abrir caso con
Microsoft. Tener listos:

- **Error log de SQL Server** de ambas VMs durante el periodo del problema.
- **Output completo** de `SELECT * FROM sys.dm_hadr_*` (todos los DMVs).
- **Resultado de `Test-NetConnection`** entre las VMs en 5022.
- **NSG rules** de ambas regiones.
- **Configuración del DAG** (`SELECT * FROM sys.availability_groups WHERE is_distributed = 1`).
- **Network captures** (Wireshark/netsh trace) si el problema es de red.

Casos de severidad A (issue crítico de producción) suelen ser asignados en < 1h.

---

## Referencias

- [Distributed AG troubleshooting (oficial)](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/troubleshoot-availability-groups-configuration-sql-server)
- [Always On AG common issues](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/always-on-troubleshooting-data-movement-latency-replicas)
- [Manual seeding for AGs](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/manually-prepare-secondary-database-for-an-availability-group-sql-server)
- [Issues when upgrading to SQL Server 2022](https://learn.microsoft.com/troubleshoot/sql/database-engine/install/windows/issues-upgrading-sql-server-2022)
- [`out-of-band-objects.md`](out-of-band-objects.md) — troubleshooting de logins/jobs
- [`networking.md`](networking.md) — troubleshooting de red
