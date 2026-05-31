# Resultados empíricos del drill de rollback

> Demo ejecutada el **2026-05-31** sobre `vm-sql2017` (SQL Server 2017 CU31 Enterprise) y `mi-link-demo-fraesp` (Azure SQL MI GP_Gen5 4 vCores)

## Estado inicial

```
DemoLink (DB)
├── dbo.DemoRows : 504 filas (originales + seed)
├── MI Link 'demo-link' : ACTIVO, SYNCHRONIZING HEALTHY
└── AG local 'MILinkAG' : ACTIVO
```

## Drill 1 — Backup nativo (Capa 1) end-to-end

### Setup
1. **T0**: Crear tabla `RollbackAudit` para tracking
2. **T0**: `INSERT 'PRE_CUTOVER_BACKUP'` → 1 evento
3. **T0**: `BACKUP DATABASE DemoLink TO DISK = 'C:\sqlbackups\DemoLink_FULL_xxx.bak' WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS=10`
4. **T0**: `BACKUP LOG DemoLink TO DISK = '...LOG_xxx.trn' WITH COPY_ONLY, COMPRESSION, CHECKSUM`

### Tamaño y tiempo
| Operación | Páginas | Tiempo | Throughput | Tamaño en disco |
|---|---|---|---|---|
| BACKUP DATABASE | 740 | 0.278s | 20.78 MB/s | 0.73 MB |
| BACKUP LOG | 340 | 0.020s | 132.62 MB/s | 0.29 MB |

> Extrapolando: una BD de **100 GB** tardaría ~80 minutos con compression (depende mucho de IO/CPU del host).
> Para el cliente real (asumiendo TBs), considerar **Backup compression** + striping multi-file + IO optimizado.

### Tráfico post-backup (simula gap T0 → T+rollback)
- INSERT 100 filas con `Origin='post-backup'`
- INSERT 1 evento `POST_BACKUP_TRAFFIC`

### Restore en BD nueva (no rompe el live)
- `RESTORE DATABASE DemoLink_RestoreTest FROM DISK = ... WITH NORECOVERY, MOVE..., REPLACE`
- `RESTORE LOG DemoLink_RestoreTest FROM DISK = ... WITH RECOVERY`

### Verificación de consistencia
| Métrica | Live DB | Restored DB | Esperado |
|---|---|---|---|
| Total `DemoRows` | 604 | **504** | 504 (estado T0) ✅ |
| Post-backup rows | 100 | **0** | 0 (perdido en rollback) ✅ |
| Audit events | 2 (PRE + POST) | **1** (solo PRE) | 1 ✅ |

**Resultado**: ✅ Capa 1 reproduce el estado exacto del backup. El gap (100 rows) corresponde al **RPO = tráfico entre backup y rollback**.

## Drill 2 — Azure Backup VM (Capa 2)

### Setup
```powershell
az backup vault create -g rg-sqlmilink-vm-fra -n rsv-sqlmilink-fra -l francecentral
az backup protection enable-for-vm -g rg-sqlmilink-vm-fra -v rsv-sqlmilink-fra --vm vm-sql2017 --policy-name DefaultPolicy
az backup protection backup-now -g rg-sqlmilink-vm-fra -v rsv-sqlmilink-fra \
    --container-name "IaasVMContainer;iaasvmcontainerv2;rg-sqlmilink-vm-fra;vm-sql2017" \
    --item-name "VM;iaasvmcontainerv2;rg-sqlmilink-vm-fra;vm-sql2017" \
    --backup-management-type AzureIaasVM \
    --retain-until 30-06-2026
```

### Job
- Job ID: `09d6da81-1f78-4449-be21-8b817571225d`
- Tipo: **CrashConsistent** por defecto en VM Linux/Windows; para **ApplicationConsistent** SQL es necesario instalar la VM Extension VMSnapshot (presente por defecto en imágenes Marketplace SQL).
- Tiempo típico: 10-20 min para una VM de 128 GB.

### Resultados empíricos del drill

| Fase | Duración | Resultado |
|---|---|---|
| `Take Snapshot` | ~9 min | ✅ Completed |
| Recovery point creado | T0+9min | ✅ `782143647972714` — **AppConsistent** |
| `Transfer data to vault` | 15-30 min adicionales | ⏳ Background (no bloquea restore) |
| Validate Backup | minutos | después de transfer |

**Hallazgo clave**: el recovery point está **disponible para restore en T+9min** desde que se lanza el job, mucho antes de que termine la transferencia al vault. La transferencia es necesaria para retención a largo plazo pero el snapshot local del disco ya es restorable.

**Listado de recovery points**:
```powershell
az backup recoverypoint list -g rg-sqlmilink-vm-fra -v rsv-sqlmilink-fra \
  -c "IaasVMContainer;iaasvmcontainerv2;rg-sqlmilink-vm-fra;vm-sql2017" \
  -i "VM;iaasvmcontainerv2;rg-sqlmilink-vm-fra;vm-sql2017" \
  --backup-management-type AzureIaasVM -o table

Name             Time                              Consistency
---------------  --------------------------------  -------------
782143647972714  2026-05-31T21:02:49.643997+00:00  AppConsistent
```

> **AppConsistent = VSS quiesció SQL Server**. El backup contiene un estado transaccional consistente, no requiere recovery al restaurar — es el modo ideal para SQL.

### Notas operativas relevantes
- **Soft-delete bloqueado** por policy MCAPS: enhanced-security-state no es desactivable. En limpieza hay que esperar 14 días post-delete.
- **Cross-region restore**: requiere `--backup-storage-redundancy GeoRedundant` al crear el vault (no es el default).

## Drill 3 — Capa 3 (Primary intacto)

> Esto **NO** se prueba destruyendo el primary porque rompería la demo. Se documenta la operativa.

### Procedimiento post-cutover
```sql
-- En SQL Server primary, justo después del cutover exitoso a MI:
ALTER DATABASE DemoLink SET READ_ONLY WITH ROLLBACK IMMEDIATE;
-- Esto previene escrituras accidentales mientras se evalúa el MI

-- Auditing para detectar conexiones inesperadas
CREATE SERVER AUDIT [Post_Cutover_Audit]
    TO FILE (FILEPATH = 'C:\sqlbackups\audit\', MAXSIZE = 100 MB)
    WITH (ON_FAILURE = CONTINUE);
ALTER SERVER AUDIT [Post_Cutover_Audit] WITH (STATE = ON);
CREATE DATABASE AUDIT SPECIFICATION [DemoLink_Connections]
    FOR SERVER AUDIT [Post_Cutover_Audit]
    ADD (DATABASE_PRINCIPAL_CHANGE_GROUP),
    ADD (SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP)
WITH (STATE = ON);
```

### Procedimiento de rollback
```sql
-- 1. App stops
-- 2. En SQL Server: 
ALTER DATABASE DemoLink SET READ_WRITE;

-- 3. (Opcional) Bloquear MI para evitar dual-write 
-- En MI:
ALTER DATABASE DemoLink SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;

-- 4. App restart con connection string → vm-sql2017
-- 5. Validación
```

**Tiempo estimado**: 5-10 min (en su mayor parte cambio de connection string en config + restart app)

**Pérdida**: 0 si la app estaba en read-only durante validación; sino los writes a MI

## Drill 4 — Capa 4 (BACPAC late rollback)

> Sólo se documenta la operativa porque requeriría export + import largo y no aporta más que el procedimiento.

```powershell
# 1. Freeze MI
sqlcmd -S "mi-link-demo-fraesp.public.332838295123.database.windows.net,3342" -d DemoLink -G `
    -Q "ALTER DATABASE DemoLink SET READ_ONLY"

# 2. Export bacpac (en build agent con sqlpackage)
sqlpackage.exe /a:Export `
    /tsn:"mi-link-demo-fraesp.public.332838295123.database.windows.net,3342" `
    /tu:admin@MngEnvMCAP184496.onmicrosoft.com `
    /tdn:DemoLink `
    /ua:true `
    /tf:C:\rollback\DemoLink_$(Get-Date -Format yyyyMMdd_HHmm).bacpac

# 3. Import en SQL Server primary
sqlpackage.exe /a:Import `
    /sf:C:\rollback\DemoLink_xxx.bacpac `
    /tsn:vm-sql2017 /tu:sa /tp:'<sa-pwd>' `
    /tdn:DemoLink_recovered

# 4. Swap
sqlcmd -S vm-sql2017 -E -Q "
    DROP DATABASE DemoLink;
    ALTER DATABASE DemoLink_recovered MODIFY NAME = DemoLink;
    ALTER DATABASE DemoLink SET READ_WRITE;"
```

**Tiempo estimado**: ~1h por cada 100 GB (export) + ~1h (import) + 10 min swap. **Total para 100 GB: ~2h 10min downtime**.

**Pérdida**: writes a MI durante el export (mitigable con READ_ONLY).

## Gotchas encontradas en el drill

### 1. ⚠️ Policy MCAPS bloquea `allowSharedKeyAccess`
- **Síntoma**: `BACKUP TO URL` con SAS user-delegation falla con `Operating system error 50 (The request is not supported.)`
- **Causa**: User-delegation SAS no es compatible con SQL Server 2017 BACKUP TO URL en todas las configuraciones; SQL Server espera account-key SAS y la policy lo bloquea
- **Workaround prod**: 
  - (a) Pedir exempt de policy para el storage account de backups
  - (b) **BACKUP TO DISK + AzCopy** (con managed identity del SQL Server / VM) — funciona siempre
  - (c) Storage account con private endpoint + AAD-based credential (SQL 2022 only)

### 2. ⚠️ Soft-delete obligatorio en Recovery Services Vault
- **Síntoma**: `BMSUserErrorDisablingSoftDeleteStateNotAllowed`
- **Causa**: Policy MCAPS fuerza soft-delete enabled
- **Impacto**: 14 días de retención forzada tras eliminar items. Coste sigue acumulando.

### 3. ✅ COPY_ONLY no rompe el Link
- BACKUP `WITH COPY_ONLY` no avanza el `differential_base_lsn` ni rompe la cadena de logs del AG/DAG
- Es la manera correcta de tomar el snapshot pre-cutover sin afectar al MI Link

### 4. ✅ Restore a BD nueva permite drill no-disruptivo
- `RESTORE DATABASE DemoLink_RestoreTest FROM DISK = ... WITH MOVE..., REPLACE`
- Permite verificar el backup sin tocar la BD productiva

### 5. ⚠️ El gap del Log Backup es CRÍTICO
- Si entre el LOG backup y el cutover hay más transacciones, esas se perderán en rollback
- Mitigación: hacer un **tail-log backup** justo después de parar la app:
  ```sql
  BACKUP LOG DemoLink TO DISK = '...' WITH NO_TRUNCATE, NORECOVERY;
  ```

## Conclusiones para el cliente

### ✅ Lo que funciona
- **Backup nativo .bak (COPY_ONLY)** → restore en cualquier momento, granular, rápido (~20 MB/s para esta VM)
- **Azure Backup VM** → snapshot disk-level + VSS para SQL → restore a punto exacto en horas
- **Mantener primary intacto post-cutover** → rollback inmediato gratis (sólo cuesta dejar la VM corriendo X días)
- **Rollback inmediato (Capa 3)** → 5-10 min, 0 pérdida si app fue read-only en validación

### ⚠️ Limitaciones SQL 2017 inherentes
- MI Link es one-way: tras el failover el link se rompe (no se puede usar para failback)
- Para rollback tardío con cambios en MI: bacpac (lento) o replicación transaccional (compleja)
- Mantener compatibility level 140 en MI durante toda la fase de validación

### 📋 Recomendaciones para producción
1. **Doble seguro de backup**: Capa 1 (.bak) **+** Capa 2 (Azure Backup VM) — son independientes
2. **Window de "limbo" controlado**: mantener primary intacto 7-14 días + monitoring activo
3. **Drill obligatorio**: ejecutar este mismo plan en un entorno de stage antes de la migración real
4. **Comms y rollback decision tree** definidos antes del cutover (quién decide, en cuánto tiempo)
5. **NUNCA upgrade compat level en MI hasta confirmar punto de no retorno**
