# Plan de rollback: SQL 2017 NorthEU → SQL 2022 SpainC

Plan multi-capa para revertir el cutover si algo va mal. Diseñado para el caso más
estricto: **cross-version forward-only** (SQL 2017 no puede aplicar log de SQL 2022, por
tanto **no hay failback nativo via DAG**).

> 📘 Inspirado en el plan de [`../../migration-rollback-plan.md`](../../migration-rollback-plan.md)
> del módulo MI Link de este repo (que enfrenta el mismo problema de unidireccionalidad).
> Adaptado al caso 2017→2022 cross-region.

---

## 1. Filosofía: defense in depth

El cutover puede fallar en distintos momentos, con distinta cantidad de "daño" acumulado.
Cada capa de rollback cubre una **ventana temporal específica**:

```
              cutover         T+15min    T+1h        T+4h       T+24h    T+7d
              │                │          │           │           │        │
              ▼                ▼          ▼           ▼           ▼        ▼
   [Capa 0] PRE-FAILOVER   ─────►
   (cancelar cutover, BD destino no recibió writes aún)

   [Capa 3] INMEDIATO          ─────────► (AG_NorthEU intacto, BD destino mínimos writes)

   [Capa 1] BAK + LOG                          ──────────────►  (restore de backup pre-cutover)

   [Capa 2] VM SNAPSHOT                                 ──────────────►  (restore VM completa)

   [Capa 4] BACPAC EXPORT                                              ──────────►  (downgrade desde 2022)
```

| Capa | Ventana | RTO | RPO | Coste pérdida |
|---|---|---|---|---|
| 0 — Pre-failover | T-0 a T+4.5min | ~3 min | **0** | Nada (cancelas el cutover) |
| 3 — Inmediato | T+4.5min a T+1h | ~10-20 min | Tx escritas a SpainC desde failover | Esas tx (manualmente recuperables vía Query Store) |
| 1 — BAK + LOG | T+1h a T+7d | ~30-60 min | Tx desde último backup pre-cutover | Todas las tx desde el T-24h backup |
| 2 — VM Snapshot | T+1h a T+30d | ~60-120 min | Tx desde último snapshot VM | Todas las tx desde el T-24h snapshot |
| 4 — BACPAC export | T+24h en adelante | **horas a días** | Tx desde el momento del BACPAC export | Gap durante el export (hasta horas) |

**Regla operativa**: elegir la capa de **menor RPO posible** según la ventana temporal y la
tolerancia al RTO.

---

## 2. Por qué cross-version cambia el plan

A diferencia del módulo MI Link de este repo, aquí **no podemos usar reverse migration
nativa** porque:

- SQL Server 2017 **no acepta** log de SQL Server 2022 (forward-only compatibility).
- El AG_NorthEU local quedó en estado `RESOLVING / NOT SYNCHRONIZING` post-failover, no
  recibe writes nuevos del DAG.
- No existe MI Link bidireccional (el target no es MI, es otra VM SQL).

**Implicaciones**:
- La Capa 4 (downgrade) requiere **export/import lógico** (BACPAC), que no preserva todo:
  - Sin estadísticas, sin índices recompilados, sin Query Store history.
  - Slow para BDs grandes (horas).
- La Capa 3 (rollback inmediato) sigue siendo viable **porque el AG_NorthEU está intacto
  con el último estado pre-cutover**.

---

## 3. Capa 0 — Cancelar pre-failover (T-0 a T+4.5min)

### Cuándo aplica
Mientras estás ejecutando los pasos del cutover (drain → SYNC → wait SYNCHRONIZED → ...)
**pero antes** de ejecutar `ALTER AVAILABILITY GROUP ... FAILOVER`. La BD nueva todavía es
secundaria.

### Cómo
**Simplemente no ejecutar el failover**. Pasos para revertir el estado:

```sql
-- En vm-sql2017 (sigue siendo primary):
-- 1. Devolver DAG a ASYNC (estado original)
ALTER AVAILABILITY GROUP [DAG_Migrate]
MODIFY AVAILABILITY GROUP ON 'AG_SpainC' WITH (
    AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT
);

ALTER AVAILABILITY GROUP [DAG_Migrate]
MODIFY AVAILABILITY GROUP ON 'AG_NorthEU' WITH (
    AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT
);

-- 2. Sacar la BD legacy de RESTRICTED_USER
ALTER DATABASE [AppDb] SET MULTI_USER;

-- 3. Reactivar app (revertir feature flag / read-only / stop)
```

### RPO/RTO
- **RPO = 0**: ninguna tx se ha perdido (no llegaron a ser escritas en ningún sitio).
- **RTO = 3 min**: tiempo de revertir el modo del DAG y reactivar app.

### Validación
```sql
-- Confirmar DAG sano:
SELECT name, synchronization_health_desc
FROM sys.availability_groups;
-- Debe ser HEALTHY o PARTIALLY_HEALTHY (lo segundo es OK en ASYNC).
```

---

## 4. Capa 3 — Rollback inmediato (T+4.5min a T+1h)

### Cuándo aplica
Después del failover (la BD nueva en SpainC ya recibió algunos writes), pero la **ventana
temporal es pequeña** (minutos). El AG_NorthEU local sigue arriba con la BD en estado
pre-cutover.

### Pre-requisito
- AG_NorthEU **no se ha tocado** desde el cutover.
- BD legacy en NorthEU está en estado `RESTORING` / `RESOLVING` / `RECOVERY_PENDING` (esto
  es esperado post-cutover).

### Pasos

```sql
-- 1. En SpainC, congelar la BD para evitar split-brain mientras se rollback.
-- En vm-sql2022:
ALTER DATABASE [AppDb] SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;
ALTER DATABASE [AppDb] SET READ_ONLY;
```

```sql
-- 2. En SpainC, capturar las tx escritas desde el failover (Query Store, Audit, o log).
-- Esto es para la potencial recuperacion manual de esas tx.
-- Query Store (si esta habilitado):
USE [AppDb];
SELECT
    qsq.query_id,
    qst.query_sql_text,
    qsrs.last_execution_time,
    qsrs.count_executions
FROM sys.query_store_query qsq
JOIN sys.query_store_query_text qst ON qst.query_text_id = qsq.query_text_id
JOIN sys.query_store_runtime_stats qsrs ON qsrs.plan_id IN (
    SELECT plan_id FROM sys.query_store_plan WHERE query_id = qsq.query_id
)
WHERE qsrs.last_execution_time > '<timestamp del failover>'
ORDER BY qsrs.last_execution_time DESC;
```

```sql
-- 3. En vm-sql2017, sacar la BD del AG_NorthEU para devolverla a estado normal.
ALTER AVAILABILITY GROUP [AG_NorthEU]
REMOVE DATABASE [AppDb];
```

```sql
-- 4. RECOVERY de la BD legacy (vuelve al estado pre-cutover).
RESTORE DATABASE [AppDb] WITH RECOVERY;
```

```sql
-- 5. Verificar que la BD legacy esta online y al dia pre-cutover.
SELECT state_desc, recovery_model_desc FROM sys.databases WHERE name = 'AppDb';
-- state_desc=ONLINE, recovery_model_desc=FULL

-- Validacion funcional: ultima tx en la tabla principal
SELECT MAX(timestamp) FROM <tabla_de_auditoria>;
-- Comparar con el timestamp del backup pre-cutover (T-24h).
-- Debe ser muy reciente (segundos antes del cutover, si la app dejo de escribir en T+0).
```

```powershell
# 6. App repoint de vuelta a NorthEU
# (Reactivar la config anterior, o feature flag flip):
flag "active_db" = "northeu"
# O reapuntar DNS / connection string al FQDN del 2017.
```

### RPO / RTO
- **RPO**: las tx escritas en SpainC entre T+failover y T+rollback. Típicamente
  segundos-minutos de tx.
- **RTO**: ~10-20 min (5 min de rollback + 5-15 min de validación).

### Recuperar las tx perdidas (opcional, si son críticas)
Si las tx escritas en SpainC durante la ventana son críticas (ej. pagos), recuperarlas
manualmente:

1. **Si están en Query Store**: extraer el SQL y re-aplicarlo a NorthEU.
2. **Si están en transaction log de SpainC**: usar
   [`fn_dblog`](https://learn.microsoft.com/sql/relational-databases/system-functions/sys-fn-dblog-transact-sql) (no oficial pero útil) para extraer los
   cambios.
3. **Si la app tiene log de aplicación**: extraer las requests fallidas y reintentarlas.

```sql
-- Ejemplo de extraccion via fn_dblog (en SpainC, sobre la BD original):
USE [AppDb_capa3_snapshot]; -- restore antes de modificarla
SELECT [Current LSN], Operation, [Page ID], AllocUnitName, [Transaction ID], [Begin Time]
FROM fn_dblog(NULL, NULL)
WHERE Operation IN ('LOP_INSERT_ROWS', 'LOP_MODIFY_ROW', 'LOP_DELETE_ROWS')
  AND [Begin Time] > '<failover timestamp>'
ORDER BY [Current LSN];
```

⚠️ Esto requiere skill avanzada. **Documentar la pérdida** si los volúmenes son bajos
suele ser preferible.

---

## 5. Capa 1 — Restore desde backup en Blob (T+1h a T+7d)

### Cuándo aplica
- AG_NorthEU ya fue tocado/decommissionado y no puedes volver vía Capa 3.
- La ventana es de horas o días post-cutover (el AG_NorthEU puede haber sido reciclado).
- Necesitas restaurar el estado a **antes del cutover**.

### Pre-requisito
- Backup full + log pre-cutover existe en Blob (creado en T-24h, ver [`cutover-plan.md`](cutover-plan.md) §T-24h).
- Storage Account accesible.

### Pasos

```sql
-- En cualquier VM SQL Server 2017 (puede ser vm-sql2017 si sigue arriba, o una nueva):

-- 1. Restore full del backup pre-cutover
RESTORE DATABASE [AppDb]
FROM URL = 'https://<sa>.blob.core.windows.net/cutover-backups/AppDb_full_T-24h.bak'
WITH NORECOVERY,
     MOVE 'AppDb_Data' TO 'D:\Data\AppDb_Data.mdf',
     MOVE 'AppDb_Log' TO 'L:\Log\AppDb_Log.ldf';

-- 2. Restore log del backup pre-cutover
RESTORE LOG [AppDb]
FROM URL = 'https://<sa>.blob.core.windows.net/cutover-backups/AppDb_log_T-24h.trn'
WITH NORECOVERY;

-- 3. Recovery final
RESTORE DATABASE [AppDb] WITH RECOVERY;
```

```powershell
# 4. App repoint al servidor donde se restauro
```

### RPO / RTO
- **RPO**: tx desde el último log backup pre-cutover (T-24h en el plan estándar). Si has
  hecho log backups intermedios, RPO baja al intervalo del último.
- **RTO**: ~30-60 min para BDs medianas. Para BDs > 1 TB, varias horas.

### Mitigación del RPO grande
Hacer **log backups frecuentes incluso durante el cutover**:
- T-1h: log backup
- T-30min: log backup
- T-5min: log backup
- T+0 cutover

Esto baja RPO de "24h" a "minutos pre-cutover".

> ⚠️ **No hacer log backup durante el cutover mismo** porque podría interferir con el AG.
> Hacerlo justo antes del T+0.

---

## 6. Capa 2 — Restore desde Azure Backup VM snapshot (T+1h a T+30d)

### Cuándo aplica
- La VM `vm-sql2017` ya no existe o está dañada (no podemos hacer Capa 3 ni Capa 1
  directamente sobre ella).
- Tenemos un snapshot Azure Backup app-consistent tomado en T-24h.
- Aceptamos restaurar la **VM entera** (incluyendo SO + SQL Server + BD).

### Pre-requisito
- Recovery Services Vault con el snapshot del T-24h.
- Permisos para restaurar VMs en el RG destino.

### Pasos

```powershell
# 1. Listar recovery points disponibles
$vault = Get-AzRecoveryServicesVault -Name "rsv-milink"
Set-AzRecoveryServicesVaultContext -Vault $vault
$container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName "vm-sql2017"
$bkpItem = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM
$rp = Get-AzRecoveryServicesBackupRecoveryPoint -Item $bkpItem `
        -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date)

# Mostrar:
$rp | Format-Table RecoveryPointId, RecoveryPointTime, RecoveryPointType

# 2. Restore como nueva VM (NO sobre la original)
$restoreJob = Restore-AzRecoveryServicesBackupItem `
    -RecoveryPoint $rp[0] `
    -StorageAccountName "stmilinkrestore" `
    -StorageAccountResourceGroupName "rg-milink-vm" `
    -TargetResourceGroupName "rg-milink-vm-restored"

# 3. Esperar a que termine
Wait-AzRecoveryServicesBackupJob -Job $restoreJob -Timeout 7200

# 4. Conectar a la nueva VM y validar que SQL Server arranca
```

```sql
-- 5. En la VM restaurada, sacar la BD legacy del AG (estaba en estado RESTORING/RESOLVING).
ALTER AVAILABILITY GROUP [AG_NorthEU] REMOVE DATABASE [AppDb];
RESTORE DATABASE [AppDb] WITH RECOVERY;
ALTER DATABASE [AppDb] SET MULTI_USER;
```

```powershell
# 6. Crear DNS record / endpoint para que la app pueda apuntar a la nueva VM
# 7. App repoint
```

### RPO / RTO
- **RPO**: tx desde el snapshot (T-24h en el plan estándar).
- **RTO**: ~60-120 min (depende del tamaño de los discos y de la cola de Azure Backup).

### Cuándo usarla vs Capa 1
- **Capa 1** es más rápida si tienes los .bak en Blob y una VM disponible donde restaurar.
- **Capa 2** es necesaria si tu VM original está dañada o eliminada, o si necesitas
  recuperar también jobs / configs / certs locales que estaban fuera de la BD.

---

## 7. Capa 4 — BACPAC export desde SpainC (T+24h en adelante)

### Cuándo aplica
- Pasaron días o semanas y SpainC acumuló muchas tx que no quieres perder.
- Quieres "volver" a SQL Server 2017 (o llevar los datos actuales a otro 2017).
- **No** puedes usar `RESTORE` directo porque el log/data files son de versión 2022 (no
  abren en 2017).

### Cómo funciona
**BACPAC** es un export lógico (`schema` + `data`) que se puede importar en cualquier SQL
Server con compatibility level compatible. Permite "downgrade" porque no transmite formato
físico de páginas, sólo los datos.

### Pre-requisito
- La BD en SpainC tiene `compatibility_level <= 140` (lo del 2017). Si la subiste a 160,
  necesitas bajarla **temporalmente** para el export.
- Si usa features de 2022 (ej. ledger, MS-Test, etc.) que no existen en 2017, **el export
  fallará** o requerirá refactor.

### Pasos

```powershell
# 1. Verificar compat level
sqlcmd -S vm-sql2022 -Q "SELECT name, compatibility_level FROM sys.databases WHERE name='AppDb'"

# 2. Export BACPAC con SqlPackage
sqlpackage /Action:Export `
  /SourceServerName:vm-sql2022.spaincentral.cloudapp.azure.com `
  /SourceDatabaseName:AppDb `
  /SourceUser:<sa> /SourcePassword:<pwd> `
  /TargetFile:"C:\rollback\AppDb_T+7d.bacpac" `
  /OverwriteFiles:True

# 3. Subir a Blob
azcopy copy "C:\rollback\AppDb_T+7d.bacpac" `
  "https://<sa>.blob.core.windows.net/rollback/AppDb_T+7d.bacpac" `
  --recursive
```

```powershell
# 4. En una VM con SQL Server 2017 (puede ser una nueva), import del BACPAC
sqlpackage /Action:Import `
  /SourceFile:"C:\rollback\AppDb_T+7d.bacpac" `
  /TargetServerName:vm-sql2017-new.northeurope.cloudapp.azure.com `
  /TargetDatabaseName:AppDb_recovered `
  /TargetUser:<sa> /TargetPassword:<pwd>
```

```sql
-- 5. Renombrar o validar antes de exponer a la app
ALTER DATABASE [AppDb_recovered] MODIFY NAME = [AppDb];
```

### RPO / RTO
- **RPO**: tx desde el momento del export. **Si la app sigue escribiendo en SpainC durante
  el export, esas tx se pierden** (el BACPAC es un snapshot puntual).
- **RTO**: **horas a días** para BDs medianas/grandes. Es un proceso lento.

### Mitigación
Si el RTO debe ser bajo, hacer el export con la BD en SpainC **read-only**:
```sql
ALTER DATABASE [AppDb] SET READ_ONLY;
-- Export BACPAC ...
ALTER DATABASE [AppDb] SET READ_WRITE;
```
Esto introduce downtime del lado destino mientras dura el export.

### Limitaciones
- **No preserva**: estadísticas, índices recompilados, Query Store history, plans, system
  versioning history (ej. temporal tables se exportan pero el history puede mezclarse).
- **Lento**: para 1 TB puede tardar 8-24 h según hardware.
- **Sensible a features 2022**: si la BD se actualizó para usar features no disponibles en
  2017, el export puede fallar.

### Cuándo NO usarla
Si la decisión es "abandonar el rollback y mejorar el problema en SpainC", la Capa 4 no es
necesaria. Es la **última red de seguridad**.

---

## 8. Decisión: qué capa usar

Árbol de decisión durante una crisis:

```
¿Cuanto tiempo pasó desde el cutover?
│
├── < 5 min (pre-failover o muy poco tiempo después)
│    │
│    ├── ¿Failover ejecutado ya?
│    │    ├── NO  → Capa 0 (cancelar cutover) — RPO 0, RTO 3 min ✅
│    │    └── SI  → ¿AG_NorthEU intacto? → Capa 3 (rollback inmediato) ✅
│    │
├── 5 min - 1 h
│    │
│    └── ¿AG_NorthEU intacto? 
│         ├── SI → Capa 3 (rollback inmediato) ✅
│         └── NO → Capa 1 (restore desde bak) 
│
├── 1 h - 24 h
│    │
│    └── ¿Tenemos bak fresco?
│         ├── SI → Capa 1 (restore bak + log) ✅
│         └── NO → Capa 2 (restore VM snapshot) ✅
│
└── > 24 h
     │
     └── ¿La pérdida de tx post-cutover es aceptable?
          ├── SI → Capa 1 (T-24h) o Capa 2 (T-24h) ✅
          └── NO → Capa 4 (BACPAC export + import) — RTO horas/días
```

---

## 9. Verificación de cada capa (drill periódico)

**No vale tener capas si no están verificadas.** Recomendación: drill mensual.

### Verificación Capa 1 (backup + restore)
```sql
-- En una VM SQL 2017 cualquiera:
RESTORE VERIFYONLY FROM URL = 'https://<sa>.blob.core.windows.net/cutover-backups/AppDb_full_T-24h.bak';
-- Debe devolver "The backup set on file 1 is valid."
```

Cada trimestre, hacer un restore completo a una VM throwaway para asegurar que funciona
end-to-end.

### Verificación Capa 2 (VM snapshot)
- Restore-test mensual a un RG temporal.
- Validar que SQL Server arranca y la BD es accesible.

### Verificación Capa 3 (AG intacto)
- Después del cutover: `SELECT state_desc, recovery_model_desc FROM sys.databases WHERE name='AppDb'`
  en vm-sql2017.
- Si la BD está en `RECOVERY_PENDING` o `RESTORING` → Capa 3 viable.
- Si está en `SUSPECT` o no existe → Capa 3 NO viable, usar Capa 1.

### Verificación Capa 4 (BACPAC)
- Export-test trimestral, validar que se completa.
- Import-test sobre VM 2017 throwaway.

---

## 10. Triggers de activación de rollback

(Repetido de [`cutover-plan.md`](cutover-plan.md) §1.5 para tenerlo a mano)

| Métrica | Umbral | Capa |
|---|---|---|
| Cutover no completa en 5 min | inmediato | Capa 0 |
| Smoke tests fallan T+5min | inmediato | Capa 3 |
| HTTP 5xx > 5% sostenido > 60s | T+5-10min | Capa 3 |
| Latencia P95 > 3× baseline > 2 min | T+5-10min | Capa 3 |
| Errores SQL (logins, timeouts) > 10/min | T+5-15min | Capa 3 |
| Corrupción detectada en BD nueva | inmediato | Capa 1 o 2 |
| Decision negocio "revert" después de validación parcial | T+1h-T+24h | Capa 1 |
| Decision negocio "revert" tardío | T+24h+ | Capa 4 |

---

## 11. Comunicación durante un rollback

Templates listos para postear:

### Comms inicio rollback
```
🚨 ROLLBACK EN CURSO
Estamos revirtiendo el cutover por <razón>.
Estimación de duración: <X> min.
La app puede no responder durante este tiempo.
Actualización en 5 min.
```

### Comms rollback completo
```
✅ ROLLBACK COMPLETADO
La app vuelve a estar operativa en la infraestructura anterior.
Tiempo total de impacto: <X> min.
Pérdida de datos: <descripción>.
Próximos pasos: post-mortem en <fecha>.
```

### Comms si Capa 3/4 tiene pérdida
```
⚠️ ROLLBACK CON PÉRDIDA DE DATOS
Hubo <N> transacciones escritas durante la ventana del cutover que no se
recuperaron. Estamos analizando si son recuperables manualmente.
Si tu transacción está afectada, contacta a <soporte> con el ID <X>.
```

---

## 12. Post-mortem específico de rollback (obligatorio)

Si se activó cualquier capa de rollback, post-mortem en T+72h con:

- ¿Qué falló en el cutover?
- ¿Qué capa se usó? ¿Por qué esa y no otra?
- ¿RPO y RTO reales vs estimados?
- ¿La capa funcionó como esperabas? ¿Hubo sorpresas?
- ¿Qué cambia para el próximo intento?

---

## Referencias

- [`../../migration-rollback-plan.md`](../../migration-rollback-plan.md) — plan original del módulo MI Link (referencia conceptual)
- [`../../rollback-verification.md`](../../rollback-verification.md) — cómo verificar empíricamente cada capa
- [SQL Server backup to URL](https://learn.microsoft.com/sql/relational-databases/backup-restore/sql-server-backup-to-url)
- [Azure Backup for SQL Server in Azure VMs](https://learn.microsoft.com/azure/backup/backup-azure-sql-database)
- [SqlPackage utility — BACPAC export/import](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage)
- [Distributed AG — cautions on cross-version migration](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups#migrate-to-higher-sql-server-versions)
- [`cutover-plan.md`](cutover-plan.md) §1.5 y §8 (triggers + rollback durante cutover)
- [`post-cutover-strategies.md`](post-cutover-strategies.md) (qué hacer si NO hay rollback)
