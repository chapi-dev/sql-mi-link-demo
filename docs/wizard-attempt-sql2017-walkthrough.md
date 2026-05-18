# Walkthrough completo del wizard MI Link en SQL Server 2017 — y por qué bloquea

> **Veredicto rápido:** SQL Server 2017 CU31-GDR (la última versión disponible a fecha de este informe)
> tiene una **incompatibilidad estructural** con MI Link cross-region: el parser de `LISTENER_URL`
> no acepta la sintaxis `;Server=[…]` que el MI necesita para hacer el redirect interno a la réplica
> lógica. El wizard de SSMS tampoco completa porque usa una SP (`sp_certificate_add_issuer`)
> que solo existe en SQL Server 2022 CU13+.
>
> **Conclusión:** la combinación SQL Server 2017 → Azure SQL Managed Instance vía MI Link **no es
> viable en la práctica con la última versión disponible de SQL 2017**, a pesar de que la matriz
> oficial de Microsoft lo lista como soportado. Hay que migrar a SQL Server 2019 CU15+ o 2022 CU13+
> primero, o usar otro mecanismo de migración (DMS, BACPAC, log shipping…).

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

## Intento de recuperación manual vía T-SQL + REST API

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

## Conclusión

**SQL Server 2017 → Azure SQL Managed Instance vía MI Link** está documentado como soportado en la
[matriz de Microsoft](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/managed-instance-link-preparation),
pero en la práctica con la última versión disponible (CU31-GDR, KB5046858, Oct 2024) **no se puede
completar el link cross-region** por dos bugs interdependientes:

1. **SSMS Wizard** (ruta moderna "Microsoft PKI"): falla por
   `Could not find stored procedure 'sp_certificate_add_issuer'`. Esta SP solo existe en SQL Server
   2022 CU13+ y nunca llegará a SQL 2017.
2. **T-SQL manual** (ruta clásica): SQL Server 2017 rechaza con `Msg 19499 invalid listener URL`
   la sintaxis `;Server=[…]` que el MI necesita para redirigir las conexiones a la réplica lógica
   correcta. Sin esa sintaxis, el MI devuelve `error 41976` + log
   "Tried to send redirect request but the redirect string is empty".

Las **dos rutas oficiales están bloqueadas** por limitaciones del binario de SQL 2017.
No es un problema de red, de NSG, de certs, de master key, de permisos AAD ni de versión del MI.
Es del propio engine de SQL 2017.

### Recomendaciones

| Escenario | Camino recomendado |
|---|---|
| Migrar de SQL 2017 a MI con downtime mínimo | **Upgrade in-place a SQL Server 2019 CU15+ o 2022 CU13+** y luego MI Link |
| Migración con ventana de downtime de horas | **Azure Database Migration Service (DMS)** offline |
| Migración de schemas pequeños / dev-test | **BACPAC export/import** |
| Validar antes de comprar la migración | Levantar un VM con SQL 2019/2022 paralelo y probar MI Link allí |

### Estado final del entorno

- VM `vm-sql2017` con AG local `MILinkAG` SYNCHRONIZED, ingerir datos OK.
- Distributed AG `MILinkDAG` creado en SQL Server (sin `;Server=`).
- Trust cert `SQLServerVMCert` subido al MI.
- Link en MI (`distributedAvailabilityGroups/MILinkDAG`) creado pero en `LinkInitError 41976`.
  La MI puede haber autolimpiado el recurso transcurrido un tiempo (verificable con
  `GET .../distributedAvailabilityGroups/MILinkDAG`).
- No hay replicación de datos efectiva a MI.

Para limpiar todo:

```powershell
.\scripts\cleanup.ps1
```
