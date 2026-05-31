# Plan de migración con botón del pánico (SQL Server 2017 → SQL MI)

> **Contexto del cliente**: SQL Server 2017 Enterprise CU31-GDR (14.0.3515.1) → Azure SQL Managed Instance (cross-region: West Europe → Spain Central).

## Resumen ejecutivo

| | SQL Server 2017 | SQL Server 2022 |
|---|---|---|
| MI Link direccional | ⚠️ **One-way** | ✅ Bidireccional con fail-back online |
| Failover sin pérdida | ✅ Sí (planned) | ✅ Sí |
| Tras failover el link… | **Se rompe y se elimina** | Se mantiene activo (opcional) |
| Fail-back via Link | ❌ **No** | ✅ Sí, online |
| Recovery oficial | bacpac / repl. transaccional / backup | Restore directo MI→SQL2022 |

> ⚠️ **Conclusión**: para SQL 2017 el rollback **NO** puede depender del Link. Necesitamos un mecanismo de defensa en profundidad construido fuera del Link.

---

## Arquitectura de rollback (defense in depth)

```
                 ┌─────────────────────────────────────────┐
                 │     Antes del cutover (T-1h)            │
                 │                                          │
                 │  Capa 1 → Backup .bak full+log → Blob   │
                 │  Capa 2 → Azure Backup snapshot VM      │
                 │  Capa 3 → Primary SQL Server INTACTO    │
                 │           (no decommission)              │
                 └─────────────────────────────────────────┘
                                  │
                                  ▼
                 ┌─────────────────────────────────────────┐
                 │           CUTOVER (T0)                   │
                 │  1. Stop workload en SQL primario        │
                 │  2. Esperar LSN sync (ambos iguales)     │
                 │  3. Planned failover → MI                │
                 │  4. App repoint → MI FQDN                │
                 │  5. Validation suite (smoke + perf)      │
                 └─────────────────────────────────────────┘
                                  │
                  ┌───────────────┴───────────────┐
                  ▼                               ▼
        ✅ Validación OK                  ❌ Algo va mal
        Continuar en MI                  Activar rollback
                                                  │
                              ┌───────────────────┴───────────────┐
                              ▼                                    ▼
                   Capa 3 (T0 + 0-24h)              Capa 4 (T0 + días/semanas)
                   "Rollback inmediato"             "Rollback tardío"
                   App → SQL primary                MI → bacpac/SAS → SQL primary
                   Tiempo: minutos                  Tiempo: horas
                   Pérdida: datos en MI             Pérdida: gap durante export
```

---

## Capa 1 — Backup nativo SQL Server (.bak) → Blob

Backup `COPY_ONLY` full + log de la BD justo antes del cutover, almacenado en Azure Blob Storage.

**Ventajas**: rápido, granular (a nivel DB), portable, restore en cualquier SQL Server 2017+.

**Requisitos**:
- Credential SQL con `SHARED ACCESS SIGNATURE` apuntando al container
- SQL Server 2017 con CU17+ acepta user-delegation SAS
- Outbound 443 desde la VM al blob (storage account público o private endpoint)

**Script**: `scripts/05-pre-cutover-backup.sql`

**Restore (rollback)**:
```sql
RESTORE DATABASE DemoLink
  FROM URL = 'https://stsqlmilinkbackup.blob.core.windows.net/sqlbackups/DemoLink_pre_cutover.bak'
  WITH REPLACE, NORECOVERY;
RESTORE LOG DemoLink
  FROM URL = 'https://stsqlmilinkbackup.blob.core.windows.net/sqlbackups/DemoLink_pre_cutover.trn'
  WITH RECOVERY;
```

---

## Capa 2 — Azure Backup (Recovery Services Vault) sobre la VM

Snapshot **application-consistent** de la VM completa (disk + SQL frozen via VSS writer).

**Ventajas**: si la VM entera se corrompe (no sólo la BD), restauras todo el SO; el VSS writer congela SQL Server para evitar inconsistencias.

**Tiempo de restore**: de minutos (mismo disk) a 1-2 horas (cross-region).

**Script**: `scripts/06-enable-azure-backup.ps1`

> ℹ️ **Tip**: programa el backup VM con una **policy ad-hoc** justo antes del cutover y un **on-demand snapshot** disparado por el runbook (no esperes a la ventana programada).

---

## Capa 3 — Mantener el primary SQL Server INTACTO post-cutover

La capa más simple y la más potente. Tras el cutover:

1. El SQL Server primario **sigue existiendo y operativo** (sólo está sin tráfico).
2. La aplicación está apuntando al MI.
3. Si en las primeras horas/días algo va mal → **repoint del connection string al SQL primario** y recuperas el estado **exacto** del T0.

**Window recomendado**: 7-14 días con el primary "frozen" y monitorizado.

**Pérdida potencial**: cualquier dato escrito en MI entre T0 y el rollback.
- Si la aplicación está en modo "lectura mientras se valida" → 0 pérdida
- Si hay writes durante validación → necesitas Capa 4 para reconciliar

**Cómo lo activamos**:
1. **No tirar la VM**. No `az vm delete`, ni siquiera `deallocate` agresivo.
2. Tras el cutover, en la VM SQL: dejar la BD en **READ_ONLY** o renombrar para evitar conexiones accidentales:
   ```sql
   ALTER DATABASE DemoLink SET READ_ONLY;
   -- O para máxima seguridad:
   ALTER DATABASE DemoLink MODIFY NAME = DemoLink_PRE_CUTOVER;
   ```
3. Activar Auditing en SQL Server para detectar cualquier conexión inesperada.

**Cómo se activa el rollback**:
1. Cambiar `READ_ONLY` → `READ_WRITE` (o renombrar de vuelta).
2. Cambiar el connection string de la app al SQL primary.
3. Validar consistencia.

---

## Capa 4 — Rollback tardío (días/semanas después)

Cuando ya hay datos críticos escritos en MI que no puedes perder.

### Opción A — BACPAC export desde MI

1. Generar bacpac desde Azure portal (SQL MI → Export) o `sqlpackage.exe /a:Export`
2. Import en SQL Server primario:
   ```cmd
   sqlpackage.exe /a:Import /sf:DemoLink.bacpac /tsn:vm-sql2017 /tdn:DemoLink_recovered /tu:sa /tp:...
   ```
3. **Cutover de vuelta** controlado: stop MI writes → último export incremental → repoint app.

**Pros**: oficial, robusto, soporta schema + datos.
**Contras**: tiempo proporcional al tamaño (~1h por cada 100 GB), no captura cambios durante el export (ventana de read-only).

### Opción B — Replicación transaccional inversa (MI → SQL Server)

MI puede ser publisher en transactional replication; SQL Server es subscriber.

Setup más complejo pero permite sync continuo sin downtime.

📖 Referencia: [Replication with managed instance](https://learn.microsoft.com/azure/azure-sql/managed-instance/replication-transactional-overview)

### Opción C — Tabla por tabla (SSIS / ADF / SqlBulkCopy)

Para escenarios muy custom donde quieres seleccionar qué tablas restaurar.

---

## Compatibility level — el detalle crítico

| | SQL 2017 | MI tras cutover |
|---|---|---|
| Default compat level | 140 | Hereda 140 desde origen |
| Máximo soportado en MI | – | 160 (SQL 2022) |
| Riesgo upgrade MI a 150+ | – | ⚠️ **Imposible rollback** a 2017 |

### Regla de oro

> **Mantén la BD en MI en compat level 140 hasta que estés 100% comprometido con el cutover.**
> Cualquier upgrade a 150 o superior rompe la portabilidad de vuelta a SQL 2017.

```sql
-- Verificar compat level en MI tras el cutover
SELECT name, compatibility_level FROM sys.databases WHERE name = 'DemoLink';
-- Debe devolver 140

-- Si está en >140 y necesitas rollback:
ALTER DATABASE DemoLink SET COMPATIBILITY_LEVEL = 140;
-- (esto sólo cambia el modo del query optimizer, no convierte features de 2019+)
```

### Features bloqueantes

Si tras el cutover en MI activaste features que **no existen** en SQL 2017, el rollback bacpac fallará:

| Feature | Versión introducida | Bloquea rollback a 2017 |
|---|---|---|
| Accelerated DB Recovery (ADR) | 2019 (compat 150) | ⚠️ Si activado |
| Edge constraints | 2019 | ⚠️ |
| UTF-8 collations | 2019 | ⚠️ |
| Ledger tables | 2022 | ⚠️ |
| GENERATE_SERIES, DATE_BUCKET | 2022 | ⚠️ |
| Always Encrypted con enclaves | 2019+ | ⚠️ |
| External JSON support nuevo | 2022 | ⚠️ |

**Validación obligatoria** post-cutover (pero antes del "punto de no retorno"):

```sql
-- Detectar uso de features incompatibles con 2017
SELECT * FROM sys.dm_exec_query_optimizer_info WHERE counter LIKE '%2019%';
-- Y revisar el query store si está activo
```

---

## Runbook ejecutivo

| Fase | Tiempo estimado | Acción | Owner |
|---|---|---|---|
| **T-7d** | – | Setup MI Link, validar SYNCHRONIZED | DBA |
| **T-3d** | – | Validation suite read-only en MI | App team |
| **T-1d** | – | Comms a stakeholders, congelar releases | PM |
| **T-2h** | 5 min | Crear Azure Backup snapshot on-demand de la VM | DBA |
| **T-1h** | 10-30 min | `BACKUP DATABASE ... TO URL` (full COPY_ONLY) | DBA |
| **T-30min** | 1 min | `BACKUP LOG ... TO URL` | DBA |
| **T-15min** | 2 min | Cambiar Link de async a **sync** (no obligatorio para 2017 pero recomendado) | DBA |
| **T-5min** | 5 min | Stop workload en app primary (cut connections) | App team |
| **T-1min** | 1 min | Verificar LSNs match (SQL=MI) | DBA |
| **T0** | 1-2 min | Planned failover en SSMS Wizard | DBA |
| **T0+1min** | – | Wizard rompe el Link (esperado en SQL 2017) | – |
| **T0+2min** | 5 min | Verificar BD en MI online R/W, smoke test queries | DBA |
| **T0+5min** | 1 min | App connection string → MI FQDN | App team |
| **T0+10min** | – | **PUNTO DE DECISIÓN**: validation suite full | App team |
| | | ✅ OK → continuar | |
| | | ❌ FAIL → **ROLLBACK Capa 3** | |
| **T0+2h** | – | Set BD primario READ_ONLY (capa 3 activada) | DBA |
| **T0+24h** | – | Health check, monitoring on MI | Ops |
| **T0+7d** | – | Decommission window: si todo OK, marcar para eliminar VM primary | Mgmt |

---

## Procedimiento de rollback inmediato (Capa 3)

> Aplica si la decisión de rollback ocurre en las **primeras horas** post-cutover y los datos escritos en MI son **descartables o reproducibles** desde el negocio.

```powershell
# 1. App: cambiar connection string de vuelta al SQL Server primario
# (esto depende de tu sistema: App Service config, Key Vault, k8s secret, etc.)

# 2. En SQL Server primary, asegurar BD escribible
sqlcmd -S vm-sql2017 -E -Q "ALTER DATABASE DemoLink SET READ_WRITE;"

# 3. (Opcional) Marcar BD en MI como out-of-service para evitar dual-write
# En MI:
ALTER DATABASE DemoLink SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;

# 4. Validar app contra primary
# 5. Lessons learned
```

---

## Procedimiento de rollback tardío (Capa 4)

> Aplica si han pasado **días** desde el cutover y hay datos críticos en MI que necesitas preservar.

### Setup pre-export

```sql
-- En MI: poner la BD en read-only para garantizar snapshot consistente
ALTER DATABASE DemoLink SET READ_ONLY;
```

### Export bacpac

```powershell
# Desde la VM o un build agent con sqlpackage instalado
sqlpackage.exe `
  /a:Export `
  /tsn:"mi-link-demo-fraesp.public.332838295123.database.windows.net,3342" `
  /tu:admin@MngEnvMCAP184496.onmicrosoft.com `
  /tdn:DemoLink `
  /tf:C:\rollback\DemoLink_$(Get-Date -Format yyyyMMdd_HHmm).bacpac `
  /ua:true   # Active Directory Integrated
```

### Import en SQL Server primary

```powershell
sqlpackage.exe `
  /a:Import `
  /sf:C:\rollback\DemoLink_xxx.bacpac `
  /tsn:vm-sql2017 `
  /tu:sa /tp:'<sa-pwd>' `
  /tdn:DemoLink_restored
```

### Switch over

```sql
-- En SQL Server: descartar la copia "frozen" y promover la restaurada
DROP DATABASE DemoLink;   -- la copia frozen pre-cutover
ALTER DATABASE DemoLink_restored MODIFY NAME = DemoLink;
ALTER DATABASE DemoLink SET READ_WRITE;
```

---

## Testing / drill

| Test | Frecuencia recomendada | Script |
|---|---|---|
| Backup restore from blob | Antes de cada cutover | `08-test-restore.ps1` |
| Failover dry-run (forced en LAB) | Cada quarter | `09-test-failover-dryrun.sh` |
| Full rollback drill (cutover + rollback) | Una vez antes de la migración real | `10-full-drill.ps1` |

---

## Decision matrix — ¿qué rollback usar?

```
┌─────────────────────────────────────────────────────────────┐
│ ¿Cuándo se detectó el problema?                              │
└────────────────────────┬────────────────────────────────────┘
                         │
       ┌─────────────────┴─────────────────┐
       │                                    │
  < 24 horas                          > 24 horas
       │                                    │
       ▼                                    ▼
  ¿La app escribió                   Capa 4
  datos a MI?                        (bacpac/repl)
       │                              tiempo: horas
   ┌───┴───┐
   No      Sí
   │       │
   ▼       ▼
Capa 3   ¿Esos datos son
inmed.   reconstruibles?
         │
     ┌───┴───┐
     Sí      No
     │       │
     ▼       ▼
   Capa 3   Capa 4
   inmed.   (bacpac)
```

---

## Referencias oficiales

- [Migrate with the link](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-migrate)
- [One-way failover (SQL 2016-2019)](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-disaster-recovery#one-way-failover-sql-server-2016---2022)
- [SQL Server backup to URL](https://learn.microsoft.com/sql/relational-databases/backup-restore/sql-server-backup-to-url)
- [ALTER DATABASE compatibility level](https://learn.microsoft.com/sql/t-sql/statements/alter-database-transact-sql-compatibility-level)
- [Azure Backup for SQL Server in Azure VM](https://learn.microsoft.com/azure/backup/backup-azure-sql-database)
