# Walkthrough visual del wizard MI Link (SQL Server 2017)

Este documento acompaña a [`ssms-wizard-guide.md`](ssms-wizard-guide.md) con capturas reales
de cada página del wizard SSMS sobre **SQL Server 2017 CU31+ con Azure Connect Pack**
(ver [`azure-connect-pack.md`](azure-connect-pack.md)).

Se incluyen tanto las pantallas del recorrido exitoso como los **errores típicos** que aparecen
si falta algún requisito (Azure Connect Pack, SQL Server Agent, AAD-only auth en el MI…) y la
forma de resolverlos.

Las capturas se generaron en un entorno de validación con:

- VM origen: Windows Server 2019 + SQL Server 2017 CU31-GDR + KB5050533 Azure Connect Pack.
- MI destino: General Purpose Gen5 4 vCores, **AAD-only auth**.
- Conectividad: VNet peering cross-region, puerto 5022 abierto en NSG y Windows Firewall.
- SSMS 21.x ejecutándose dentro de la VM (RDP).

Los nombres de instancia, RGs, FQDNs y suscripción son específicos del entorno donde se
generaron las capturas. Cualquier ingeniero verá los suyos propios al seguir el wizard.

---

## Estado inicial

Antes de lanzar el wizard, en la VM deben estar ya creados (siguiendo `runbook.md`):

- AG local *clusterless* en estado `SYNCHRONIZED / HEALTHY` con la única réplica local.
- Endpoint `Hadr_endpoint` en puerto 5022 con AES required.
- Master key + certificados local/remoto.
- Login `MIAGLogin` mapeado al certificado, con CONNECT GRANT sobre el endpoint.
- BD a replicar en `FULL` recovery, con backup completo aplicado.

![Estado inicial: AG local SYNCHRONIZED, BD con datos](images/wizard-walkthrough/00-initial-ssms-state-aglocal-synchronized.png)

> En este punto **la replicación es solo local al AG clusterless**: aún no hay Distributed AG
> creado → no hay replicación al MI todavía. El wizard se encargará de crear el DAG.

---

## Recorrido paso a paso del wizard

### 1. Lanzar el wizard

Object Explorer del SQL Server → click derecho sobre la BD →
**Tasks → Azure SQL Managed Instance link → New…**

![Object Explorer con la BD](images/wizard-walkthrough/01-object-explorer-databases.png)
![Tasks → Azure SQL Managed Instance link → New](images/wizard-walkthrough/02-tasks-menu-mi-link-new.png)

`Failover…` solo aplica cuando el link ya existe. `Test connection` y `Delete` son para
diagnóstico de un link ya creado.

### 2. Specify Link Options

![Link name](images/wizard-walkthrough/03-specify-link-options.png)

- **Link name**: nombre lógico del link (los AGs auxiliares se generan a partir de él).
- **Failover intent**: deshabilitado en SQL 2017 — *"Requires SQL Server 2022 or later"*.
  Confirma que el wizard detecta la versión: sin SQL 2022+ no hay *managed failover*.
- **Enable connectivity troubleshooting**: marcado para que el wizard guarde logs extra.

### 3. Requirements — Server readiness

![Server readiness](images/wizard-walkthrough/04-requirements-server-readiness.png)

Verde en los tres críticos:

- ✅ SQL Server: version check.
- ✅ SQL Server: Always On Availability Groups.
- ✅ SQL Server: sysadmin role membership.

Dos warnings amarillos (no bloqueantes):

- ⚠️ Recommended trace flag **1800** not enabled.
- ⚠️ Recommended trace flag **9567** not enabled.

El popup explica que los TF se activan vía SQL Server Configuration Manager
(`-T1800;-T9567` en *Startup Parameters*) y requieren reinicio del servicio.

![TF popup](images/wizard-walkthrough/05-tf1800-popup.png)

> En producción cross-region merece la pena activarlos (especialmente TF 9567, que comprime el
> log stream del AG y reduce el ancho de banda consumido por la replicación).

### 4. Requirements — Availability group readiness

![AG readiness](images/wizard-walkthrough/06-availability-group-readiness.png)

Verde en los cuatro: master key, mirroring endpoint, master key-encrypted, endpoint using master.
Todo el setup previo (master key + cert + endpoint en 5022) se valida correctamente.

### 5. Select Databases

![Select databases](images/wizard-walkthrough/07-select-databases.png)

La BD a replicar marcada, **Status: Ready**. Solo aparecen BDs en `FULL` recovery con backup
completo aplicado.

### 6. Specify Secondary Replica — añadir el MI

![Replicas empty](images/wizard-walkthrough/08-specify-secondary-replica-empty.png)

Aparece solo la primaria. **Add secondary replica…** abre el diálogo de Azure:

![Sign in dialog](images/wizard-walkthrough/09-sign-in-mi-public-endpoint-checkbox.png)

- Suscripción + Resource Group + MI destino.
- **`Use public endpoint (if enabled)` desmarcado** cuando el MI es alcanzable vía VNet peering
  por el endpoint privado 1433. Solo marcar si el MI tiene público habilitado y se va a usar
  esa ruta.

### 7. Conexión al MI — Error 18452 (untrusted domain)

Si el dropdown `Authentication` queda en **Windows Authentication** por defecto, la conexión
al MI falla:

![Error 18452](images/wizard-walkthrough/10-error-18452-untrusted-domain.png)

```text
Cannot connect to <mi-fqdn>.
Login failed. The login is from an untrusted domain and cannot be used with Integrated authentication.
(Microsoft SQL Server, Error: 18452)
```

**Causa**: una VM fuera del AD no puede autenticarse por Windows contra un MI. En entornos
con AAD-only auth, además, no existen logins SQL.

**Fix**: cambiar `Authentication` a **Microsoft Entra MFA**:

![Entra MFA](images/wizard-walkthrough/11-connect-server-entra-mfa.png)

User: el admin AAD del MI → ventana popup de Microsoft con MFA → conecta.

### 8. Network Checker — SQL Server Agent no habilitado

![Agent not enabled](images/wizard-walkthrough/12-network-checker-agent-not-enabled.png)

El **Network Checker** del wizard necesita SQL Server Agent corriendo para ejecutar trabajos
de prueba que validen conectividad DBM end-to-end (no solo TCP).

**Fix**:

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

| Campo | Valor esperado |
|---|---|
| Endpoint name | `Hadr_endpoint` |
| Port | `5022` |
| SQL MI name | FQDN del MI (`<mi>.<dns-zone>.database.windows.net`) |
| Server name | nombre NetBIOS de la VM |
| IP accesible desde Azure | IP privada de la VM, alcanzable vía peering |

### 10. Network Checker — todos los checks verdes

![Network Checker green](images/wizard-walkthrough/13-network-checker-all-green.png)

**11/11 tasks en verde** confirma:

- ✅ SQL Managed Instance can reach SQL Server on port 5022.
- ✅ SQL Server can reach SQL Managed Instance on ports 5022 and 11002.

### 11. Validation — todo verde

![Validation all green](images/wizard-walkthrough/15-validation-all-green.png)

**8/8 validations**: la BD no existe en MI, collations alineadas, storage suficiente, no
in-memory data, sysadmin OK, TDE OK, link name libre. Mensaje *"All validations are successful"*.

---

## Error típico cuando falta el Azure Connect Pack

Esta sección documenta el fallo más común al lanzar el wizard sobre **SQL Server 2017 sin
KB5050533 instalado**. Si la VM ya tiene el Azure Connect Pack, se salta directamente al
[apartado de resolución](#resultado-final-todo-verde).

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

> *"An exception occurred while executing a Transact-SQL statement or batch."*

`Show details` revela el detalle crítico:

![Advanced info](images/wizard-walkthrough/18-advanced-info-sp-certificate-add-issuer.png)

```text
Could not find stored procedure 'sp_certificate_add_issuer'.
(Framework Microsoft SqlClient Data Provider)

Error Number: 2812
Severity: 16

Stack:
  at Microsoft.SqlServer.Management.Hadr.ManagedInstanceLink
       .ManagedInstanceLinkWizardData.CreateMicrosoftCertificate(...)
  at Microsoft.SqlServer.Management.Hadr.ManagedInstanceLink
       .MIHybridLinkWorkItem.DoWork()
```

**Causa**: `sp_certificate_add_issuer` (junto a `sp_get_endpoint_certificate`) las añade el
**Azure Connect Pack KB5050533** a SQL Server 2017. No vienen ni en RTM ni en ningún CU oficial.

**Fix**: instalar KB5050533, reiniciar `MSSQLSERVER`, y relanzar el wizard. Receta completa
en [`azure-connect-pack.md`](azure-connect-pack.md).

> Síntoma equivalente al intentar la ruta manual (T-SQL + REST): `Msg 19499 invalid listener URL`
> al usar la sintaxis `tcp://<fqdn>:5022;Server=[<mi>]` requerida por el MI. El Azure Connect
> Pack también extiende el parser de `LISTENER_URL` para aceptar esa extensión.

### Cleanup antes de reintentar tras instalar el Connect Pack

Si el primer intento dejó un DAG fallido (en la VM y/o en el MI), hay que limpiarlo:

```powershell
$tok = az account get-access-token --query accessToken -o tsv
$sub = "<subscription-id>"
$rg  = "<rg-mi>"
$mi  = "<mi-name>"
$dag = "<failed-dag-name>"
$crt = "<uploaded-cert-name>"

# Borra el DAG fallido del lado MI
Invoke-RestMethod -Method DELETE -Headers @{Authorization="Bearer $tok"} `
  "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Sql/managedInstances/$mi/distributedAvailabilityGroups/$dag?api-version=2023-08-01"

# Borra el certificado subido al MI
Invoke-RestMethod -Method DELETE -Headers @{Authorization="Bearer $tok"} `
  "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Sql/managedInstances/$mi/serverTrustCertificates/$crt?api-version=2023-08-01"
```

```sql
-- Lado VM (si quedó algún DAG del intento manual):
DROP AVAILABILITY GROUP <failed-dag-name>;
-- El AG local clusterless con la BD SYNCHRONIZED se deja intacto.
```

---

## Resultado final: todo verde

Con el Azure Connect Pack instalado (engine `14.0.3490.10` o superior), el wizard completa las
**11 tareas en Success**:

| Tarea | Estado |
|---|---|
| Scripting setup | ✅ Success |
| Link name availability check on SQL Managed Instance | ✅ Success |
| **Create Microsoft PKI certificate** | ✅ **Success** (la SP ya existe) |
| Set up SQL Managed Instance authentication | ✅ Success |
| Set up SQL Server authentication | ✅ Success |
| Test connection MI → SQL Server | ✅ Success |
| Configure SQL Server availability group | ✅ Success |
| Create distributed availability group | ✅ Success |
| Join SQL Managed Instance to hybrid link | ✅ Success |
| Save link information | ✅ Success |
| Scripting cleanup | ✅ Success |

> El wizard nombra internamente el Distributed AG en formato kebab-case derivado del *link name*
> elegido. La réplica del lado MI sigue el patrón `AG_<DbName>_MI`.

### Verificación end-to-end

**En la VM (origen)**:

```sql
SELECT name, primary_replica, synchronization_health_desc
FROM sys.dm_hadr_availability_group_states s
JOIN sys.availability_groups g ON g.group_id = s.group_id;
-- AG local: primary_replica=<VM>, HEALTHY

SELECT ar.replica_server_name, ar.role_desc,
       hars.synchronization_state_desc,
       drs.log_send_queue_size, drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar  ON drs.replica_id = ar.replica_id
JOIN sys.dm_hadr_availability_replica_states hars ON drs.replica_id = hars.replica_id
WHERE ar.replica_server_name LIKE 'AG_%_MI%';
-- Esperado: SYNCHRONIZING / HEALTHY, LogQueue=0, RedoQueue=0
```

> Cross-region el modo es **`ASYNCHRONOUS_COMMIT`** → estado normal `SYNCHRONIZING / HEALTHY`
> (nunca llega a `SYNCHRONIZED`). Eso es esperado, no un fallo.

Inserción de una fila marker en la VM:

```sql
USE <DbName>;
INSERT INTO dbo.<TestTable>(Origin, Note)
VALUES ('VM-WIZARD-OK', 'marker post-link');
```

**En el MI (destino, AAD MFA)**:

```sql
USE <DbName>;
SELECT TOP 5 Id, Origin, Note, InsertedAt
FROM dbo.<TestTable>
ORDER BY Id DESC;
-- La fila marker debe aparecer en cuestión de segundos.
```

### Estado final visual

![BD Synchronized en VM y visible bajo Databases en el MI](images/wizard-walkthrough/19-success-demolink-replicated-both-sides.png)

La pestaña del SQL Server muestra la BD en `Synchronized`, y la pestaña del MI muestra la misma
BD expandida con todas sus carpetas (*Database Diagrams*, *Tables*, *Views*, *External Resources*,
*Synonyms*, *Programmability*, *Service Broker*, *Storage*, *Security*) — replicada y accesible.

---

## Resumen del flujo

```text
  ┌──────────────────┐    cert exchange   ┌────────────────────────┐
  │ Link Options     │ ─────────────────► │ Distributed AG         │
  │ Requirements     │                    │ (clusterless AG en VM  │
  │ Select Databases │     5022 / 11002   │  + réplica MI)         │
  │ Add MI replica   │ ─────────────────► │                        │
  │ Network Checker  │                    │ ASYNCHRONOUS_COMMIT    │
  │ Validation       │                    │ SYNCHRONIZING/HEALTHY  │
  │ Results          │ ─────────────────► │ LogQueue=0, RedoQueue=0│
  └──────────────────┘                    └────────────────────────┘
```

Para los pasos previos al wizard (provisioning, AG local, certificados, Azure Connect Pack)
ver [`runbook.md`](runbook.md) y [`azure-connect-pack.md`](azure-connect-pack.md).
Para la ruta sin wizard (CI/CD), ver [`manual-link-setup.md`](manual-link-setup.md).
Para errores comunes y workarounds, ver [`troubleshooting.md`](troubleshooting.md).
