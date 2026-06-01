# SSMS Managed Instance Link Wizard

Guía paso a paso del wizard incluido en **SSMS 19+** para crear un Managed
Instance Link entre un SQL Server (on-prem o IaaS) y una Azure SQL Managed Instance.

> El wizard es el camino **oficial y recomendado**. Automatiza cert exchange,
> creación del AG local (si no existe), creación del DAG y la initial seeding.
>
> Para ver una pasada completa del wizard con capturas de pantalla, mira
> [`wizard-walkthrough.md`](wizard-walkthrough.md).
>
> Las alternativas (REST API y T-SQL puro) están documentadas pero son frágiles
> en SQL Server 2017 y no se recomiendan salvo casos muy específicos.

## Pre-requisitos

- SSMS 19.x o superior instalado en una máquina con conectividad a:
  - El SQL Server origen (puerto 1433).
  - El Azure SQL Managed Instance (puerto 1433 o 3342 según endpoint).
- SQL Server origen cumple los requisitos del MI Link:
  - Versión y CU soportados (ver [`version-comparison.md`](version-comparison.md)).
  - Para SQL 2017: Azure Connect Pack instalado
    (ver [`azure-connect-pack.md`](azure-connect-pack.md)).
  - Endpoint TCP 5022 abierto entre el SQL Server y el MI (NSG + Windows Firewall).
  - Modo de recuperación de la BD = `FULL`.
  - Al menos un FULL backup tomado de la BD.
- MI desplegado y operativo, accesible por endpoint privado o público.
- Identidad para autenticar en MI: AAD Admin o usuario con permisos `sysadmin`
  equivalentes en el MI.

### Validar pre-requisitos en T-SQL

```sql
-- En SQL Server origen
SELECT @@VERSION;            -- Versión y CU
SELECT name, recovery_model_desc FROM sys.databases WHERE name = N'<DbName>';
SELECT * FROM sys.system_objects WHERE name = 'sp_get_endpoint_certificate'; -- Azure Connect Pack

-- Comprobar último backup
SELECT TOP 1 backup_finish_date, type
FROM msdb.dbo.backupset
WHERE database_name = N'<DbName>' AND type = 'D'
ORDER BY backup_finish_date DESC;
```

```sql
-- En MI
SELECT @@VERSION;
SELECT name FROM sys.databases;  -- Verificar que <DbName> NO existe ya en MI
```

---

## Flujo del wizard

### Paso 1 — Abrir el wizard

En SSMS 19+, en el Object Explorer:

1. Conectar al **SQL Server origen** (no al MI primero).
2. Expandir el árbol hasta `Databases` → click derecho sobre la BD a replicar
   → **Azure SQL Managed Instance link** → **New …**.

Se abre el asistente *"New Managed Instance link"*.

### Paso 2 — Introduction

Pantalla informativa. Click **Next**.

### Paso 3 — Login

Autenticación contra el **MI destino**:

| Campo | Valor recomendado |
|---|---|
| Server name | `<mi-name>.<dns-zone>.database.windows.net` (endpoint público) o IP del endpoint privado |
| Authentication | **Microsoft Entra MFA** (recomendado en tenants AAD-only) o **Microsoft Entra Password** |
| Database | `master` |
| Encrypt connection | ✅ activado |
| Trust server certificate | ⚠️ Solo si el cert no es CA-signed |

Para tenants con políticas que prohíben SQL Authentication en MI, Microsoft Entra
es la única opción operativa.

Click **Login** → debe conectar y mostrar el listado de DBs del MI vacío
(o solo `master`).

### Paso 4 — Specify SQL Server Instance

Confirma el SQL Server origen (el árbol desde el que se abrió el wizard).
Click **Next**.

### Paso 5 — Databases

Marcar la(s) BD(s) que se van a replicar.

> Cada BD crea **su propio Link**. Si se replican 5 BDs, hay 5 AGs locales y 5
> Distributed AGs. Decidir si se crean por lote o uno a uno.

Si la BD no tiene un FULL backup reciente, el wizard ofrece **tomarlo
automáticamente** antes de continuar. Aceptar.

Click **Next**.

### Paso 6 — Specify Distributed AG Options

| Campo | Valor recomendado | Notas |
|---|---|---|
| Availability Group name | `AG_<DbName>` | Nombre del AG local en el SQL Server origen |
| Distributed AG name | `DAG_<DbName>` | Nombre del Distributed AG que une SQL Server y MI |
| Endpoint TCP port | `5022` | Default. Si está cambiado por NSG, ajustar |
| Endpoint URL | Auto-detectado | Verificar que apunta al FQDN/IP correcto y resolvible desde el MI |
| Failover mode | `Manual` | Único soportado en MI Link |
| Seeding mode | `Automatic` | Initial seed lo gestiona el wizard |

Click **Next**.

### Paso 7 — Specify Initial Data Synchronization

Resumen del initial seeding:

- El wizard hace `BACKUP DATABASE … TO URL` a un storage container temporal
  y lo restaura en el MI. Requiere outbound 443 desde el SQL Server al storage.
- Alternativa: marcar **Skip initial backup** si la BD ya existe en MI con LSN
  compatible (uso avanzado, NO recomendado en el primer intento).

Click **Next**.

### Paso 8 — Summary

Revisa toda la configuración. Click **Finish** para ejecutar.

### Paso 9 — Execution

El wizard ejecuta secuencialmente:

| Tarea | Qué hace |
|---|---|
| Validating prerequisites | Verifica versiones, permisos, conectividad |
| Creating master key | Si no existe en `master` del SQL Server |
| Creating endpoint | Endpoint TCP 5022 con certs |
| Exchanging certificates | Cert local → MI y MI cert → local (via `sp_certificate_add_issuer`) |
| Creating availability group | AG local en SQL Server |
| Creating distributed availability group | DAG que une SQL Server y MI |
| Joining MI to distributed AG | Operación REST contra el MI |
| Starting seeding | Initial seed automático |

Cuando todos los pasos muestran ✅ green check, el Link está activo.

Click **Close**.

---

## Verificación post-creación

### En el SQL Server origen

```sql
-- AG local
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.log_send_queue_size,
    drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar      ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag        ON drs.group_id = ag.group_id;
```

Resultado esperado: `SYNCHRONIZED HEALTHY`, queues a 0.

```sql
-- Distributed AG
SELECT
    ag.name AS dag_name,
    ar.replica_server_name,
    drs.role_desc,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states drs
JOIN sys.availability_replicas ar  ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag    ON drs.group_id = ag.group_id
WHERE ag.is_distributed = 1;
```

Resultado esperado: `SYNCHRONIZING HEALTHY` para ambos replicas.

> Es **normal** que un cross-region MI Link aparezca como `SYNCHRONIZING` (no
> `SYNCHRONIZED`): MI Link cross-region siempre opera en `ASYNCHRONOUS_COMMIT`
> para tolerar latencias.

### En el MI destino

```sql
-- La BD aparece como ONLINE en MI durante el seeding (en read-only)
SELECT name, state_desc FROM sys.databases WHERE name = N'<DbName>';
```

Durante el seeding la BD aparece y es accesible en **read-only**. Tras la
sincronización inicial sigue siendo read-only hasta el cutover.

---

## Initial seeding — fases y monitorización

El initial seeding atraviesa estas fases:

1. **Backup phase**: SQL Server origen hace `BACKUP DATABASE` a un storage
   container temporal (creado y gestionado por el wizard).
2. **Restore phase**: MI hace `RESTORE` desde el container.
3. **Catch-up phase**: aplicación de log shipping para llegar al estado del
   primary live.
4. **Continuous replication**: estado normal del Link, `SYNCHRONIZING HEALTHY`.

### Monitorización del progreso

```sql
-- Backups en curso en SQL Server origen
SELECT
    database_id,
    backup_type,
    bytes_processed,
    estimated_completion_time
FROM sys.dm_database_encryption_keys
WHERE database_id = DB_ID(N'<DbName>');
```

```sql
-- Progreso de seeding (en MI)
SELECT * FROM sys.dm_hadr_physical_seeding_stats;
```

Columnas relevantes:
- `transfer_rate_bytes_per_second`: ritmo de copia.
- `total_disk_io_wait_time_ms`: tiempo esperando I/O del storage MI.
- `total_network_wait_time_ms`: tiempo esperando red (indicador de cuello de botella).

---

## Operaciones post-creación

### Pausar el Link

No hay un comando explícito "pause". Para detener temporalmente la replicación:

```sql
ALTER AVAILABILITY GROUP [DAG_<DbName>]
    MODIFY AVAILABILITY GROUP ON N'DAG_<DbName>'
    WITH (SEEDING_MODE = MANUAL);
```

> Solo válido como parche temporal; reanudar con `SEEDING_MODE = AUTOMATIC`.
> En producción, la pausa real se hace con failover planned + drop del Link.

### Cutover (failover) al MI

⚠️ **Acción destructiva para el Link**. Documentada en [`runbook.md`](runbook.md)
paso 8. En SQL Server 2016/2017/2019 el Link se rompe tras el failover y para
volver al origen se necesitan las capas de rollback externas
([`migration-rollback-plan.md`](migration-rollback-plan.md)).

### Eliminar el Link sin cutover

Drop ordenado (vía SSMS o T-SQL):

```sql
-- En SQL Server origen
ALTER AVAILABILITY GROUP [DAG_<DbName>] REMOVE AVAILABILITY GROUP N'DAG_<DbName>';
DROP AVAILABILITY GROUP [DAG_<DbName>];

-- (Si solo se replicaba una BD y se quiere reciclar el AG local)
ALTER AVAILABILITY GROUP [AG_<DbName>] REMOVE DATABASE [<DbName>];
DROP AVAILABILITY GROUP [AG_<DbName>];
```

En el MI, la BD restaurada queda como standalone read-only — promover a writable
solo durante un cutover real.

---

## Errores frecuentes del wizard

Lista breve aquí; el detalle completo está en [`troubleshooting.md`](troubleshooting.md).

| Código | Causa habitual |
|---|---|
| 41986 | Cert exchange OK pero parser `LISTENER_URL` no acepta `;Server=[…]` → falta Azure Connect Pack (SQL 2017). |
| 41974 | Endpoint TCP 5022 inalcanzable (NSG, firewall, peering). |
| 41976 | Auth handshake fallido — cert no registrado en el lado contrario. |
| 18452 | Login sin acceso al MI — verificar AAD Admin o permisos. |
| 19499 | Endpoint con error de configuración — recrear endpoint con `CREATE ENDPOINT … FOR DATABASE_MIRRORING`. |

---

## Referencias

- [Configure link with SSMS](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-use-ssms-to-replicate-database)
- [Managed Instance link best practices](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-best-practices)
- [Distributed availability groups overview](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups)
