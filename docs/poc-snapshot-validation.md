# POC de validación: copia puntual de la BD a la región destino

Antes de planificar un MI Link cross-region y un cutover real, conviene **levantar una POC
funcional** copiando una BD del origen (SQL Server IaaS / on-prem) a un MI en la región destino
mediante backup nativo + restore. El objetivo es validar:

- Compatibilidad de schema, features y collation con SQL Managed Instance.
- Latencia y comportamiento de la app desde la región destino.
- Cualquier dependencia externa (linked servers, jobs, replicación, SSIS) que pudiera fallar.
- Estimación realista de tiempos de backup/copy/restore para el dimensionado del cutover real.

Esta POC **no es la migración** — el primary original sigue siendo el de producción y nunca
deja de recibir tráfico. La copia en la región destino es un **clon en un punto en el tiempo**,
no replicación continua. Para la migración real se sigue [`runbook.md`](runbook.md) con MI Link.

> **¿Hay riesgo de pérdida de datos?** No, mientras se trate de una POC sin tráfico de
> producción contra la copia. El origen no se toca. Si en algún momento se cambia la app
> productiva a la copia, sí habría desincronización: ver "¿Qué NO hacer con esta POC?" al
> final del documento.

---

## Flujo en alto nivel

```text
  ┌──────────────────────┐                       ┌──────────────────────┐
  │ Región ORIGEN        │                       │ Región DESTINO       │
  │ (p. ej. North Europe)│                       │ (p. ej. Spain Central)│
  │                      │                       │                      │
  │  ┌────────────────┐  │  1) BACKUP TO URL     │  ┌────────────────┐  │
  │  │ SQL Server     │──┼──────────────────────►│  │ Blob storage   │  │
  │  │ (VM o on-prem) │  │                       │  │ (poc-restore)  │  │
  │  │  BD producción │  │  2) (opcional) azcopy │  └───────┬────────┘  │
  │  └────────────────┘  │     cross-region      │          │           │
  │       ▲              │                       │          │ 3) RESTORE│
  │       │              │                       │          ▼           │
  │   Producción         │                       │  ┌────────────────┐  │
  │   sigue intacta      │                       │  │ SQL MI (POC)   │  │
  │                      │                       │  │ GP Gen5 4 vCore│  │
  │                      │                       │  │ BD clonada     │  │
  │                      │                       │  └────────┬───────┘  │
  └──────────────────────┘                       │           │          │
                                                 │           ▼          │
                                                 │   App de QA prueba   │
                                                 │   contra esta copia  │
                                                 └──────────────────────┘
```

---

## Pre-requisitos

- Una **Storage Account** en la región destino (LRS o ZRS es suficiente para POC).
- Un **MI pequeño en la región destino**, mínimo GP Gen5 4 vCores, con AHB si aplica.
  Una vez completada la POC se borra (no es producción).
- Subnet delegada a `Microsoft.Sql/managedInstances` en la VNet destino.
- Conectividad cliente → MI (endpoint privado vía VNet peering, jumpbox, o public endpoint
  para POC si la policy del tenant lo permite).
- Identidad para autenticar contra el MI (AAD admin o login SQL).
- BD origen en `FULL` recovery con al menos un FULL backup tomado, o capacidad de generar
  un FULL ahora.

---

## Opción A — `BACKUP TO URL` directo + `RESTORE FROM URL`

La ruta más rápida si el SQL Server origen tiene acceso a internet (o a la Storage Account
destino vía private endpoint).

### 1. Crear la Storage Account destino

```powershell
$rg        = "<rg-poc>"
$location  = "<region-destino>"
$saName    = "stgpocrestore$(Get-Random -Maximum 9999)"
$container = "poc-restore"

az group create --name $rg --location $location

az storage account create --name $saName --resource-group $rg `
  --location $location --sku Standard_LRS --kind StorageV2 `
  --allow-blob-public-access false

az storage container create --account-name $saName --name $container `
  --auth-mode login
```

### 2. Generar un SAS token (solo para el contenedor, con permisos rwl)

```powershell
$expiry = (Get-Date).AddHours(24).ToString("yyyy-MM-ddTHH:mm:ssZ")

$sas = az storage container generate-sas `
  --account-name $saName --name $container `
  --permissions rwl --expiry $expiry `
  --auth-mode login --as-user --https-only -o tsv

Write-Host "SAS para BACKUP TO URL (NO incluir el ?): $sas"
```

> **Nota sobre tenants restrictivos**: si la policy del tenant bloquea
> `allowSharedKeyAccess`, el `BACKUP TO URL` con SAS basado en account key falla con
> `OS error 50`. Workaround: usar un SAS basado en delegated user (`--auth-mode login
> --as-user`) o bien backup a disco local + `azcopy` con AAD (Opción B más abajo).

### 3. Crear la credential en el SQL Server origen

```sql
USE master;

CREATE CREDENTIAL [https://<storage-account>.blob.core.windows.net/<container>]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET   = '<el SAS generado, SIN el ? inicial>';
```

### 4. Lanzar el FULL backup a URL desde el SQL Server origen

```sql
BACKUP DATABASE <DbName>
TO URL = N'https://<storage-account>.blob.core.windows.net/<container>/<DbName>-full.bak'
WITH COMPRESSION, STATS = 5, CHECKSUM, INIT;
```

> Para BDs grandes, fraccionar en múltiples striped files acelera enormemente la transferencia:
>
> ```sql
> BACKUP DATABASE <DbName>
> TO URL = N'https://<sa>.blob.core.windows.net/<c>/<DbName>-1.bak',
>    URL = N'https://<sa>.blob.core.windows.net/<c>/<DbName>-2.bak',
>    URL = N'https://<sa>.blob.core.windows.net/<c>/<DbName>-3.bak',
>    URL = N'https://<sa>.blob.core.windows.net/<c>/<DbName>-4.bak'
> WITH COMPRESSION, STATS = 5, CHECKSUM, INIT, FORMAT;
> ```

### 5. Restaurar en el MI destino

Conectado al MI (vía SSMS, sqlcmd o `mssql-cli` con AAD):

```sql
RESTORE DATABASE <DbName>
FROM URL = N'https://<storage-account>.blob.core.windows.net/<container>/<DbName>-full.bak';
```

Si fue striped:

```sql
RESTORE DATABASE <DbName>
FROM URL = N'https://<sa>.blob.core.windows.net/<c>/<DbName>-1.bak',
     URL = N'https://<sa>.blob.core.windows.net/<c>/<DbName>-2.bak',
     URL = N'https://<sa>.blob.core.windows.net/<c>/<DbName>-3.bak',
     URL = N'https://<sa>.blob.core.windows.net/<c>/<DbName>-4.bak';
```

> El MI lee el blob directamente; no requiere crear credential adicional si la Storage
> Account está en la misma VNet o tiene endpoint público accesible. Para Storage privada,
> el MI necesita resolución DNS y conectividad al endpoint privado del blob.

### 6. Validar y conectarse desde la app de QA

```sql
USE <DbName>;
SELECT TOP 100 * FROM dbo.<TablaPrincipal>;
SELECT name, state_desc, compatibility_level, collation_name
FROM sys.databases WHERE name = '<DbName>';
```

Apuntar la app de QA al MI (`<mi-name>.<dns-zone>.database.windows.net,1433`) con un
usuario de prueba y ejecutar el plan de validación funcional habitual.

---

## Opción B — Backup a disco local + AzCopy AAD a la región destino

Útil cuando:

- El tenant bloquea `allowSharedKeyAccess` y los SAS basados en account key no funcionan.
- El SQL Server origen no tiene acceso directo a la Storage Account destino.
- Se quiere desacoplar el SQL Server del transporte (más control).

### 1. Backup local

```sql
BACKUP DATABASE <DbName>
TO DISK = N'D:\backups\<DbName>-full.bak'
WITH COMPRESSION, STATS = 5, CHECKSUM, INIT;
```

### 2. Subir a la Storage Account con AzCopy + AAD

Desde la VM del SQL Server (o un jumpbox con identidad asignada y RBAC `Storage Blob
Data Contributor` sobre la Storage Account destino):

```powershell
azcopy login --tenant-id <tenant-id>

azcopy copy 'D:\backups\<DbName>-full.bak' `
  "https://<sa>.blob.core.windows.net/<container>/<DbName>-full.bak" `
  --recursive=false
```

### 3. Restaurar en el MI

Como en el paso 5 de la Opción A.

---

## Opción C — Azure Database Migration Service (DMS) online

Para POCs donde se quiere validar también el **modo online** (con captura de cambios
durante la migración inicial), DMS ofrece *Log Replay Service (LRS)* para SQL MI:

- El SQL Server origen toma FULL + diffs + logs y los sube a un blob.
- DMS aplica los backups en orden al MI y los nuevos logs según llegan.
- En el momento del cutover, se hace un `Complete migration` y la BD pasa a `RESTORING` →
  `ONLINE` en el MI.

DMS LRS **no requiere MI Link** ni Always On AG en el origen, lo que lo hace adecuado para:

- BDs en SQL Server Standard sin AG configurado (los SPOFs del tipo `LOG` y `RPT` en una
  topología típica).
- POCs donde se quiere ensayar todo el flujo end-to-end sin tocar la VM original.

Doc oficial: [Migrate databases with Log Replay Service](https://learn.microsoft.com/en-us/azure/dms/migrate-sql-server-to-managed-instance-lrs).

> DMS LRS no sustituye a MI Link para producción cross-region: no garantiza RPO=0 y no
> tiene failback automático. Es complementario para POC y para workloads sin AG.

---

## Lista de checks funcionales recomendados en la POC

Tras el restore, validar en el MI:

```sql
-- 1. Compatibility level: ¿lo subimos al del MI o lo mantenemos al original?
SELECT name, compatibility_level FROM sys.databases WHERE name = '<DbName>';

-- 2. Features en uso que podrían no estar soportadas en MI
SELECT feature_name, feature_id
FROM sys.dm_db_persisted_sku_features;

-- 3. Linked servers (no se restauran automáticamente; recrearlos manualmente)
SELECT name, product, provider, data_source
FROM sys.servers WHERE server_id <> 0;

-- 4. Jobs del SQL Agent (idem)
SELECT name, enabled, description
FROM msdb.dbo.sysjobs;

-- 5. CLR assemblies (solo SAFE permission set en MI)
SELECT name, permission_set_desc FROM sys.assemblies WHERE is_user_defined = 1;

-- 6. Replication articles (si la BD es Publisher / Subscriber)
SELECT publication, article, source_object FROM syspublications p
JOIN sysarticles a ON p.pubid = a.pubid;

-- 7. Service Broker
SELECT name, is_broker_enabled FROM sys.databases WHERE name = '<DbName>';

-- 8. CDC habilitado
SELECT name, is_cdc_enabled FROM sys.databases WHERE name = '<DbName>';
```

Cualquier feature reportada que esté en la lista de [diferencias T-SQL entre SQL Server
y SQL MI](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/transact-sql-tsql-differences-sql-server)
hay que documentarla como item a resolver antes del cutover real.

---

## ¿Qué NO hacer con esta POC?

No conmutar el tráfico de producción de forma definitiva a la copia POC, porque:

- La copia es **un punto en el tiempo**: todos los writes contra el origen posteriores al
  backup **no están en la copia**.
- Si la app empieza a escribir contra la copia y luego se hace fallback al origen, los
  writes posteriores al cutover **se quedan en la copia** y desaparecen al volver.
- No hay reconciliación automática entre origen y copia.

Para tráfico productivo real con RPO=0, hay que usar **MI Link** (ver `runbook.md`), que
mantiene replicación continua síncrona en commit hasta el momento exacto del cutover.

---

## Cleanup de la POC

Cuando la validación funcional termina:

```powershell
# Borrar el MI de POC
az sql mi delete --resource-group <rg-poc> --name <mi-poc-name> --yes

# Borrar la Storage Account
az storage account delete --resource-group <rg-poc> --name <sa-poc> --yes

# Borrar el RG entero si era exclusivo de la POC
az group delete --name <rg-poc> --yes --no-wait
```

> El MI de POC y la Storage Account incurren coste mientras existen. Borrarlos al
> terminar la validación.

---

## Siguiente paso

Una vez validada la POC, planificar la migración productiva con **MI Link** y el plan
de rollback de 4 capas:

1. [`version-comparison.md`](version-comparison.md) — confirmar versión del origen.
2. [`runbook.md`](runbook.md) — provisionar el MI productivo y configurar el link.
3. [`migration-rollback-plan.md`](migration-rollback-plan.md) — preparar el botón de pánico.
4. [`cross-instance-replication.md`](cross-instance-replication.md) — si hay
   dependencias de replicación entre BDs de instancias distintas.
