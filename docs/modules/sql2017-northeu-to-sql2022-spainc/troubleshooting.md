# Troubleshooting cross-version (SQL 2017 → SQL 2022) Distributed AG

Errores típicos durante la migración con sus causas y resoluciones. Ordenado por **fase
del flujo**.

> 📘 Si tu error no está aquí, mira primero la guía oficial:
> [Distributed AG troubleshooting](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/troubleshoot-availability-groups-configuration-sql-server).

> ✅ **Findings empíricos de POC en Azure (2026-06-18)**: los errores marcados con
> 🧪 fueron encontrados ejecutando los scripts reales contra una sub MCAP en Azure
> Spain Central y están documentados aquí con la solución exacta.

---

## 0. Errores específicos detectados en POC real (Azure MCAP sub)

Esta sección recoge bugs encontrados al ejecutar el módulo end-to-end por primera vez.
Algunos requirieron fixes en los propios scripts (ya aplicados); otros son limitaciones
de Azure / subscripciones tipo MCAP que aparecen siempre.

### 🧪 0.1 — Script 02: `az vm create --nsg ""` falla
**Síntoma**: `ERROR: argument --nsg: expected one argument`. La VM nunca se crea pero el
script reporta "DONE" porque no chequea `$LASTEXITCODE`.

**Causa**: `--nsg ""` (string vacío) no es válido en Azure CLI moderno. PowerShell hace
strip de las comillas vacías.

**Fix aplicado en scripts**:
```powershell
# Mal:
--nsg ""

# Bien (PowerShell -> CLI escape):
--nsg '""'

# O alternativa: NO incluir --nsg, dejar que Azure cree el default
```
Además, **siempre comprobar `$LASTEXITCODE` después de cada `az ...`** y abortar si != 0.

### 🧪 0.2 — VM Azure Windows: CD-ROM ocupa `D:\` por default
**Síntoma**: el script `02-install-sql2022.ps1` intenta crear partición data en `D:\` pero
falla porque la letra está ocupada por el DVD virtual.

**Causa**: las VMs Windows en Azure montan el CD-ROM virtual como `D:\` por default.

**Fix obligatorio antes de inicializar discos**:
```powershell
$cdrom = Get-WmiObject Win32_CDROMDrive
if ($cdrom -and $cdrom.Drive -eq 'D:') {
    $dvd = Get-WmiObject -Class Win32_volume -Filter "DriveType=5"
    $dvd.DriveLetter = 'Z:'
    $dvd.Put() | Out-Null
}
# Ahora D:\ está libre para el data disk
```

### 🧪 0.3 — `az vm run-command invoke` con script inline grande puede fallar silencioso
**Síntoma**: el script "termina OK" pero los recursos NO se crearon (folders, Always On no
habilitado, etc.).

**Causa**: el run-command tiene límites de tamaño en el payload, problemas de encoding con
caracteres especiales, y no propaga exit codes de PowerShell interno.

**Fix obligatorio en cualquier script que use run-command**:
- **Capturar output del script PowerShell interno en JSON** y devolverlo (no usar `Write-Host`
  porque puede perderse).
- **Wrappear el inner script en try/catch** y devolver `status: SUCCESS/FAILED` explícito.
- **Validar el resultado** después con un segundo run-command de verificación.

Ejemplo:
```powershell
$results = @{}
try {
    # ... operaciones ...
    $results['status'] = 'SUCCESS'
} catch {
    $results['status'] = 'FAILED'
    $results['error'] = $_.Exception.Message
}
$results | ConvertTo-Json -Depth 4
```

### 🧪 0.4 — Sub MCAP/CSP: shared key auth en Storage prohibido por policy
**Síntoma**: 
```
ERROR: Key based authentication is not permitted on this storage account.
ErrorCode: KeyBasedAuthenticationNotPermitted
```
al ejecutar `az storage container create --account-key ...` o `az storage account generate-sas --account-key ...`.

**Causa**: muchas suscripciones corporativas (Microsoft Customer Agreement Partner = MCAP, EA,
gov) tienen Azure Policy que prohíbe `allowSharedKeyAccess` en Storage Accounts. Es una
buena práctica de seguridad.

**Fix aplicado al script 03**:
- Crear Storage Account con `--allow-shared-key-access false` (default seguro).
- Usar `--auth-mode login` para crear containers (requiere "Storage Blob Data Contributor"
  role en el usuario).
- Generar **user-delegation SAS** con `--as-user` en lugar de account-key SAS.

**Workaround si necesitas long-lived SAS y la policy lo permite**: usar el switch
`-AllowSharedKey` del script 03 (crea SA con `--allow-shared-key-access true`).

### 🧪 0.5 — User-delegation SAS limit: estrictamente < 7 días
**Síntoma**: `ERROR: incorrect usage: --expiry should be within 7 days from now` al
generar SAS con `--as-user`.

**Causa**: la SAS de Entra ID (user-delegation) tiene un límite **estricto** de 7 días.
Configurar exactamente 7 días tampoco funciona (es <, no ≤). Esta limitación viene del
servicio Storage, no del CLI.

**Fix aplicado al script 03**: cap automático a 6 días si `-AllowSharedKey` está false.
Para SAS de mayor duración, hay 3 opciones:
1. Usar shared-key SAS (requiere que la policy lo permita).
2. Renovar el SAS cada 6 días con un job programado.
3. Usar Managed Identity (no aplica para SQL Server BACKUP TO URL).

### 🧪 0.6 — VM Azure Marketplace SQL Server: solo `sa` como sysadmin (deshabilitado)
**Síntoma**: ejecutar T-SQL como `sysadmin` (necesario para `CREATE MASTER KEY`,
`CREATE ENDPOINT`, etc.) falla con:
```
Msg 15247, Level 16, State 1
User does not have permission to perform this action.
```
Incluso ejecutando como local administrator vía RDP o `az vm run-command` (que corre
como `NT AUTHORITY\SYSTEM`).

**Causa**: las imágenes Marketplace SQL Server en Azure (Developer, Standard, Enterprise)
vienen con **hardened defaults**: solo `sa` es sysadmin, y `sa` está **deshabilitado**.
Esto es una práctica de seguridad correcta, pero impide automatización vía run-command.

**Verificación**:
```sql
SELECT sp.name, sp.is_disabled FROM sys.server_principals sp
WHERE sp.principal_id IN (
    SELECT member_principal_id FROM sys.server_role_members
    WHERE role_principal_id = SUSER_ID('sysadmin')
);
-- Resultado tipico: solo 'sa' con is_disabled=1
```

**Fix obligatorio post-install**: single-user mode + add sysadmin → restart normal:
```powershell
# 1) Stop SQL
Stop-Service MSSQLSERVER -Force

# 2) Add -m to startup params via registry
$regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\Parameters'
$existingParams = (Get-ItemProperty -Path $regPath).PSObject.Properties |
    Where-Object Name -like 'SQLArg*' | Select-Object -ExpandProperty Value
if ('-m' -notin $existingParams) {
    Set-ItemProperty -Path $regPath -Name "SQLArg$($existingParams.Count)" -Value '-m'
}

# 3) Start in single-user mode (only one admin connection allowed)
Start-Service MSSQLSERVER

# 4) Connect as Windows admin and add sysadmin
& sqlcmd -S . -E -Q "
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT AUTHORITY\SYSTEM')
    CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM];

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'BUILTIN\Administrators')
    CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS;
ALTER SERVER ROLE sysadmin ADD MEMBER [BUILTIN\Administrators];
"

# 5) Remove -m
(Get-ItemProperty -Path $regPath).PSObject.Properties |
    Where-Object { $_.Name -like 'SQLArg*' -and $_.Value -eq '-m' } |
    ForEach-Object { Remove-ItemProperty -Path $regPath -Name $_.Name }

# 6) Restart normal
Stop-Service MSSQLSERVER -Force
Start-Service MSSQLSERVER
```

**Mejor práctica para automatización**: ejecutar esto **inmediatamente después del
provisioning de la VM** (en el script 02), no más tarde.

### 🧪 0.7 — Disco GPT pre-existente: New-Partition falla "drive letter already in use"
**Síntoma**: al re-ejecutar el script 02 después de un fallo previo, el script de
inicialización de discos falla con:
```
The requested access path is already in use.
```

**Causa**: tras un primer intento fallido, los discos quedan en estado `GPT` (no `RAW`),
así que `Get-Disk | Where-Object PartitionStyle -eq 'RAW'` no los devuelve, pero las
particiones tampoco están bien configuradas.

**Fix**: detectar discos GPT sin partition con drive letter asignado y reusarlos:
```powershell
$unpartitioned = Get-Disk | Where-Object { $_.PartitionStyle -eq 'GPT' -and $_.Number -ne 0 } | ForEach-Object {
    $hasLetter = (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
        Where-Object DriveLetter).Count -gt 0
    if (-not $hasLetter) { $_ }
}
```

### 🧪 0.8 — Script 01 asume RG NorthEU pre-existente con `nsg-vm`
**Síntoma**: si ejecutas el script 01 sin haber hecho antes el módulo MI Link, falla al
intentar añadir la regla NSG `AllowMigrationFromSpainC` al NSG inexistente.

**Causa**: el script asume que `rg-milink-vm`, `vnet-vm` y `nsg-vm` (del módulo MI Link)
ya existen.

**Fix recomendado**: hacer el script tolerante: si el NSG no existe, **emitir warning y
continuar** en lugar de fallar. La regla NSG del lado NorthEU se puede añadir más tarde
cuando se provisione esa VM.

```powershell
$nsgExists = az network nsg show -g $RgNE -n $NsgNE --query name -o tsv 2>$null
if ($nsgExists) {
    # Añadir regla
} else {
    Write-Warning "NSG $NsgNE no existe en NorthEU. Skip — añadir regla manualmente cuando exista."
}
```

---

### 🧪 0.9 — SKU `Standard_D2as_v5` no disponible en NorthEurope (capacity)
**Síntoma**: `(SkuNotAvailable) Following SKUs have failed for Capacity Restrictions: Standard_D2as_v5`.

**Causa**: Azure tiene fluctuaciones de capacity por región/SKU. SKUs populares pueden no
estar disponibles temporalmente.

**Fix**: probar SKUs alternativos del mismo nivel:
- `Standard_D2s_v5` (Intel)
- `Standard_E2as_v5`
- `Standard_B2ms` (cheaper, burstable)

O usar otra región (West Europe, Spain Central, France Central tienen menos contención
típicamente).

### 🧪 0.10 — SQL Server 2017 NO soporta user-delegation SAS para BACKUP/RESTORE TO URL
**Síntoma** (al hacer `BACKUP DATABASE ... TO URL = 'https://...'`):
```
Msg 3201, Level 16, State 1
Cannot open backup device 'https://<sa>.blob.core.windows.net/...'.
Operating system error 50 (The request is not supported.).
Location: "sql\\ntdbms\\storeng\\dfs\\manager\\blobcredential.cpp":1888
```

**Causa**: SQL Server 2017 (incluso CU31) **NO soporta user-delegation SAS** (Entra ID-based).
Esa capability se añadió en versiones más recientes de SQL Server. SQL Server 2017 solo
acepta SAS firmado con account key (shared key SAS).

**Implicación CRÍTICA en subs MCAP/EA con policy `denyAllowSharedKeyAccess`**:
- Si la sub prohíbe shared-key access en Storage (BUG 0.4)
- Y SQL Server 2017 solo acepta shared-key SAS (este bug)
- Entonces **BACKUP/RESTORE TO URL es IMPOSIBLE para SQL 2017** en esa sub.

**Workarounds**:
1. **Hacer backup local + transferir** (Azure File Share, AzCopy, base64 chunking).
2. **Usar otra sub sin la policy** para el Storage intermedio.
3. **Excepcionalmente excluir el SA de la policy** (requiere admin de la sub).
4. **Migrar primero a SQL Server 2022** en otro entorno (que sí soporta user-delegation
   SAS via `CREATE EXTERNAL CREDENTIAL`).

> **Findings empíricos**: en sub MCAP `ME-MngEnvMCAP184496-antonioch-1` esta combinación
> bloquea totalmente el patrón "backup to URL" del seeding manual. **Para producción real
> con esta sub, se debe usar Azure File Share temporal (SMB con identity Entra) o un
> bypass de la policy aprobado por security team**.

### 🧪 0.11 — Azure Policy fuerza `allowSharedKeyAccess: false` post-creación
**Síntoma**: creas un Storage Account con `--allow-shared-key-access true` y el comando
no falla, pero al verificar `allowSharedKeyAccess` está `false`.

**Causa**: Azure Policy `Storage accounts should prevent shared key access` aplica al
recurso después de creación (deny+modify) y silenciosamente cambia el setting. Es típico
en MCAP/EA con baseline de seguridad de Microsoft.

**Verificación**:
```powershell
az storage account show -g <rg> -n <sa> --query allowSharedKeyAccess -o tsv
# 'false' aunque hayas pedido 'true'
```

**No hay fix técnico en el script**. Soluciones posibles:
1. Pedir excepción de la policy al admin para un SA específico (`Microsoft.Storage`
   exemption).
2. Crear el SA en otra sub sin la policy.
3. Usar Managed Identity-based access (solo para SQL Server 2022+).

### 🧪 0.12 — `az vm run-command` output truncado a 4096 bytes
**Síntoma**: scripts que devuelven output > 4 KB tienen el output cortado, sin warning.

**Causa**: `az vm run-command invoke` truncate `value[0].message` a 4096 bytes por
default.

**Workarounds**:
1. **Chunking**: dividir output en chunks de 2-3 KB y reensamblar.
2. **`az vm run-command create` (V2 managed)**: permite outputBlob donde el output va a
   un Blob storage (sin límite). Más complejo pero robusto.
3. **Azure VM Custom Script Extension**: para subir scripts grandes (no para output).
4. **WinRM directo**: si VPN/peering permite, conectar via WinRM con
   `Enter-PSSession`. Habilitar WinRM no es default en VMs Azure.
5. **Azure File Share mounted en la VM**: el script escribe el output al share, mi
   máquina lo lee.

**Para el módulo**: documentar en cualquier script que use run-command que outputs grandes
(certificados grandes, .bak files, logs largos) requieren chunking.

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
