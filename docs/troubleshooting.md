# Troubleshooting

Catálogo de errores y workarounds observados al desplegar y operar un Managed
Instance Link entre SQL Server (on-prem / IaaS) y Azure SQL Managed Instance.

---

## Errores del Distributed AG

### 41986 — `Cannot promote the availability group to distributed`

**Síntoma**: el `ALTER AVAILABILITY GROUP … ADD AVAILABILITY GROUP ON …` se
ejecuta sin error en el origen, pero al consultar `sys.dm_hadr_database_replica_states`
el estado del replica remoto se queda en `NOT SYNCHRONIZING` o el comando devuelve
`Msg 41986`.

**Causas habituales**:

1. **Azure Connect Pack no instalado o SQL Server no reiniciado tras el install**.
   El parser de `LISTENER_URL` no entiende la sintaxis `;Server=[<MI_NAME>]`.
   Ver [`azure-connect-pack.md`](azure-connect-pack.md).
2. **Mismatch en la version del Database Mirroring endpoint**. Verificar:
   ```sql
   SELECT name, type_desc, state_desc, port
   FROM sys.tcp_endpoints
   WHERE type = 4;   -- DATABASE_MIRRORING
   ```
3. **El cert local no se registró en el MI**, o el cert del MI no se importó al
   SQL Server. El cert exchange tiene dos direcciones, ambas obligatorias.

**Fix**:

```sql
-- Verificar las stored procedures del Azure Connect Pack
SELECT name FROM sys.system_objects
WHERE name IN ('sp_certificate_add_issuer', 'sp_get_endpoint_certificate');

-- Si faltan: instalar el pack y reiniciar MSSQLSERVER.

-- Re-exportar e importar certs en ambos lados (en MI primero, luego SQL Server).
```

Si el wizard SSMS está construyendo el Link, dejar que lo recrease tras el
restart del servicio — repetir desde el wizard suele resolverlo.

---

### 41974 — `The connection attempt failed`

**Síntoma**: error de conectividad al construir el DAG. Mensaje suele incluir
`Cannot connect to '<host>:5022'`.

**Causas habituales**:

1. **NSG bloquea 5022/TCP** en el subnet del SQL Server o del MI.
2. **Windows Firewall** en la VM bloquea 5022 (la regla NSG no basta).
3. **Peering VNet no transitivo** o no establecido entre las dos regiones.
4. **Endpoint resolviendo a IP equivocada** (DNS privada vs pública).

**Diagnóstico**:

Desde el SQL Server origen:
```powershell
Test-NetConnection -ComputerName <mi-internal-ip> -Port 5022
```

Desde el MI (vía `tcping` desde otra VM en la misma VNet o usando `xp_cmdshell`
si está habilitado):
```powershell
Test-NetConnection -ComputerName <vm-public-ip-or-fqdn> -Port 5022
```

Ambos lados deben responder `TcpTestSucceeded: True`.

**Fix**:

```powershell
# NSG inbound rule en ambos lados, para 5022/TCP
az network nsg rule create -g <rg> --nsg-name <nsg> --name AllowMILink5022 `
  --priority 200 --access Allow --protocol Tcp `
  --source-address-prefixes <peer-vnet-cidr> `
  --destination-port-ranges 5022

# Windows Firewall
New-NetFirewallRule -DisplayName "MI Link 5022" -Direction Inbound `
  -Protocol TCP -LocalPort 5022 -Action Allow
```

---

### 41976 — `The authentication of the connection between the server endpoints failed`

**Síntoma**: TCP/5022 alcanzable, los logs del SQL Server muestran intentos de
handshake pero el TLS auth falla.

**Causa**: certificados intercambiados pero el cert del *otro lado* no está
registrado como issuer trusted.

**Diagnóstico**:

En SQL Server origen:
```sql
-- Certs locales
SELECT name, pvt_key_encryption_type_desc, subject
FROM sys.certificates WHERE pvt_key_encryption_type IS NOT NULL;

-- Issuers registrados (deben incluir el cert del MI)
SELECT * FROM sys.certificates WHERE issuer_name LIKE '%<mi-name>%';
```

En MI:
```sql
-- El MI debe tener el cert del SQL Server como issuer trusted
SELECT * FROM sys.certificates WHERE issuer_name LIKE '%<vm-host>%';
```

**Fix**: rehacer el cert exchange en orden estricto:

1. Generar/extraer el cert público del MI:
   ```sql
   -- En MI
   EXEC sys.sp_get_endpoint_certificate @endpoint_type = 4;
   -- Copiar el PEM resultante
   ```
2. Registrarlo como issuer en el SQL Server:
   ```sql
   -- En SQL Server
   EXEC sys.sp_certificate_add_issuer @public_certificate = N'-----BEGIN CERT---...';
   ```
3. Generar/extraer el cert público del SQL Server:
   ```sql
   -- En SQL Server
   EXEC sys.sp_get_endpoint_certificate @endpoint_type = 4;
   ```
4. Subirlo al MI vía REST API (el wizard SSMS lo hace transparente; manualmente
   se usa el endpoint `PUT /certificates` del Managed Instance).

---

## Errores de auth a MI

### 18452 — `Login failed. The login is from an untrusted domain`

**Síntoma**: al conectar SSMS a MI con SQL Authentication.

**Causa habitual**: el tenant tiene la política
*"Azure SQL Managed Instance should use Microsoft Entra-only authentication"*
activada. SQL Authentication está deshabilitada.

**Fix**: usar **Microsoft Entra MFA** o **Microsoft Entra Password** como
auth method en la conexión. Para que el usuario funcione debe ser:

- AAD Admin del MI (configurado en la pestaña *Active Directory admin*), o
- Estar mapeado dentro del MI con un user/role:
  ```sql
  -- Como AAD Admin
  CREATE USER [user@tenant.onmicrosoft.com] FROM EXTERNAL PROVIDER;
  ALTER SERVER ROLE sysadmin ADD MEMBER [user@tenant.onmicrosoft.com];
  ```

### 40532 — `Cannot open server requested by the login`

**Síntoma**: connect string apunta al FQDN público pero el MI solo tiene
endpoint privado, o viceversa.

**Fix**: verificar la configuración de endpoints del MI:

```bash
az sql mi show -g <rg-mi> -n <mi-name> `
  --query "{publicEndpoint:publicDataEndpointEnabled, fqdn:fullyQualifiedDomainName}"
```

- Endpoint privado: `<mi-name>.<dns-zone>.database.windows.net` puerto **1433**.
- Endpoint público: mismo FQDN pero puerto **3342** (¡ojo al puerto!).

Para conectar desde fuera de la VNet, habilitar el endpoint público
*solo si la política del tenant lo permite* y crear NSG con allowlist
restringida.

---

## Errores del endpoint de Database Mirroring

### 19499 — `The endpoint configuration is not valid`

**Síntoma**: al crear o alterar el endpoint mirror, el comando falla con
`The endpoint configuration is not valid`.

**Causas**:

- Cert asociado al endpoint expirado.
- Conflict de cert: dos endpoints intentan usar el mismo cert.
- Encryption mode incompatible (`REQUIRED` vs `DISABLED`).

**Fix**:

```sql
-- Drop endpoint y recrear desde cero
ALTER ENDPOINT Hadr_endpoint STATE = STOPPED;
DROP ENDPOINT Hadr_endpoint;

-- Crear nuevo cert (10 años validity por seguridad)
USE master;
CREATE CERTIFICATE [LinkCert]
    WITH SUBJECT = N'MI Link endpoint cert',
    EXPIRY_DATE = '2035-01-01';

CREATE ENDPOINT Hadr_endpoint
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        AUTHENTICATION = CERTIFICATE [LinkCert],
        ENCRYPTION = REQUIRED ALGORITHM AES,
        ROLE = ALL
    );
```

Luego rehacer el cert exchange.

---

### 2812 — `Could not find stored procedure 'sp_get_endpoint_certificate'`

**Causa**: Azure Connect Pack no instalado o SQL Server no reiniciado.

**Fix**: ver [`azure-connect-pack.md`](azure-connect-pack.md).

---

## Errores de seeding / replicación

### Seeding se queda colgado en `0% complete`

**Síntomas**: `sys.dm_hadr_physical_seeding_stats` muestra `transfer_rate_bytes_per_second = 0`
y `internal_state_desc = 'WAITING_FOR_DATA'`.

**Causas habituales**:

1. **Storage del MI lleno** durante el restore. Verificar `sys.dm_io_virtual_file_stats`
   y métricas `storage_used_mb` en el portal de MI.
2. **Network throttle entre regiones** — cross-region MI Link es `ASYNCHRONOUS`
   por diseño, pero puede ralentizarse drásticamente con BDs grandes.
3. **Endpoint mirroring con encryption fallando** — TLS handshake error en
   loop. Verificar SQL Server error log.

**Diagnóstico**:

```sql
SELECT
    local_database_name,
    role_desc,
    internal_state_desc,
    transfer_rate_bytes_per_second,
    transferred_size_bytes,
    database_size_bytes,
    100.0 * transferred_size_bytes / NULLIF(database_size_bytes, 0) AS pct_complete,
    failure_state_desc,
    failure_message
FROM sys.dm_hadr_physical_seeding_stats;
```

### Estado del DAG `SYNCHRONIZING` permanente

**No es un error**. En cross-region MI Link el modo es `ASYNCHRONOUS_COMMIT`,
y el estado normal es `SYNCHRONIZING HEALTHY`. **NUNCA** aparecerá como
`SYNCHRONIZED` (que solo se da con `SYNCHRONOUS_COMMIT`, no soportado cross-region).

Verificar `synchronization_health_desc = 'HEALTHY'` y `log_send_queue_size`,
`redo_queue_size` cerca de 0 son los indicadores reales de salud.

---

## Limitaciones de SQL Server 2017

### Replicación unidireccional

El Link en SQL Server 2017 (y 2016/2019) es **one-way**: SQL Server → MI.
Tras el cutover el Link se rompe y la única forma de volver al SQL Server origen
es vía las capas de rollback externas descritas en
[`migration-rollback-plan.md`](migration-rollback-plan.md).

> Para fail-back online vía Link es necesario SQL Server 2022/2025 con la
> update policy del MI configurada acorde.

### Compatibility level

SQL Server 2017 soporta compat level hasta **140**. Si la BD se promueve a
compat 150+ tras el cutover en MI, **rollback a 2017 deja de ser viable**
(features 2019+ presentes en metadata).

### Features bloqueantes para rollback

Ledger tables, ADR, edge constraints, UTF-8 collations, GENERATE_SERIES, etc.
no existen en 2017. Si se activan en MI tras el cutover, el rollback a 2017
falla en el import del BACPAC.

Lista completa en [`version-comparison.md`](version-comparison.md).

---

## Workarounds para políticas restrictivas del tenant

Aplica a tenants (corporativos, soberanos, etc.) que imponen políticas de
seguridad sobre los recursos Azure.

### `allowSharedKeyAccess = false` en Storage Accounts

**Impacto**: `BACKUP DATABASE … TO URL` con SAS basada en account key falla
con `Operating system error 50 (The request is not supported)`.

**Workarounds**:

1. **Solicitar exempt del policy** para el storage account de backups
   (vía governance / aprobación con el dueño del policy).
2. **Usar AzCopy con managed identity** + `BACKUP TO DISK`:
   ```sql
   BACKUP DATABASE <DbName>
       TO DISK = N'C:\sqlbackups\<DbName>_FULL.bak'
       WITH COMPRESSION, CHECKSUM;
   ```
   ```powershell
   azcopy login --identity
   azcopy copy "C:\sqlbackups\<DbName>_FULL.bak" `
     "https://<storage>.blob.core.windows.net/backups/<DbName>_FULL.bak"
   ```
3. **Usar `BACKUP TO URL` con AAD-based credential** (SQL 2022+ únicamente):
   ```sql
   CREATE DATABASE SCOPED CREDENTIAL [https://<storage>.blob.core.windows.net/backups]
       WITH IDENTITY = 'MANAGED IDENTITY';
   ```

### Soft-delete obligatorio en Recovery Services Vault

**Impacto**: al intentar borrar el vault o reducir la retención, devuelve
`BMSUserErrorDisablingSoftDeleteStateNotAllowed`. Forzosamente hay un periodo
de retención (por defecto 14 días).

**Workaround**: planificar la limpieza con esa retención forzada. No hay
override sin aprobación del policy.

### Endpoint público de MI bloqueado

**Impacto**: muchos tenants tienen un policy *"Public network access should be
disabled for Azure SQL Managed Instance"* que impide habilitar el endpoint
público (puerto 3342).

**Workarounds**:

1. Conectar a MI **siempre desde dentro de la VNet** (jumpbox, VPN P2S/S2S,
   Bastion).
2. Solicitar exempt del policy para el MI específico (poco probable que se apruebe).
3. Usar **Azure Bastion + jumpbox VM** con SSMS instalado.

---

## Errores de quotas / capacidad

### `Subscription has reached its limit for SQL Managed Instance vCores`

**Fix**: solicitar incremento de quota:
```bash
az quota update --resource-name standard_gen5_family_vcores `
  --target-region <region> --target-value <new-vcores> `
  --scope "/subscriptions/<sub-id>/providers/Microsoft.Capacity/locations/<region>"
```

O usar el portal: **Subscription → Usage + quotas → SQL Managed Instance**.

### `MI subnet must have at least N IP addresses available`

**Causa**: el subnet delegado al MI necesita un mínimo de 32 IPs libres (`/27`
o mayor) y solo puede contener MIs.

**Fix**: provisionar un subnet `/27` o mayor delegado a
`Microsoft.Sql/managedInstances`. No mezclar con otros recursos.

---

## Cómo leer los logs útiles

### SQL Server error log (origen)

```sql
EXEC sys.xp_readerrorlog 0, 1, N'%AlwaysOn%';
EXEC sys.xp_readerrorlog 0, 1, N'%Mirror%';
EXEC sys.xp_readerrorlog 0, 1, N'%Certificate%';
```

Filtrar por `Distributed Availability Group`, `Endpoint`, `Database Mirroring`.

### MI error log

Accesible vía:
```sql
-- Desde MI
SELECT TOP 1000 * FROM sys.fn_get_audit_file('https://<mi>.../auditlogs/*', NULL, NULL);
```

O vía portal: **MI → Diagnostic settings → Send to Log Analytics workspace**
→ tabla `AzureDiagnostics` con `Category = 'SQLSecurityAuditEvents'` para auditoría
y `'DatabaseMirroring'` para eventos del Link.

### Extended events session para diagnosticar el Link

```sql
CREATE EVENT SESSION [MILinkDiagnostic]
ON SERVER
ADD EVENT sqlserver.hadr_db_partner_set_sync_state,
ADD EVENT sqlserver.hadr_dump_log_progress,
ADD EVENT sqlserver.error_reported (
    WHERE error_number IN (41986, 41974, 41976, 19499, 2812)
)
ADD TARGET package0.ring_buffer;

ALTER EVENT SESSION [MILinkDiagnostic] ON SERVER STATE = START;

-- Consulta de eventos
SELECT CAST(target_data AS XML)
FROM sys.dm_xe_session_targets t
JOIN sys.dm_xe_sessions s ON t.event_session_address = s.address
WHERE s.name = 'MILinkDiagnostic';
```

---

## Referencias

- [Troubleshoot Managed Instance link](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-troubleshoot)
- [SQL Server distributed AG troubleshooting](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/troubleshoot-availability-groups)
- [MI policies and restrictions](https://learn.microsoft.com/azure/azure-sql/managed-instance/connectivity-architecture-overview)
