# Walkthrough completo del wizard MI Link en SQL Server 2017

> **🎉 RESUELTO (mayo 2026 — día 2).** Lo que en la primera sesión pareció una incompatibilidad
> estructural de SQL 2017 era en realidad **un paquete que faltaba en la VM**: el
> **[SQL Server 2017 Azure Connect Pack (KB5050533, v14.0.3490.10)](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect)**,
> publicado el 6-marzo-2025. Ese paquete añade `sp_certificate_add_issuer`,
> `sp_get_endpoint_certificate` y extiende el parser de `LISTENER_URL` para aceptar `;Server=[…]`.
>
> **Veredicto actualizado:** SQL Server 2017 sí completa MI Link cross-region siempre que tenga
> instalados **CU31+** (o GDR equivalente) **y** el **Azure Connect Pack KB5050533**. Tras
> instalarlo, el SSMS Wizard completó las **11/11 tareas en verde** y la BD `DemoLink` replica
> de la VM (France Central) a la MI (Spain Central) en estado `SYNCHRONIZING / HEALTHY` (modo
> async, normal en cross-region), con `LogQueue=0` y `RedoQueue=0`.

> Este documento se conserva como walkthrough completo del wizard: la **primera parte** muestra el
> intento inicial que falló y por qué, y la **sección final ("Resolución…")** documenta el reintento
> exitoso tras instalar el Azure Connect Pack. La receta de instalación del paquete está en
> [`azure-connect-pack-install.md`](./azure-connect-pack-install.md).

---

## Contexto

- **Origen**: VM `vm-sql2017` en France Central, Windows Server 2019, **SQL Server 2017 CU31-GDR
  (KB5046858) v14.0.3485.1** — Developer Edition.
- **Destino**: `mi-link-demo-fraesp` en Spain Central, GP Gen5 4 vCores, AAD-only auth.
- **Conectividad**: Global VNet peering `10.10.0.0/16` ↔ `10.20.0.0/16`, puerto 5022 abierto en NSG y
  Windows Firewall. Endpoint privado MI por VNet peering, FQDN
  `mi-link-demo-fraesp.332838295123.database.windows.net`.
- **Base de datos**: `DemoLink` (16 MB, FULL recovery), con datos de inserción continua para validar
  la replicación.
- **Wizard usado**: el de SSMS (cliente RDP en la VM, SSMS 21.x).

Estado inicial al lanzar el wizard (de la sesión anterior ya quedaban el AG local `MILinkAG`,
el endpoint `Hadr_endpoint`, los certs `MILinkCert` / `MICert` y el login `MIAGLogin`):

![Estado inicial: AG MILinkAG SYNCHRONIZED, DemoLink con datos](images/wizard-walkthrough/00-initial-ssms-state-aglocal-synchronized.png)

> El AG local `MILinkAG` ya estaba `SYNCHRONIZED / HEALTHY` con la única réplica `VM-SQL2017`,
> y se observa `DemoLink` recibiendo filas. La **única replicación** en este punto es **local
> al AG clusterless**: no hay Distributed AG todavía → no hay replicación a la MI.

---

## Recorrido paso a paso del wizard

### 1. Lanzar el wizard

En el Object Explorer del SQL Server, click derecho sobre la base de datos `DemoLink` →
**Tasks → Azure SQL Managed Instance link → New…**

![Object Explorer con DemoLink](images/wizard-walkthrough/01-object-explorer-databases.png)
![Tasks → Azure SQL Managed Instance link → New](images/wizard-walkthrough/02-tasks-menu-mi-link-new.png)

`Failover…` no aplica todavía (solo sirve cuando el link existe). `Test connection` y `Delete` son
para diagnóstico de un link ya creado.

### 2. Specify Link Options

![Link name](images/wizard-walkthrough/03-specify-link-options.png)

- **Link name:** nombre lógico del link (los AGs auxiliares se generan a partir de él).
- **Failover intent:** deshabilitado — *"Requires SQL Server 2022 or later"*. Confirma que el wizard
  detecta la versión y deja claro que sin SQL 2022+ no hay managed failover.
- **Enable connectivity troubleshooting:** marcado para que el wizard guarde logs extra.

### 3. Requirements (Server readiness)

![Server readiness](images/wizard-walkthrough/04-requirements-server-readiness.png)

Verde en los tres críticos:
- ✅ SQL Server: Version check
- ✅ SQL Server: Always On Availability Groups
- ✅ SQL Server: Sysadmin role membership

Dos warnings amarillos (no bloqueantes):
- ⚠️ Recommended trace flag **1800** not enabled
- ⚠️ Recommended trace flag **9567** not enabled

El popup explica que los TF se activan manualmente vía SQL Server Configuration Manager
(`-T1800;-T9567` en Startup Parameters) y requieren reinicio del servicio. Para la demo se ignoraron
para no romper el AG actual:

![TF popup](images/wizard-walkthrough/05-tf1800-popup.png)

> En producción cross-region **sí merece la pena** activarlos (especialmente TF 9567 que comprime el
> log stream del AG → ahorro de ancho de banda).

### 4. Requirements (Availability group readiness)

![AG readiness](images/wizard-walkthrough/06-availability-group-readiness.png)

Verde en los cuatro: master key, mirroring endpoint, master key-encrypted, endpoint using master.
Todo el setup de la sesión anterior (master key + cert + endpoint en 5022) se valida correctamente.

### 5. Select Databases

![Select databases](images/wizard-walkthrough/07-select-databases.png)

`DemoLink` (16 MB) marcada, **Status: Ready**.

### 6. Specify Secondary Replica — añadir la MI

![Replicas empty](images/wizard-walkthrough/08-specify-secondary-replica-empty.png)

Aparece solo la primaria `vm-sql2017`. **Add secondary replica…** abre el diálogo de Azure:

![Sign in dialog](images/wizard-walkthrough/09-sign-in-mi-public-endpoint-checkbox.png)

- Suscripción `ME-MngEnvMCAP184496-antonioch-1`
- RG `rg-sqlmilink-mi-esp`
- MI `mi-link-demo-fraesp (Spain Central)`

**`Use public endpoint (if enabled)` desmarcado** — al estar en VNet peered, el endpoint privado
1433 es alcanzable y es el camino correcto.

### 7. Conexión a la MI — Error 18452 (untrusted domain)

Primer intento de **Sign in** falla porque por defecto usa `Windows Authentication` (que en una VM
fuera de un AD no funciona contra la MI):

![Error 18452](images/wizard-walkthrough/10-error-18452-untrusted-domain.png)

```
Cannot connect to mi-link-demo-fraesp.332838295123.database.windows.net.
Login failed. The login is from an untrusted domain and cannot be used with Integrated authentication.
(Microsoft SQL Server, Error: 18452)
```

**Causa**: la MI está configurada como **AAD-only** (la policy MCAPS bloquea SQL admin/password).
**Fix**: cambiar el dropdown `Authentication` a **Microsoft Entra MFA**:

![Entra MFA](images/wizard-walkthrough/11-connect-server-entra-mfa.png)

User: `admin@MngEnvMCAP184496.onmicrosoft.com` → ventana popup de Microsoft con MFA → conecta.

### 8. Network Checker — SQL Server Agent no habilitado

![Agent not enabled](images/wizard-walkthrough/12-network-checker-agent-not-enabled.png)

El **Network Checker** del wizard necesita SQL Server Agent corriendo en la VM para correr
trabajos de prueba que validen conectividad real (no solo TCP, sino DBM end-to-end).

**Fix** (ejecutado vía `az vm run-command` desde fuera de la VM):

```powershell
Set-Service -Name SQLSERVERAGENT -StartupType Automatic
Start-Service -Name SQLSERVERAGENT
```

```sql
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Agent XPs', 1;             RECONFIGURE;
```

Tras `Re-run Validation`, los checks pasan a verde.

### 9. Specify Network Options — endpoint mirroring y red

![Network options](images/wizard-walkthrough/14-network-options.png)

Auto-detectado correctamente:

| Campo | Valor |
|---|---|
| Endpoint name | `Hadr_endpoint` |
| Port | `5022` |
| SQL MI name | `mi-link-demo-fraesp.332838295123.database.windows.net` |
| Server name | `vm-sql2017` |
| IP accesible desde Azure | `10.10.1.4` (privada de la VM, alcanzable vía peering) |

### 10. Network Checker — todos los checks verdes

![Network Checker green](images/wizard-walkthrough/13-network-checker-all-green.png)

**11 de 11 tasks en verde** y el resumen confirma:
- ✅ SQL Managed Instance can reach SQL Server on port 5022
- ✅ SQL Server can reach SQL Managed Instance on ports 5022 and 11002

Este es el momento en el que se desbloquea el atasco de la sesión anterior: la red está limpia en
los dos sentidos, los firewall están bien, los endpoints se comunican.

### 11. Validation — todo verde

![Validation all green](images/wizard-walkthrough/15-validation-all-green.png)

**8 de 8 validations en verde**: la BD no existe en MI, collations alineadas, storage suficiente,
no in-memory data, sysadmin OK, TDE OK, link name libre. Mensaje "All validations are successful".

A esta altura **todo apunta a que el wizard va a completar**.

### 12. Results — ❌ Create Microsoft PKI certificate

![Results error](images/wizard-walkthrough/16-results-create-microsoft-pki-error.png)

El wizard cae al primer paso de cert exchange:

| Tarea | Estado |
|---|---|
| Scripting setup | ✅ Success |
| Link name availability check on SQL Managed Instance | ✅ Success |
| **Create Microsoft PKI certificate** | ❌ **Error** |
| (resto) | (no ejecutado) |

`Link creation operation has failed.`

### 13. El error real

El popup inicial es genérico:

![Generic error](images/wizard-walkthrough/17-error-popup-generic.png)

> "An exception occurred while executing a Transact-SQL statement or batch."

Pero `Show details` revela el detalle crítico:

![Advanced info](images/wizard-walkthrough/18-advanced-info-sp-certificate-add-issuer.png)

```
Could not find stored procedure 'sp_certificate_add_issuer'.
(Framework Microsoft SqlClient Data Provider)

Server Name: vm-sql2017
Error Number: 2812
Severity: 16
State: 62
Line Number: 1

Stack:
  at Microsoft.SqlServer.Management.Hadr.ManagedInstanceLink
       .ManagedInstanceLinkWizardData.CreateMicrosoftCertificate(...)
  at Microsoft.SqlServer.Management.Hadr.ManagedInstanceLink
       .MIHybridLinkWorkItem.DoWork()
```

`sp_certificate_add_issuer` **solo existe en SQL Server 2022 CU13+**. SQL Server 2017 nunca la tendrá.
El wizard de SSMS 21.x intenta usar la ruta moderna ("Microsoft PKI") sin tener fallback compatible
para SQL 2017.

---

## Intento de recuperación manual vía T-SQL + REST API (también fallido, mismo motivo)

> **Nota mayo 2026 día 2**: esta sección documenta el segundo callejón sin salida del **primer
> intento** (antes de instalar el Azure Connect Pack). Falla por la misma causa raíz que el wizard:
> faltaba KB5050533, así que el parser de `LISTENER_URL` no aceptaba `;Server=[…]`. Se conserva
> como referencia. Con el Azure Connect Pack instalado, esta misma secuencia funciona.

Tras el fallo del wizard, se intentó terminar el setup vía T-SQL en la VM y REST API contra el MI,
reutilizando lo que el wizard sí dejó preparado.

### Estado verificado en SQL Server tras el wizard

| Recurso | Estado |
|---|---|
| Master key (encrypted by service master key) | ✅ |
| Cert local `MILinkCert` (encrypted by master key, válido hasta 2099) | ✅ |
| Cert remoto `MICert` (cert MI importado, válido hasta 2026-08-25) | ✅ |
| Cert `MicrosoftPKI` (root CA, lo dejó el wizard antes de petar) | ✅ |
| Endpoint `Hadr_endpoint` puerto 5022 STARTED, AES required | ✅ |
| Login `MIAGLogin` (CERTIFICATE_MAPPED_LOGIN) con CONNECT GRANT en endpoint | ✅ |
| AG local `MILinkAG` clusterless con `DemoLink` SYNCHRONOUS_COMMIT | ✅ |

### Pasos ejecutados

1. **Export de `MILinkCert` desde SQL Server** a `C:\MILink\MILinkCert.cer` (738 bytes, ya existía
   del setup previo).
2. **Subida del cert a MI** como `ServerTrustCertificate` vía REST API
   (`PUT .../serverTrustCertificates/SQLServerVMCert?api-version=2023-08-01`). Validado: aparece en
   la lista con thumbprint `64428D2382D2784D70E5517BCBB48ABD520F50E1`.
3. **Creación del Distributed AG `MILinkDAG`** en SQL Server con la sintaxis `LISTENER_URL` sin
   extensión `;Server=`:

   ```sql
   CREATE AVAILABILITY GROUP [MILinkDAG]
   WITH (DISTRIBUTED)
   AVAILABILITY GROUP ON
      N'MILinkAG' WITH (
         LISTENER_URL = N'tcp://vm-sql2017:5022',
         AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
         FAILOVER_MODE = MANUAL,
         SEEDING_MODE = AUTOMATIC),
      N'mi-link-demo-fraesp' WITH (
         LISTENER_URL = N'tcp://mi-link-demo-fraesp.332838295123.database.windows.net:5022',
         AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
         FAILOVER_MODE = MANUAL,
         SEEDING_MODE = AUTOMATIC);
   ```

   ✅ Aceptado por SQL Server.

4. **Creación del lado MI del link** vía REST API
   (`PUT .../distributedAvailabilityGroups/MILinkDAG?api-version=2023-08-01`):

   ```json
   {
     "properties": {
       "distributedAvailabilityGroupName": "MILinkDAG",
       "instanceAvailabilityGroupName": "mi-link-demo-fraesp",
       "partnerAvailabilityGroupName": "MILinkAG",
       "partnerEndpoint": "tcp://10.10.1.4:5022",
       "databases": [{"databaseName": "DemoLink"}],
       "failoverMode": "None",
       "replicationMode": "Async",
       "seedingMode": "Automatic",
       "instanceLinkRole": "Secondary"
     }
   }
   ```

   ✅ HTTP 202 Accepted, operación `DistributedAvailabilityGroupsLinkCreate` iniciada.

### Resultado: el mismo error 41976 de la sesión anterior

Polling del status devuelve:

```json
{
  "databases": [{
    "databaseName": "DemoLink",
    "mostRecentLinkError": "41976",
    "partnerAuthCertValidity": {
      "certificateName": "SQLServerVMCert",
      "expiryDate": "2099-12-31T00:00:00Z"
    },
    "replicaState": "LinkInitError"
  }]
}
```

Y en el SQL Server error log:

```
Database Mirroring login attempt failed with error:
'Tried to send redirect request but the redirect string is empty'.
[SERVER: 10.20.0.9]
```

`10.20.0.9` es la IP de la MI en `vnet-mi-esp`.

### El bug: SQL Server 2017 rechaza la sintaxis `;Server=[…]` en LISTENER_URL

El error "redirect string is empty" sugiere que el MI necesita el sufijo `;Server=[<MI_NAME>]` en la
LISTENER_URL para saber a qué réplica lógica de su cluster redirigir. La documentación oficial
([learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-create-replication-script](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/managed-instance-link-create-replication-script))
lo muestra como el formato esperado:

```sql
LISTENER_URL = N'tcp://<MI_FQDN>:5022;Server=[<MI_NAME>]'
```

Probadas **tres variantes** en SQL Server 2017 CU31-GDR:

| Variante | Resultado |
|---|---|
| `tcp://mi-link-demo-fraesp.332838295123.database.windows.net:5022;Server=[mi-link-demo-fraesp]` | ❌ Msg 19499: invalid listener URL |
| `tcp://...,5022;Server=[...]` (coma para el puerto) | ❌ Msg 19499 |
| `TCP://...:5022;Server=[...]` (uppercase) | ❌ Msg 19499 |
| `tcp://10.20.0.9:5022;Server=[mi-link-demo-fraesp]` (IP directa) | ❌ Msg 19499 |
| `tcp://...:5022` (sin `;Server=`) | ✅ aceptado por SQL Server, ❌ rechazado por MI con `41976` |

Versión exacta probada:

```
Microsoft SQL Server 2017 (RTM-CU31-GDR) (KB5046858) - 14.0.3485.1 (X64)
Oct 17 2024 16:14:54
Developer Edition (64-bit) on Windows Server 2019 Datacenter
```

Es **la última versión publicada de SQL Server 2017** (mainstream support cerrado en oct 2022,
extended support solo recibe parches de seguridad GDR). Es decir, **no hay un CU posterior a este
que pueda traer el fix**.

---

## Conclusión del primer intento (con SQL 2017 14.0.3485.1, **sin** Azure Connect Pack)

Los errores `Msg 2812 sp_certificate_add_issuer` (wizard) y `Msg 19499 invalid listener URL` /
`error 41976 LinkInitError` (T-SQL manual) **no son** un bug estructural ni una incompatibilidad
permanente: son síntomas de **que faltaba el Azure Connect Pack KB5050533** en la VM. La matriz
oficial de Microsoft está bien — solo que el requisito del Connect Pack vive en
[una página aparte](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect)
y es fácil pasarlo por alto.

---

## Resolución: instalar el Azure Connect Pack KB5050533 y reintentar

Tras una jornada infructuosa intentando el T-SQL manual, un compañero apuntó al
**SQL Server 2017 Azure Connect Pack** (KB5050533, v14.0.3490.10, publicado el 6 de marzo de 2025).
Receta completa de descarga + instalación en
[`azure-connect-pack-install.md`](./azure-connect-pack-install.md). Resumen:

1. Descargar el instalador (542 MB) del Microsoft Update Catalog en la VM (BITS async).
2. Instalar en silencio:
   ```powershell
   Start-Process -FilePath "C:\MILink\KB5050533-AzureConnect.exe" `
     -ArgumentList '/quiet','/allinstances','/IAcceptSQLServerLicenseTerms' -Wait
   ```
3. Esperar reinicio de servicios (`MSSQLSERVER` + `SQLSERVERAGENT`).
4. Validar:
   ```sql
   SELECT @@VERSION;  -- Microsoft SQL Server 2017 ... 14.0.3490.10 (X64)
   SELECT name FROM sys.system_objects
    WHERE name IN ('sp_certificate_add_issuer','sp_get_endpoint_certificate');
   -- Ambas deben aparecer.
   ```

### Cleanup antes de reintentar el wizard

Hay que limpiar el Distributed AG fallido del primer intento, tanto en la MI como en la VM, para
que el wizard parta de cero:

```powershell
# Lado MI: borrar el DAG fallido y el cert subido
$sub = "57b74ad7-4e8a-4221-b993-59b7df78c096"
$rg  = "rg-sqlmilink-mi-esp"
$mi  = "mi-link-demo-fraesp"
$tok = (az account get-access-token --query accessToken -o tsv)

Invoke-RestMethod -Method DELETE -Headers @{Authorization="Bearer $tok"} `
  "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Sql/managedInstances/$mi/distributedAvailabilityGroups/MILinkDAG?api-version=2023-08-01"

Invoke-RestMethod -Method DELETE -Headers @{Authorization="Bearer $tok"} `
  "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Sql/managedInstances/$mi/serverTrustCertificates/SQLServerVMCert?api-version=2023-08-01"
```

```sql
-- Lado VM (si quedó algún DAG/AG del intento manual):
DROP AVAILABILITY GROUP MILinkDAG;
-- El AG local MILinkAG con DemoLink SYNCHRONIZED se deja intacto.
```

### Segundo intento del wizard — todo verde

Tras instalar KB5050533 (versión engine = `14.0.3490.10`) y limpiar el DAG fallido:

1. Re-conectar SSMS al SQL Server (`vm-sql2017`, Windows auth) y a la MI
   (`mi-link-demo-fraesp.332838295123.database.windows.net`, **Microsoft Entra MFA**).
2. Click derecho `DemoLink` → Tasks → Azure SQL Managed Instance link → New.
3. Mismos pasos del walkthrough anterior (Link name, Requirements, Select DBs, Add MI, Network
   Checker 11/11 verde, Validation 8/8 verde).
4. **Results**: todas las tareas en **Success**:

| Tarea | Estado |
|---|---|
| Scripting setup | ✅ Success |
| Link name availability check on SQL Managed Instance | ✅ Success |
| **Create Microsoft PKI certificate** | ✅ **Success** (la SP ya existe) |
| Set up SQL Managed Instance authentication | ✅ Success |
| Set up SQL Server authentication | ✅ Success |
| Test connection MI → SQL Server | ✅ Success |
| Configure SQL Server availability group | ✅ Success |
| Create distributed availability group (database `DemoLink`) | ✅ Success |
| Join SQL Managed Instance to hybrid link | ✅ Success |
| Save link information | ✅ Success |
| Scripting cleanup | ✅ Success |

> El wizard nombró internamente el Distributed AG **`demo-link`** (variante kebab-case del link
> name elegido), y la réplica del lado MI **`AG_DemoLink_MI`**.

### Verificación end-to-end

**En la VM (origen):**
```sql
SELECT name, primary_replica, synchronization_health_desc
FROM sys.dm_hadr_availability_group_states s
JOIN sys.availability_groups g ON g.group_id = s.group_id;
-- MILinkAG: primary_replica=VM-SQL2017, HEALTHY

SELECT ar.replica_server_name, ar.role_desc, hars.synchronization_state_desc,
       drs.log_send_queue_size, drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar  ON drs.replica_id = ar.replica_id
JOIN sys.dm_hadr_availability_replica_states hars ON drs.replica_id = hars.replica_id
WHERE ar.replica_server_name LIKE 'AG_DemoLink_MI%';
-- SYNCHRONIZING / HEALTHY, LogQueue=0, RedoQueue=0
```

Inserción de la fila marker en la VM:
```sql
USE DemoLink;
INSERT INTO dbo.DemoRows(Origin, Note) VALUES ('VM-WIZARD-OK-LIVE','marker post-resolution');
-- Devuelve Id=504
```

**En la MI (destino, AAD MFA):**
```sql
USE DemoLink;
SELECT TOP 5 Id, Origin, Note, InsertedAt FROM dbo.DemoRows ORDER BY Id DESC;
-- La fila Id=504 aparece, confirmando replicación end-to-end.
```

### Estado final visual

![Replicación verificada: DemoLink Synchronized en VM y DemoLink visible bajo Databases en la MI](images/wizard-walkthrough/19-success-demolink-replicated-both-sides.png)

`vm-sql2017 (SQL Server 14.0.3490.10 - sa)` muestra `DemoLink (Synchronized)`, y
`mi-link-demo-fraesp.332838295123.data...` muestra `DemoLink` expandido con todas sus carpetas
(Database Diagrams, Tables, Views, External Resources, Synonyms, Programmability, Service Broker,
Storage, Security).

---

## Conclusión final

**MI Link cross-region desde SQL Server 2017 a Azure SQL Managed Instance funciona** siempre
que se cumplan los **dos** requisitos:

1. **CU31** (`14.0.3456.2`) o un GDR posterior (p. ej. CU31-GDR `14.0.3485.1` de octubre 2024).
2. **Azure Connect Pack KB5050533** (`14.0.3490.10`) — añade `sp_certificate_add_issuer`,
   `sp_get_endpoint_certificate` y extiende el parser de `LISTENER_URL` para aceptar `;Server=[…]`.

La matriz oficial de Microsoft es correcta — solo conviene asegurarse de instalar **ambos**
paquetes, porque el requisito del Connect Pack vive en una página aparte
([troubleshoot/sql/releases/sqlserver-2017/azureconnect](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect))
y no aparece destacado en la matriz principal de soporte.

### Limitaciones reales (operativas) que siguen aplicando a SQL Server 2017

| Tema | Detalle |
|---|---|
| Failover | Solo unidireccional VM → MI. No hay managed failover ni failback (eso es SQL 2022 CU13+). |
| Cutover | Manual: BD en read-only → esperar `LogQueue=0` y `RedoQueue=0` → `DROP AVAILABILITY GROUP` del DAG en la VM → la MI queda standalone. |
| Rollback | Manual con backups en SQL Server. Tras cutover, la BD en MI está en formato MI nativo y no se puede importar de vuelta. |
| Modo de replicación cross-region | `ASYNCHRONOUS_COMMIT` → estado normal `SYNCHRONIZING / HEALTHY` (no `SYNCHRONIZED`). |
| Granularidad | Un link por base de datos. |

### Estado final del entorno demo

- VM `vm-sql2017` con Azure Connect Pack instalado (engine `14.0.3490.10`).
- AG local `MILinkAG` SYNCHRONIZED / HEALTHY.
- Distributed AG `demo-link` cross-region: SYNCHRONIZING / HEALTHY (modo async, normal).
- Réplica `AG_DemoLink_MI` en MI con `DemoLink` accesible vía Object Explorer y SQL.
- Marker row Id=504 `VM-WIZARD-OK-LIVE` replicada de VM a MI.

Para limpiar todo cuando ya no se necesite:

```powershell
.\scripts\cleanup.ps1
```
