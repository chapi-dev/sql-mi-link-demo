# Runbook técnico: levantar el escenario

Secuencia de pasos para desplegar un entorno de validación SQL Server →
Azure SQL Managed Instance con MI Link cross-region.

## 0. Prerrequisitos

- Azure CLI 2.60+ y, opcionalmente, GitHub CLI 2.40+.
- `az login` y `az account set --subscription "<sub-id>"` con permisos `Owner`
  (o `Contributor` + `Network Contributor` + `SQL Managed Instance Contributor`).
- Providers registrados: `Microsoft.Sql`, `Microsoft.Network`, `Microsoft.Compute`,
  `Microsoft.RecoveryServices`.
- Una identidad AAD (usuario o grupo) para el rol *Active Directory admin* del MI
  si el tenant impone AAD-only auth.
- SSMS 19+ o Azure Data Studio en una máquina con acceso a ambos endpoints.
- (Solo SQL Server 2017) tener identificado el origen del paquete
  **KB5050533 (Azure Connect Pack)** — ver [`azure-connect-pack.md`](azure-connect-pack.md).

> **Antes de levantar el entorno de migración real**, conviene validar la BD destino con una
> **POC de copia puntual** (backup + restore) en un MI pequeño, sin tocar producción. El
> procedimiento está en [`poc-snapshot-validation.md`](poc-snapshot-validation.md).
>
> Si la topología tiene **replicación entre instancias distintas** (transactional / snapshot
> replication, CDC, Service Broker cross-instance, linked servers), revisar también
> [`cross-instance-replication.md`](cross-instance-replication.md) para planificar el cutover
> en el orden adecuado.

## 1. Provisionar la infraestructura

```powershell
.\scripts\01-infra.ps1 `
  -SubId           "<sub-id>" `
  -VmAdminPwd      "<pwd-fuerte>" `
  -MiAadAdminUpn   "<upn>@<tenant>.onmicrosoft.com" `
  -MiAadAdminObjId "<aad-object-id>"
```

Provisiona:
- 2 resource groups (uno por región).
- 2 VNets + subnets + NSGs (subnet del MI delegada y con RT propia).
- Global VNet peering bidireccional.
- VM con SQL Server (imagen Marketplace).
- MI con AAD-only auth.

Verificar estado del MI:
```powershell
az sql mi show -g <rg-mi> -n <mi-name> --query state -o tsv
# Estados: Creating -> Created -> Ready
```

## 2. Conectar a la VM

```powershell
# IP pública
az vm show -g <rg-vm> -n <vm-name> -d --query publicIps -o tsv

# Opción 1: RDP con azureuser + pwd
# Opción 2: az vm run-command invoke para ejecutar scripts sin RDP
az vm run-command invoke -g <rg-vm> -n <vm-name> `
  --command-id RunPowerShellScript --scripts "Get-Service MSSQLSERVER"
```

## 3. Habilitar Always On AG

```powershell
.\scripts\00-enable-alwayson.ps1
```
Activa la feature y reinicia el servicio `MSSQLSERVER`.

Validar:
```sql
SELECT SERVERPROPERTY('IsHadrEnabled') AS HadrEnabled;  -- debe devolver 1
```

## 4. (Solo SQL Server 2017) Aplicar CU31 + Azure Connect Pack

```powershell
.\scripts\install-sql2017-cu31.ps1
```

Después, instalar **KB5050533** siguiendo
[`azure-connect-pack.md`](azure-connect-pack.md).

Validar versión y stored procedures requeridas:
```sql
SELECT SERVERPROPERTY('ProductVersion');  -- 14.0.3490.10 o superior
SELECT name FROM sys.system_objects
 WHERE name IN ('sp_certificate_add_issuer','sp_get_endpoint_certificate');
-- Debe devolver ambas filas
```

## 5. Preparar SQL Server: trace flags, master key, certificado, endpoint

```sql
:setvar MasterKeyPwd "<pwd-master>"
:r scripts\01-prepare-sql.sql
```

Verificar:
```sql
SELECT name, port, state_desc FROM sys.tcp_endpoints WHERE name='Hadr_endpoint';
-- debe estar STARTED en 5022

SELECT name FROM sys.certificates WHERE name='MILinkCert';
-- debe existir
```

Confirmar que `C:\MILink\MILinkCert.cer` (o la ruta que uses) se ha exportado.

## 6. Crear la base de datos demo

```sql
:r scripts\02-restore-sample-db.sql
```

Resultado:
- BD `DemoLink` en FULL recovery model.
- Backup full + log tomados (requisito para que el AG la admita).
- Tabla `dbo.DemoRows` con filas semilla.

## 7. Esperar a que el MI esté `Ready`

```powershell
az sql mi show -g <rg-mi> -n <mi-name> --query state -o tsv
```

Continuar cuando devuelve `Ready`.

## 8. Configurar el MI Link

### Opción A (recomendada) — wizard SSMS

1. Abrir SSMS y conectar al SQL Server origen (Windows o SQL auth).
2. Click derecho sobre la BD → **Tasks → Azure SQL Managed Instance link → New…**.
3. Seguir el wizard. El detalle de cada página está en
   [`ssms-wizard-guide.md`](ssms-wizard-guide.md), y hay un walkthrough con capturas reales
   paso a paso en [`wizard-walkthrough.md`](wizard-walkthrough.md).

### Opción B — T-SQL manual

Procedimiento completo en [`manual-link-setup.md`](manual-link-setup.md).
Útil para CI/CD, lotes de múltiples DBs o diagnóstico de fallos del wizard.

Resumen:

1. Importar en el SQL Server el certificado público del MI
   (vía `sys.sp_certificate_add_issuer`).
2. Importar en el MI el certificado público del SQL Server (`MILinkCert.cer`)
   vía REST API `PUT .../serverTrustCertificates`.
3. Editar y ejecutar `scripts\03-mi-link-setup.sql` con las variables
   `LocalServerName`, `MIName`, `MIDnsZone` correctas.
4. Unir el MI al DAG vía REST `PUT .../distributedAvailabilityGroups`.

## 9. Validar replicación

En el SQL Server origen:
```sql
SELECT
    ar.replica_server_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.log_send_queue_size,
    drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id;
```

Estado esperado en estado estable cross-region:
- `synchronization_state_desc` = `SYNCHRONIZING` (commit asíncrono cross-region es lo normal).
- `synchronization_health_desc` = `HEALTHY`.
- `log_send_queue_size` y `redo_queue_size` bajos o cero.

Test funcional:
```sql
USE DemoLink;
INSERT INTO dbo.DemoRows (Origin, Note) VALUES ('VM-after-link', 'should replicate');
```

Conectar al MI con AAD y verificar que la fila está visible.

## 10. Cutover

⚠️ **Antes del cutover** ejecuta el plan de rollback descrito en
[`migration-rollback-plan.md`](migration-rollback-plan.md).
En SQL 2016/2017/2019 el Link es one-way; el botón del pánico se construye fuera del Link.

### 10.1 Capa 1 — backup nativo pre-cutover

```powershell
.\scripts\06-pre-cutover-backup.ps1 -DbName "DemoLink"
```

Crea full + log con `COPY_ONLY` (no rompe la chain del Link).

### 10.2 Capa 2 — Azure Backup VM

```powershell
.\scripts\07-enable-azure-backup-vm.ps1
```

Crea Recovery Services Vault, protege la VM y lanza snapshot on-demand
(application-consistent vía VSS si la VM tiene la extensión VMSnapshot).

### 10.3 Cutover

```sql
:r scripts\04-cutover.sql
```

Tras esto la BD en MI queda como primaria standalone. En SQL 2016/2017/2019 el Link
**se rompe** (esperado). En SQL 2022/2025 con update policy alineada se mantiene
disponible para failback (ver [`version-comparison.md`](version-comparison.md)).

### 10.4 Capa 3 — congelar el primary

```sql
:r scripts\10-post-cutover-freeze-primary.sql
```

Deja la BD en el primary en `READ_ONLY` + auditing → sirve como rollback inmediato
mientras se valida el MI.

### 10.5 Rollback (si hace falta)

Elegir según la situación:
- **Inmediato**, app no escribió todavía en MI: `08-rollback-immediate.sql`.
- **Desde backup**, en cualquier momento: `09-rollback-restore-from-blob.sql`.
- **Tardío**, hay datos en MI que conservar: BACPAC (ver
  [`migration-rollback-plan.md`](migration-rollback-plan.md) Capa 4).

Decision matrix completa en [`migration-rollback-plan.md`](migration-rollback-plan.md).

## 11. Limpieza

```powershell
.\scripts\cleanup.ps1
```

Borra ambos resource groups del entorno de pruebas.
