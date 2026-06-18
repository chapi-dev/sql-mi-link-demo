# Runbook: ejecución end-to-end del módulo

Secuencia ejecutable que orquesta TODOS los pasos para migrar de SQL Server 2017
(NorthEU) a SQL Server 2022 (Spain Central). Es la guía paso a paso que une los 10 docs
de diseño con los scripts ejecutables.

> 📘 Pre-lectura obligatoria (en orden):
> 1. [`README.md`](README.md)
> 2. [`official-microsoft-guidance.md`](official-microsoft-guidance.md)
> 3. [`rpo-options.md`](rpo-options.md) (decidir modo: A/B/C)
> 4. [`architecture.md`](architecture.md)
> 5. [`networking.md`](networking.md)

Sin haber leído estos no se pueden seguir los pasos con criterio.

---

## 0. Prerequisitos globales

### Acceso y permisos
- [ ] Acceso `Owner` (o equivalentes granulares) a la subscription Azure con el RG `rg-milink-vm` existente.
- [ ] Permisos para crear nuevos RGs/VNets/NSGs/VMs en Spain Central.
- [ ] Acceso SSH/RDP a `vm-sql2017` con cuenta `sysadmin` en SQL.
- [ ] Azure CLI 2.60+ (`az version`).
- [ ] PowerShell 7.4+ (recomendado) con módulo `Az` y `dbatools`:
  ```powershell
  Install-Module Az -Scope CurrentUser -Force
  Install-Module SqlServer -Scope CurrentUser -Force
  Install-Module dbatools -Scope CurrentUser -Force
  ```

### Información a recopilar antes de empezar
- [ ] Nombre exacto de la BD a migrar (`<AppDb>`).
- [ ] Tamaño actual de la BD (`SELECT SUM(size)*8/1024 FROM sys.master_files WHERE database_id = DB_ID('<AppDb>')`).
- [ ] ¿Usa TDE? (`SELECT name, is_encrypted FROM sys.databases`).
- [ ] ¿Tiene FILESTREAM? (`SELECT name, is_filestream_db FROM sys.databases`).
- [ ] Connection string actual de la app.
- [ ] Lista de logins críticos (`SELECT name FROM sys.server_principals WHERE type IN ('S','U','G') AND name NOT LIKE '##%'`).
- [ ] Lista de jobs SQL Agent críticos.
- [ ] Lista de linked servers (`SELECT name FROM sys.servers WHERE is_linked = 1`).
- [ ] Estrategia post-cutover decidida (A/B/C/D — ver [`post-cutover-strategies.md`](post-cutover-strategies.md)).

---

## 1. Fase 1 — Provisionar infraestructura SpainC (T-14d)

> Asume modo ASYNC default. Si modo SYNC, revisar [`rpo-options.md`](rpo-options.md) primero.

### 1.1 Crear RG, VNet, NSG, peering
```powershell
.\scripts\modules\sql2017-to-sql2022\01-infra-spain.ps1 `
    -SubId "<sub-id>" `
    -RgNE "rg-milink-vm" `
    -VnetNE "vnet-vm" `
    -SubnetNECidr "10.10.1.0/24" `
    -RgSC "rg-mig-spainc" `
    -LocSC "spaincentral" `
    -VnetSC "vnet-mig-spainc" `
    -VnetSCCidr "10.30.0.0/16" `
    -SubnetSCCidr "10.30.1.0/24"
```

Output esperado: peering bidireccional en estado `Connected`, NSG con regla 5022 inbound.

### 1.2 Provisionar VM SQL 2022
```powershell
.\scripts\modules\sql2017-to-sql2022\02-install-sql2022.ps1 `
    -RgSC "rg-mig-spainc" `
    -LocSC "spaincentral" `
    -VmName "vm-sql2022" `
    -VmSize "Standard_E4ads_v5" `
    -VmAdminUser "azureuser" `
    -VmAdminPwd "<pwd-fuerte>"
```

Output: VM con SQL Server 2022 Marketplace image, Always On habilitado, firewall 5022 abierto.

### 1.3 Provisionar Storage Account intermedio
```powershell
.\scripts\modules\sql2017-to-sql2022\03-create-storage.ps1 `
    -RgSC "rg-mig-spainc" `
    -LocSC "spaincentral" `
    -SaName "stmilinkmig$(Get-Random -Maximum 9999)"
```

Output: SA con containers `seeding`, `cutover-backups`, `rollback`, `migration`. SAS guardado en `$SasToken`.

### 1.4 Validar conectividad
```powershell
.\scripts\modules\sql2017-to-sql2022\04-validate-network.ps1 `
    -VmNE "vm-sql2017" -VmSC "vm-sql2022" -Port 5022
```

Output: 100/100 muestras TCP exitosas + RTT promedio.

---

## 2. Fase 2 — Preparar SQL Server destination (T-10d)

### 2.1 Crear master key, cert, endpoint
```sql
-- Desde sqlcmd o SSMS, conectado a vm-sql2022:
:r .\scripts\modules\sql2017-to-sql2022\05-prepare-sql2022.sql
```

Lo que hace:
- `CREATE MASTER KEY` con password.
- `CREATE CERTIFICATE SpainCCert`.
- `CREATE ENDPOINT Hadr_endpoint` TCP 5022 con cert auth.
- `BACKUP CERTIFICATE` a `C:\certs\SpainCCert.cer`.

### 2.2 Cert exchange (intercambiar certs)
```powershell
.\scripts\modules\sql2017-to-sql2022\06-cert-exchange.ps1 `
    -VmNE "vm-sql2017" -VmSC "vm-sql2022" `
    -CertNE "NorthEUCert" -CertSC "SpainCCert"
```

Lo que hace:
- Descarga el `.cer` de cada VM.
- Lo sube a la otra VM.
- Crea login + cert + GRANT CONNECT en ambos lados.

### 2.3 Migrar Master Key/cert TDE (solo si TDE habilitado)
```powershell
.\scripts\modules\sql2017-to-sql2022\07-migrate-tde-cert.ps1 `
    -VmNE "vm-sql2017" -VmSC "vm-sql2022" `
    -TdeCertName "TDECert" -Password "<pwd-temporal>"
```

Saltar si no usa TDE.

---

## 3. Fase 3 — Manual seeding de la BD (T-7d)

Recordar: AUTOMATIC seeding **no funciona** cross-version.

### 3.1 Backup full + log en NorthEU → Blob
```sql
-- En vm-sql2017:
:r .\scripts\modules\sql2017-to-sql2022\08-backup-for-seeding.sql
-- Pre-requisito: configurar credential SAS en master (ver networking.md §7)
```

Output: `AppDb_full_seed.bak` + `AppDb_log_seed.trn` en container `seeding`.

### 3.2 Restore con NORECOVERY en SpainC
```sql
-- En vm-sql2022:
:r .\scripts\modules\sql2017-to-sql2022\09-restore-for-seeding.sql
```

Output: BD `<AppDb>` en estado `RESTORING` en vm-sql2022.

### 3.3 Migrar logins, jobs, linked servers, configs
```powershell
# Logins via sp_help_revlogin + ejecutar en destino
sqlcmd -S vm-sql2017 -Q "EXEC sp_help_revlogin" -o "C:\migration\logins.sql"
sqlcmd -S vm-sql2022 -i "C:\migration\logins.sql"

# O usar dbatools (recomendado):
.\scripts\modules\sql2017-to-sql2022\10-migrate-oob-objects.ps1 `
    -SourceVm "vm-sql2017" -DestVm "vm-sql2022" `
    -SaPassword "<pwd>"
```

Lo que hace (con `dbatools`):
- `Copy-DbaLogin` (preserva SIDs + passwords)
- `Copy-DbaAgentJob -DisableOnDestination`
- `Copy-DbaAgentOperator`, `Copy-DbaAgentAlert`
- `Copy-DbaLinkedServer`
- `Copy-DbaCredential` (si pasas el secret)
- `Copy-DbaDbMail`
- `Copy-DbaSpConfigure`
- `Copy-DbaResourceGovernor`

Detalles en [`out-of-band-objects.md`](out-of-band-objects.md).

---

## 4. Fase 4 — Crear AGs locales (T-5d)

### 4.1 AG local en NorthEU
Si ya existe `MILinkAG` del módulo MI Link del repo, **NO usarlo** — interfiere con el nuevo
DAG. Crear uno nuevo separado o pausar el MI Link durante esta migración.

```sql
-- En vm-sql2017:
:r .\scripts\modules\sql2017-to-sql2022\11-create-local-ag-northeu.sql
```

### 4.2 AG local en SpainC
```sql
-- En vm-sql2022:
:r .\scripts\modules\sql2017-to-sql2022\12-create-local-ag-spainc.sql
```

### 4.3 Validar
```sql
-- Desde ambas VMs:
SELECT name, primary_replica, synchronization_health_desc
FROM sys.availability_groups
JOIN sys.dm_hadr_availability_replica_states ON ...;
```

Esperado: ambos AGs en estado `HEALTHY`.

---

## 5. Fase 5 — Crear Distributed AG (T-4d)

### 5.1 Permisos previos
```sql
-- En vm-sql2022 (forwarder):
ALTER AVAILABILITY GROUP [AG_SpainC] GRANT CREATE ANY DATABASE;
```

### 5.2 Crear DAG (manual seeding)
```sql
-- En vm-sql2017 (global primary):
:r .\scripts\modules\sql2017-to-sql2022\13-create-distributed-ag.sql
```

### 5.3 Join del segundo AG al DAG
```sql
-- En vm-sql2022:
:r .\scripts\modules\sql2017-to-sql2022\14-join-distributed-ag.sql
```

### 5.4 Añadir BD al AG en SpainC (BD ya restaurada con NORECOVERY)
```sql
-- En vm-sql2022:
ALTER DATABASE [AppDb] SET HADR AVAILABILITY GROUP = AG_SpainC;
```

### 5.5 Monitorizar la sincronización
```sql
-- Bucle de monitoring (cada 30s)
SELECT
    ag.name, ar.replica_server_name, drs.synchronization_state_desc,
    drs.synchronization_health_desc, drs.log_send_queue_size, drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id;
```

Esperar a `synchronization_state_desc = SYNCHRONIZING` (es ASYNC), `synchronization_health_desc = HEALTHY`, `log_send_queue_size < 5000`.

---

## 6. Fase 6 — Período de estabilización (T-3d a T-1d)

Durante estos 2-3 días el DAG está activo y sincronizando. Aprovechar para:

- Monitorizar `log_send_queue_size` — debe estabilizarse en valores bajos.
- Monitorizar `last_commit_time` lag — debe ser < 30 segundos.
- Practicar el protocolo de cutover **en staging** si existe.
- Comunicar fecha/hora del cutover real a stakeholders.
- Validar que los backups Capa 1 (T-24h del cutover) están planeados.
- Revisar la decisión de estrategia post-cutover.

---

## 7. Fase 7 — Cutover (T+0)

**Pre-cutover (T-24h)**:
```sql
-- En vm-sql2017:
:r .\scripts\modules\sql2017-to-sql2022\15-pre-cutover-backup.sql
-- Output: backup full + log a container 'cutover-backups' (Capa 1 rollback)
```

```powershell
# Azure Backup snapshot VM (Capa 2 rollback)
.\scripts\modules\sql2017-to-sql2022\16-pre-cutover-vm-snapshot.ps1 `
    -VmName "vm-sql2017" -VaultName "rsv-milink"
```

**Pre-cutover (T-1h)**:
```sql
-- En vm-sql2017:
:r .\scripts\modules\sql2017-to-sql2022\17-pre-cutover-checklist.sql
-- Output: si HEALTHY → seguir; si no → posponer
```

**Cutover (T+0)** — seguir el protocolo paso a paso de [`cutover-plan.md`](cutover-plan.md):

```sql
-- Pasos T+0 a T+5min, ejecutar manualmente con el script de referencia
:r .\scripts\modules\sql2017-to-sql2022\18-cutover-planned.sql
-- Este script tiene los pasos SYNC + wait + failover + MULTI_USER comentados;
-- ejecutarlos uno a uno, validando cada paso.
```

**Habilitar jobs T+5min**:
```sql
-- En vm-sql2022:
:r .\scripts\modules\sql2017-to-sql2022\19-enable-jobs-spainc.sql

-- En vm-sql2017:
:r .\scripts\modules\sql2017-to-sql2022\20-disable-jobs-northeu.sql
```

**Validación T+5min**:
```sql
-- En vm-sql2022:
:r .\scripts\modules\sql2017-to-sql2022\21-post-cutover-validate.sql
```

---

## 8. Fase 8 — Validación extendida (T+1h a T+72h)

Ejecutar las suites de [`post-migration-validation.md`](post-migration-validation.md):

```sql
-- T+1h
:r .\scripts\modules\sql2017-to-sql2022\21-post-cutover-validate.sql  -- Capas A,B,C

-- T+24h
:r .\scripts\modules\sql2017-to-sql2022\22-validate-oob-objects.sql   -- Capa E

-- T+72h
:r .\scripts\modules\sql2017-to-sql2022\23-validate-extended.sql      -- Capa F
```

**GO/NO-GO en T+30min, ratificación en T+72h**.

---

## 9. Fase 9 — Ejecutar estrategia post-cutover (T+72h+)

Según la decisión de [`post-cutover-strategies.md`](post-cutover-strategies.md):

### Si Estrategia A (Decommission)
```sql
-- En vm-sql2022 (primary):
:r .\scripts\modules\sql2017-to-sql2022\24-decommission-dag.sql
```
```powershell
# Apagar VM 2017 (NO eliminar todavía)
az vm deallocate -g rg-milink-vm -n vm-sql2017

# A T+7d, si todo OK, eliminar:
.\scripts\modules\sql2017-to-sql2022\cleanup-northeu.ps1 -VmName "vm-sql2017"
```

### Si Estrategia B (Upgrade in-place)
```powershell
.\scripts\modules\sql2017-to-sql2022\25-upgrade-northeu-to-2022.ps1 `
    -VmName "vm-sql2017" -SqlIso "<path-to-iso>"
```

Tras el upgrade:
```sql
-- En vm-sql2017 (ahora SQL 2022):
:r .\scripts\modules\sql2017-to-sql2022\26-reseed-after-upgrade.sql
-- Reseed manual desde SpainC + rejoin al DAG
```

### Si Estrategia C (Pivot a MI)
Empezar la fase MI usando el patrón MI Link del [módulo original del repo](../../) pero
con `SQL Server 2022` como origen, lo que habilita el failback nativo en MI Link.

### Si Estrategia D (UAT)
```sql
-- Sacar BD del AG_NorthEU, recovery, rename a UAT
:r .\scripts\modules\sql2017-to-sql2022\27-convert-to-uat.sql
```

---

## 10. Rollback (si algo va mal)

Si necesitas revertir, NO improvises: sigue [`rollback-plan.md`](rollback-plan.md).

Scripts auxiliares:

| Capa | Script |
|---|---|
| Capa 0 (pre-failover) | `28-rollback-cancel-cutover.sql` |
| Capa 3 (inmediato) | `29-rollback-immediate.sql` |
| Capa 1 (backup restore) | `30-rollback-from-backup.sql` |
| Capa 2 (VM snapshot) | `31-rollback-from-vm-snapshot.ps1` |
| Capa 4 (BACPAC) | `32-rollback-bacpac-export.ps1` |

---

## 11. Cleanup completo (post-cutover exitoso, T+30d)

Cuando ya no hace falta ningún rollback:

```powershell
.\scripts\modules\sql2017-to-sql2022\cleanup-spainc.ps1 `
    -KeepStorage  # mantener el SA con backups
```

Lo que NO eliminar nunca:
- Storage Account con los backups pre-cutover (mantener al menos 90 días).
- Snapshot Azure Backup del T-24h (mantener al menos 30 días).
- Logs y reportes del cutover.

---

## 12. Cheatsheet de comandos más usados

### Estado del DAG en una línea
```sql
SELECT ag.name, ar.replica_server_name, drs.synchronization_state_desc, drs.synchronization_health_desc, drs.log_send_queue_size, drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id;
```

### Conectividad VM ↔ VM
```powershell
Test-NetConnection -ComputerName <otra-vm> -Port 5022
```

### Verificación rápida pre/post cutover
```sql
SELECT @@SERVERNAME, DB_NAME(), (SELECT COUNT(*) FROM <tabla_principal>) AS row_count;
```

### Logs SQL Server tail
```sql
EXEC xp_readerrorlog 0, 1, NULL, NULL, NULL, NULL, N'DESC';
```

---

## Referencias

- Todos los documentos del módulo (10 archivos en `docs/modules/sql2017-northeu-to-sql2022-spainc/`)
- Todos los scripts del módulo (`scripts/modules/sql2017-to-sql2022/`)
- [Tutorial oficial MS: Use distributed AG to migrate from a standalone instance](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/distributed-availability-group-migrate-standalone-instance)
