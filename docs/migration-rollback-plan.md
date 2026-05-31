# Plan de migración con botón del pánico (SQL Server → Azure SQL Managed Instance)

Plan de cutover usando MI Link como vehículo de migración, con un mecanismo de
rollback multi-capa diseñado para escenarios donde el Link es **unidireccional**
(SQL Server 2016/2017/2019).

> Si el origen es SQL Server 2022/2025 con MI configurado con la update policy
> correspondiente, parte del rollback puede apoyarse en el propio Link
> (reverse migration). Aun así, **Capa 1 sigue siendo recomendable** como
> backup independiente. Ver [`version-comparison.md`](version-comparison.md).

## Resumen ejecutivo

| | SQL Server 2016/2017/2019 | SQL Server 2022/2025 |
|---|---|---|
| MI Link direccional | ⚠️ **One-way** | ✅ Bidireccional con fail-back online |
| Failover sin pérdida (planned) | ✅ Sí | ✅ Sí |
| Tras failover el link… | **Se rompe y se elimina** | Se mantiene activo (opcional) |
| Fail-back vía Link | ❌ No | ✅ Sí, online |
| Recovery oficial post-cutover | BACPAC / repl. transaccional / backup nativo | Restore directo MI → SQL Server |

> ⚠️ **Conclusión**: para SQL 2016/2017/2019 el rollback **NO** puede depender del Link.
> Hay que construir defense in depth fuera del Link.

---

## Arquitectura de rollback (defense in depth)

```
                 ┌─────────────────────────────────────────┐
                 │     Antes del cutover                    │
                 │                                          │
                 │  Capa 1 → Backup .bak full+log → Blob   │
                 │  Capa 2 → Azure Backup snapshot VM      │
                 │  Capa 3 → Primary SQL Server INTACTO    │
                 │           (no decommission)              │
                 └─────────────────────────────────────────┘
                                  │
                                  ▼
                 ┌─────────────────────────────────────────┐
                 │           CUTOVER                        │
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
                   Capa 3 (rollback inmediato)        Capa 4 (rollback tardío)
                   App → SQL primary                  MI → BACPAC → SQL primary
                   Pérdida: writes a MI               Pérdida: gap durante export
```

---

## Capa 1 — Backup nativo SQL Server (.bak) → Blob o disco

Backup `COPY_ONLY` full + log de la BD justo antes del cutover.

**Ventajas**: granular (a nivel DB), portable, restore en cualquier SQL Server
de la misma versión major o superior.

**Requisitos**:
- Para *BACKUP TO URL*: credential SQL con `SHARED ACCESS SIGNATURE` apuntando al
  container. SQL Server 2017 CU17+ acepta user-delegation SAS.
- Para *BACKUP TO DISK*: storage local suficiente + transferencia posterior
  (AzCopy con managed identity, robocopy, etc.).
- Outbound 443 desde la VM al blob (storage account público o private endpoint).

**Por qué `COPY_ONLY`**: no avanza el `differential_base_lsn` ni interrumpe la
cadena de logs del AG/Distributed AG. **No rompe el Link**.

**Script**: `scripts/05-pre-cutover-backup.sql` (plantilla TO URL),
`scripts/06-pre-cutover-backup.ps1` (wrapper TO DISK + AzCopy).

**Restore (rollback)**:
```sql
RESTORE DATABASE <DbName>
  FROM URL = 'https://<storage>.blob.core.windows.net/<container>/<DbName>_pre_cutover.bak'
  WITH REPLACE, NORECOVERY;

RESTORE LOG <DbName>
  FROM URL = 'https://<storage>.blob.core.windows.net/<container>/<DbName>_pre_cutover.trn'
  WITH RECOVERY;
```

Para el caso de archivos en disco, sustituir `FROM URL` por `FROM DISK`.
Plantilla completa en `scripts/09-rollback-restore-from-blob.sql`.

---

## Capa 2 — Azure Backup (Recovery Services Vault) sobre la VM

Snapshot **application-consistent** de toda la VM (disk + SQL Server quiesced via
VSS writer).

**Ventajas**: si toda la VM se corrompe (no solo la BD), restauras el SO completo.
El VSS writer congela SQL Server para evitar inconsistencias transaccionales.

**Tipo de snapshot**:
- `CrashConsistent` por defecto en VM genérica.
- `AppConsistent` cuando la VM tiene la extensión `IaaSVMSnapshot` (presente por
  defecto en imágenes Marketplace SQL Server).

**Disponibilidad para restore**: el recovery point está disponible para restore
en cuanto el snapshot se completa. La transferencia al vault sigue después en
background pero **no bloquea** el rollback inmediato.

**Script**: `scripts/07-enable-azure-backup-vm.ps1`.

> **Tip operativo**: programa un **on-demand snapshot** justo antes del cutover
> disparado por el runbook, además del backup programado. No dependas de la ventana
> programada.

**Restore granular a otra ubicación** (sin destruir la VM original):
```powershell
az backup restore restore-disks `
  -g <rg> -v <vault> `
  -c "IaasVMContainer;iaasvmcontainerv2;<rg>;<vm>" `
  -i "VM;iaasvmcontainerv2;<rg>;<vm>" `
  -r <recovery-point-id> `
  --storage-account <staging-storage>
```

---

## Capa 3 — Mantener el primary SQL Server INTACTO post-cutover

La capa más simple y, en la práctica, la más eficaz para rollback inmediato.

Tras el cutover:
1. El SQL Server origen **sigue existiendo y operativo** (solo sin tráfico productivo).
2. La aplicación apunta al MI.
3. Si en las primeras horas/días algo va mal → repoint del connection string al
   SQL Server origen y se recupera el estado **exacto** del momento del cutover.

**Cómo activar la capa**:

1. **No destruir** la VM. Nada de `az vm delete`, ni siquiera un `deallocate`
   agresivo programado.
2. Tras el cutover, en el SQL Server origen, dejar la BD en `READ_ONLY` o
   renombrarla para evitar conexiones accidentales:
   ```sql
   ALTER DATABASE <DbName> SET READ_ONLY;
   -- O para máxima seguridad:
   ALTER DATABASE <DbName> MODIFY NAME = <DbName>_PRE_CUTOVER;
   ```
3. Activar Server Audit en SQL Server para detectar cualquier conexión inesperada
   (`scripts/10-post-cutover-freeze-primary.sql` lo deja configurado).

**Cómo se activa el rollback**:

1. Cambiar `READ_ONLY` → `READ_WRITE` (o renombrar de vuelta).
2. Cambiar el connection string de la app al SQL Server origen.
3. Validar consistencia con el plan de smoke tests.

**Pérdida potencial**: cualquier dato escrito en el MI entre el cutover y el
rollback. Mitigaciones:
- App en modo lectura mientras dura la validación → pérdida = 0.
- Si hay writes durante validación → necesitas Capa 4 para reconciliar.

---

## Capa 4 — Rollback tardío

Cuando ya hay datos críticos escritos en el MI que no se pueden perder y han
pasado suficientes ciclos como para no poder usar Capa 3 limpiamente.

### Opción A — BACPAC export desde MI

1. Generar BACPAC desde Azure portal (SQL MI → Export) o `sqlpackage.exe /a:Export`.
2. Import en el SQL Server origen:
   ```cmd
   sqlpackage.exe /a:Import ^
     /sf:<DbName>.bacpac ^
     /tsn:<server> ^
     /tdn:<DbName>_recovered ^
     /tu:sa /tp:<pwd>
   ```
3. Cutover de vuelta controlado: stop writes en MI → último export incremental →
   repoint app al SQL Server origen.

**Pros**: oficial, robusto, schema + datos.
**Contras**: BACPAC no es estrictamente transaccional (puede requerir DB en
READ_ONLY durante el export para garantizar consistencia).

### Opción B — Replicación transaccional inversa (MI → SQL Server)

MI puede ser publisher en transactional replication; SQL Server origen actúa de
subscriber.

Setup más complejo, pero permite sync continuo sin downtime adicional.

📖 [Replication with managed instance](https://learn.microsoft.com/azure/azure-sql/managed-instance/replication-transactional-overview)

### Opción C — Tabla por tabla (SSIS / ADF / SqlBulkCopy)

Para escenarios muy custom donde se necesita seleccionar qué tablas restaurar
y qué tablas dejar como están.

### Opción D (solo SQL 2022/2025) — Link en sentido reverso

Si el MI está configurado con update policy *SQL Server 2022* o *SQL Server 2025*
y el primary es de la misma versión, se puede establecer un nuevo Link
**desde el MI hacia el SQL Server origen** y hacer un planned failover en sentido
inverso. Detalles en
[disaster-recovery docs](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-disaster-recovery).

---

## Compatibility level — el detalle crítico

| | SQL 2017 origen | SQL 2019 origen | SQL 2022 origen | MI tras cutover |
|---|---|---|---|---|
| Default compat level | 140 | 150 | 160 | Hereda el del origen |
| Soportado en MI | 100-160 | 100-160 | 100-160 | hasta 160 |
| Upgrade a 150+ en MI | – | – | – | ⚠️ **Imposible rollback a 2017** |

### Regla de oro

> **Mantén la BD en MI en el compat level del origen hasta que estés 100%
> comprometido con el cutover.**
> Subir el compat level rompe la portabilidad de vuelta a la versión anterior.

```sql
-- Verificar compat level en MI tras el cutover
SELECT name, compatibility_level
FROM sys.databases WHERE name = N'<DbName>';

-- Si subió y necesitas rollback:
ALTER DATABASE <DbName> SET COMPATIBILITY_LEVEL = 140;
-- (esto solo cambia el modo del query optimizer, no revierte features 2019+)
```

### Features bloqueantes para rollback a 2017

| Feature | Versión introducida | Bloquea rollback a 2017 |
|---|---|---|
| Accelerated DB Recovery (ADR) | 2019 (compat 150) | ⚠️ Si activado |
| Edge constraints | 2019 | ⚠️ |
| UTF-8 collations | 2019 | ⚠️ |
| Ledger tables | 2022 | ⚠️ |
| GENERATE_SERIES, DATE_BUCKET | 2022 | ⚠️ |
| Always Encrypted con enclaves | 2019+ | ⚠️ |
| JSON nativo (JSON_OBJECT, JSON_ARRAY) | 2022 | ⚠️ |

Validación obligatoria **antes del punto de no retorno**:

```sql
-- Detectar uso de features modernas activadas accidentalmente
SELECT * FROM sys.dm_exec_query_optimizer_info WHERE counter LIKE '%2019%';
-- Y revisar Query Store si está habilitado
```

---

## Procedimiento de rollback inmediato (Capa 3)

> Aplica si la decisión de rollback ocurre **antes** de que la app haya escrito
> datos críticos en el MI o cuando esos datos son reconstruibles.

```powershell
# 1. App: cambiar el connection string al SQL Server origen
#    (App Service config, Key Vault, k8s secret, etc.)

# 2. En SQL Server primary, devolver la BD a estado escribible
sqlcmd -S <vm-name> -E -Q "ALTER DATABASE <DbName> SET READ_WRITE;"

# 3. (Opcional) Bloquear el MI para evitar dual-write durante el rollback
#    En el MI:
ALTER DATABASE <DbName> SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;

# 4. Validar app contra primary y monitorizar
# 5. Lessons learned: documentar qué se detectó y por qué se canceló
```

Script empaquetado: `scripts/08-rollback-immediate.sql`.

---

## Procedimiento de rollback tardío (Capa 4 — BACPAC)

### Setup pre-export

```sql
-- En MI: poner la BD en READ_ONLY para garantizar export consistente
ALTER DATABASE <DbName> SET READ_ONLY;
```

### Export BACPAC

```powershell
sqlpackage.exe `
  /a:Export `
  /tsn:"<mi-fqdn-public>,3342" `
  /tu:"<admin-upn>" `
  /tdn:<DbName> `
  /tf:"C:\rollback\<DbName>_export.bacpac" `
  /ua:true   # Active Directory Integrated
```

### Import en SQL Server primary

```powershell
sqlpackage.exe `
  /a:Import `
  /sf:"C:\rollback\<DbName>_export.bacpac" `
  /tsn:<server> `
  /tu:sa /tp:"<sa-pwd>" `
  /tdn:<DbName>_restored
```

### Switch over

```sql
-- En SQL Server: descartar la copia frozen y promover la restaurada
DROP DATABASE <DbName>;   -- la copia READ_ONLY pre-cutover
ALTER DATABASE <DbName>_restored MODIFY NAME = <DbName>;
ALTER DATABASE <DbName> SET READ_WRITE;
```

---

## Decision matrix — qué rollback usar

```
┌─────────────────────────────────────────────────────────────┐
│ ¿Cuándo se detectó el problema?                             │
└────────────────────────┬────────────────────────────────────┘
                         │
       ┌─────────────────┴─────────────────┐
       │                                   │
  Justo tras cutover                  Más adelante
       │                                   │
       ▼                                   ▼
  ¿La app ya escribió                 Capa 4
  datos al MI?                        (BACPAC o repl. transaccional)
       │                              
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
   inmed.   (BACPAC)                  
```

```
┌─────────────────────────────────────────────────────────────┐
│ ¿Es solo la BD, o toda la VM/SO?                            │
└────────────────────────┬────────────────────────────────────┘
                         │
       ┌─────────────────┴─────────────────┐
       │                                   │
   Solo BD                             VM o SO corrupto
       │                                   │
       ▼                                   ▼
   Capa 1 (RESTORE                     Capa 2 (Azure Backup VM
   from .bak)                          restore to disks)
```

---

## Drill obligatorio antes del cutover real

Cada capa debe verificarse en un entorno de staging idéntico al de producción.
Procedimiento detallado en [`rollback-verification.md`](rollback-verification.md).

Checklist mínima:

- [ ] Capa 1: tomar backup, simular tráfico post-backup, restaurar en una BD
      nueva y comparar row counts / checksums con el estado esperado.
- [ ] Capa 2: lanzar un on-demand snapshot, verificar que aparece un recovery
      point AppConsistent y probar `restore-disks` a una VM efímera.
- [ ] Capa 3: practicar el switch de connection string + el `ALTER DATABASE … READ_WRITE`
      en un entorno aislado y medir el tiempo end-to-end.
- [ ] Capa 4: hacer un export+import BACPAC del tamaño real (o del tamaño máximo
      esperado) para validar el procedimiento y dimensionar la ventana.

---

## Referencias oficiales

- [Migrate with the link](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-migrate)
- [Failover with the link (cutover unidireccional)](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-disaster-recovery)
- [SQL Server backup to URL](https://learn.microsoft.com/sql/relational-databases/backup-restore/sql-server-backup-to-url)
- [ALTER DATABASE compatibility level](https://learn.microsoft.com/sql/t-sql/statements/alter-database-transact-sql-compatibility-level)
- [Azure Backup for SQL Server VM workloads](https://learn.microsoft.com/azure/backup/backup-azure-sql-database)
- [sqlpackage / BACPAC import-export](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage)
