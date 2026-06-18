# Estrategias post-cutover

Qué hacer con la VM SQL 2017 de NorthEU **después** de que la migración a SQL 2022 en SpainC
sea exitosa y la app esté operativa en el destino. Cuatro estrategias canónicas, cada una
con su propia narrativa de riesgo, coste y propósito.

> 📘 Pre-requisito: el cutover ya está hecho. La app escribe en SpainC. AG_NorthEU está
> "huérfano" (sigue arriba pero no recibe writes del DAG, y no puede aceptarlos porque el
> DAG está roto por la asimetría de versión).

---

## Diagrama del estado post-cutover (T+0)

```
       North Europe (origen, ahora secundario lógico)        Spain Central (nuevo primary)
   ┌────────────────────────────────────────┐        ┌────────────────────────────────────────┐
   │ VM SQL Server 2017 CU31                │        │ VM SQL Server 2022                     │
   │ AG_NorthEU local intacto               │        │ AG_SpainC ← primary del DAG            │
   │ BD <AppDb> queda en RESOLVING o        │        │ BD <AppDb> ACTIVA, recibiendo writes   │
   │   NOT SYNCHRONIZING / RECOVERY_PENDING │        │   de la app                            │
   │   (forward-only compat impide          │        │                                        │
   │    aplicar log de 2022 a 2017)         │        │ DAG_Migrate sigue existente            │
   │                                        │        │   pero en estado NOT HEALTHY           │
   │ ¿Qué hacemos con esta VM?              │        │                                        │
   └────────────────────────────────────────┘        └────────────────────────────────────────┘
                                                                       ▲
                                                                       │
                                                          App escribe aquí
```

**En este estado tienes 4 opciones canónicas**. Elegir una **antes del cutover**, no
después — la decisión condiciona pasos del runbook.

---

## Estrategia A — Decommission ordenado (la más común)

### Resumen
Mantener `AG_NorthEU` arriba como **botón de pánico frío** durante una ventana de seguridad
(T+24h, T+72h o T+7d según tolerancia), y después decommissionar todo:

- Romper el DAG.
- Detener servicios SQL en `vm-sql2017`.
- Eventualmente borrar VM + RG.

### Cuándo elegir esta estrategia
- El objetivo final es **migrar a MI** y no quieres complejidad extra en NorthEU.
- El equipo no quiere mantener una segunda instancia 2022 (la upgradada) sin propósito.
- El coste mensual de la VM 2017 importa.

### Pros
- **Lo más simple operativamente**.
- Coste se va a cero una vez decommissionada la VM.
- Cero ambigüedad sobre cuál es el primario "oficial".

### Contras
- **No tienes failback online cross-region** durante la ventana de seguridad. Si algo
  catastrófico pasa en SpainC en T+5d, no puedes volver al 2017 con los últimos datos —
  sólo a un backup pre-cutover (Capa 1 del rollback plan).
- Una vez decommissionada, no hay vuelta atrás sin restore desde backup.

### Pasos T+24h (validación OK → empezar decommission)

```sql
-- En SpainC (primary actual):
-- 1) Verificar el estado real del DAG primero
SELECT name, synchronization_health_desc
FROM sys.availability_groups;

-- 2) Si DAG_Migrate sigue existente con AG_NorthEU como miembro, removerla
ALTER AVAILABILITY GROUP [DAG_Migrate]
REMOVE AVAILABILITY GROUP [AG_NorthEU];

-- 3) Borrar el DAG entero
DROP AVAILABILITY GROUP [DAG_Migrate];
```

```sql
-- En NorthEU (legado):
-- 4) Sacar la BD del AG local huerfano (queda en estado RESTORING)
ALTER AVAILABILITY GROUP [AG_NorthEU]
REMOVE DATABASE [AppDb];

-- 5) Llevar la BD al estado ONLINE (sirve solo como referencia)
RESTORE DATABASE [AppDb] WITH RECOVERY;

-- 6) Pasar la BD a READ_ONLY explicito como guardia
ALTER DATABASE [AppDb] SET READ_ONLY WITH NO_WAIT;

-- 7) Quitar permisos de escritura a logins de aplicacion para evitar split brain
REVOKE INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::dbo FROM [app_user];
```

### Pasos T+7d (ventana de seguridad cumplida → eliminar)

```powershell
# Apagar VM 2017
az vm deallocate -g rg-milink-vm -n vm-sql2017

# Una semana mas en deallocated (no genera coste de compute, sigue genrando coste de disco)
# Eventualmente:
az vm delete -g rg-milink-vm -n vm-sql2017 --yes
az group delete -n rg-milink-vm --yes --no-wait
```

> **Conservar los backups pre-cutover en Blob durante al menos 90 días**. Ver
> [`rollback-plan.md`](rollback-plan.md) Capa 1.

---

## Estrategia B — Upgrade in-place del 2017 a 2022 para restaurar el DAG (oficial MS)

### Resumen
Hacer **upgrade in-place** del SQL Server 2017 a SQL Server 2022 en la VM de NorthEU.
Esto deja **dos instancias 2022** (NorthEU y SpainC) con el DAG funcional bidireccional,
habilitando **failback online cross-region**.

### Cita oficial MS
[Distributed availability groups — Migrate to higher SQL Server versions](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups#migrate-to-higher-sql-server-versions):

> "From here, choose if you want to decommission the original (primary) AG, or if you want to
> upgrade AG1 and maintain the distributed AG. **If you choose to maintain the distributed
> AG, then upgrade the SQL Server version for AG1 to match AG2. Once AG1 is upgraded, AG1
> becomes healthy, the distributed AG becomes healthy, the replicas catch up to
> synchronize, and fail-back becomes possible.**"

### Cuándo elegir esta estrategia
- El cliente quiere **DR cross-region** para SQL Server (no MI) como objetivo permanente.
- La migración a MI **no es prioridad inmediata** (puede ser T+meses).
- Se valora tener **failback online** disponible permanentemente, no sólo durante la
  ventana de seguridad.
- El presupuesto admite **dos VMs SQL 2022** funcionando indefinidamente.

### Pros
- **Failback nativo online** cross-region. Si SpainC tiene un problema, puedes hacer
  planned failover de vuelta a NorthEU **sin pérdida de datos**.
- El DAG queda como **arquitectura DR permanente** — el mismo patrón que se usaría para
  HA cross-region desde cero.
- Conserva la inversión hecha en el setup (cert exchange, NSGs, AGs locales).
- Es el patrón canónico recomendado por MS para DR cross-region SQL Server-only.

### Contras
- **Coste mensual permanente** de la VM secundaria 2022 + storage.
- **Operativa más compleja** — hay que monitorizar dos instancias, mantener parches
  sincronizados, gestionar dos credentials sets, etc.
- **No es trivial el upgrade in-place de SQL 2017 a 2022** — requiere planificación
  propia (assessment, backup pre-upgrade, ventana de servicio del 2017 que ya no recibe
  writes pero sí queries de "consultations").

### Workflow

```
T+0  cutover OK → app en SpainC, AG_NorthEU huerfano
T+24h validacion smoke OK
T+48h (decision punto) ¿queremos fail-back online cross-region permanente? → SI
       │
       ▼
T+72h Empezar upgrade in-place de vm-sql2017:
       1. Backup full + log de seguridad de la BD legacy (ya stale, pero por si acaso)
       2. Remover BD del AG_NorthEU local (sacarla del AG temporalmente)
          ALTER AG [AG_NorthEU] REMOVE DATABASE [AppDb]
          RESTORE DATABASE [AppDb] WITH RECOVERY -- queda online
       3. Ejecutar SQL Server 2022 setup.exe en modo upgrade in-place
          (mantiene instance name, mantiene config)
       4. Aplicar ultimo CU de SQL 2022
       5. Validar que SQL Server arranca y la BD legacy esta accesible
       6. Reanyadir la BD al AG local con SEEDING_MODE=MANUAL
       7. Restore del backup actual de SpainC (full+log) sobre vm-sql2017
          (WITH NORECOVERY)
       8. Reanyadir AG_NorthEU al DAG → debe sincronizar automaticamente
       9. Verificar DAG → state debe ser HEALTHY/SYNCHRONIZED

T+96h DAG_Migrate funcional bidireccional → failback disponible
```

### Detalle del paso 3 (upgrade in-place)

> ⚠️ El upgrade in-place de SQL 2017 → 2022 es una **operación delicada**. Tiene su propio
> runbook: [Upgrade SQL Server using the migration component in SSMS](https://learn.microsoft.com/ssms/migrate/upgrade-sql-server).

Pre-requisitos antes de lanzar setup:

- **Assessment** con DMA o SSMS Migration Component (compatibility, breaking changes).
- **Backup full + log** de la BD legacy y de las system databases.
- **Espacio en disco**: 6 GB extra mínimo para SQL 2022 binarios + cache.
- **Privilegios**: ejecutar setup como administrador local.
- **Ventana de servicio**: el upgrade reinicia la instancia SQL. Cualquier usuario
  conectado a la VM (RDP, queries) se desconecta. **Para nuestro caso esto no afecta a
  la app** porque la app ya está en SpainC.

Comando:

```powershell
# Asume ISO de SQL 2022 montado en E:
E:\setup.exe /q /ACTION=Upgrade `
  /INSTANCENAME=MSSQLSERVER `
  /IACCEPTSQLSERVERLICENSETERMS `
  /SQLSYSADMINACCOUNTS="BUILTIN\Administrators"
```

Tiempo típico: **30-60 minutos** (más reboot eventual de la VM).

### Trade-off del coste

| Componente | Coste mensual estimado (NorthEU) |
|---|---|
| VM Standard_E4ads_v5 (running 24/7) | ~150 €/mes |
| Premium SSD v2 1 TB | ~120 €/mes |
| SQL Server license (BYOL o pago por uso) | depende — BYOL ideal |
| Network (peering inter-region traffic) | ~10-50 €/mes según workload |
| **Total adicional** | **~300-400 €/mes** |

Comparar contra el coste de un disaster sin failback nativo: si se pierde SpainC y hay
que restaurar desde Blob a una VM nueva, son **horas de RTO**. Esa hora de RTO mata más
revenue que 300€/mes en muchos negocios.

### Pasos T-SQL (post-upgrade in-place)

```sql
-- En vm-sql2017 ya upgradeada a SQL 2022:
-- 1) Verificar version
SELECT @@VERSION; -- debe mostrar SQL Server 2022

-- 2) Sacar la BD legacy del AG (la replica primaria del AG local, que esta stale)
ALTER AVAILABILITY GROUP [AG_NorthEU]
REMOVE DATABASE [AppDb];

-- 3) Borrar la BD legacy (los datos buenos estan en SpainC)
DROP DATABASE [AppDb];

-- 4) Restaurar la copia actual de SpainC sobre vm-sql2017 (manual seeding nuevo)
RESTORE DATABASE [AppDb]
FROM URL = 'https://<sa>.blob.core.windows.net/<container>/AppDb_full_<fecha>.bak'
WITH NORECOVERY;

RESTORE LOG [AppDb]
FROM URL = 'https://<sa>.blob.core.windows.net/<container>/AppDb_log_<fecha>.trn'
WITH NORECOVERY;

-- 5) Reanyadir la BD al AG_NorthEU (ya en SQL 2022)
ALTER AVAILABILITY GROUP [AG_NorthEU]
ADD DATABASE [AppDb];

-- 6) Reanyadir AG_NorthEU al DAG (desde SpainC, el primary actual)
-- En vm-sql2022 (SpainC, primary del DAG):
ALTER AVAILABILITY GROUP [DAG_Migrate]
MODIFY AVAILABILITY GROUP ON 'AG_NorthEU' WITH (
    AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
    SEEDING_MODE = MANUAL
);

-- 7) Verificar healthy
SELECT
    ag.name,
    rs.synchronization_state_desc,
    rs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states rs
JOIN sys.availability_groups ag ON ag.group_id = rs.group_id;
-- Esperar a que ambas replicas muestren SYNCHRONIZED
```

A partir de aquí, **fail-back está disponible** (siguiendo el mismo protocolo de
[`cutover-plan.md`](cutover-plan.md) pero en sentido inverso).

---

## Estrategia C — Pivot directo a MI (saltar a la siguiente fase)

### Resumen
Una vez confirmado que SpainC funciona en producción, **decommission inmediato** del
2017 en NorthEU y empezar **YA** la fase siguiente: configurar **MI Link** entre el
SQL 2022 SpainC y un Azure SQL Managed Instance (en SpainC o región paired).

### Cuándo elegir esta estrategia
- **El objetivo real del proyecto es MI**. El paso por 2022 era sólo el vehículo.
- Quieres minimizar costes intermedios (no pagar 2 VMs 2022 si lo que quieres es MI).
- Aceptas el riesgo de un periodo corto sin failback online (rollback sólo vía backups).

### Pros
- **Avanza el proyecto** rápidamente hacia el objetivo final.
- No paga la "VM secundaria 2022" indefinidamente.
- Aprovecha el momento — el equipo está en modo migración, la inercia ayuda.

### Contras
- Si la fase MI tarda meses, durante todo ese tiempo **no hay DR cross-region nativo**.
- Si surge un problema con SpainC mientras se prepara MI, el rollback es a backups.

### Workflow

```
T+0     Cutover a SpainC OK
T+24h   Validacion smoke OK
T+72h   Confirmado estable en produccion
T+96h   Empezar estrategia A (decommission NorthEU 2017) en paralelo a:
T+96h   Empezar diseno de fase MI Link:
        - MI provision en SpainC (o region paired)
        - MI Link con update policy "SQL Server 2022"
        - Cert exchange SpainC ↔ MI
T+2w    MI Link operativo
T+3w    Cutover SpainC → MI (con fail-back NATIVO bidireccional al SpainC)
```

### Por qué esta estrategia desbloquea la mejor migración a MI
Es **exactamente la razón** por la que se hizo el paso por 2022. Una vez en MI con SQL
2022 origen, el MI Link es bidireccional y el rollback es nativo. **La fase MI no
necesita las 4 capas externas** del rollback plan del módulo original.

> Esto es **el argumento estratégico principal** para todo este módulo. Recuerda
> [`README.md`](README.md) §"Por qué este módulo existe".

---

## Estrategia D — AG_NorthEU como entorno de UAT/QA

### Resumen
Mantener el `AG_NorthEU` (en SQL 2017, o upgradeado a 2022) con una **copia desfasada**
de la BD, usándolo como entorno de **User Acceptance Testing / QA**.

- Cargas de prueba aisladas (sin afectar prod).
- Pruebas de queries pesadas, índices nuevos, análisis ad-hoc.
- Equipo de QA y BI puede consultar sin pegarle a prod.

### Cuándo elegir esta estrategia
- Hay equipo de **BI / QA / analytics** que ya estaba pidiendo un entorno espejo.
- Aprovecharlo justifica el coste de la VM legacy.
- No se quiere coste extra de levantar otro entorno UAT desde cero.

### Pros
- **Re-purpose útil** de una infraestructura que ya existe.
- Reduce carga en prod (queries pesadas se van a UAT).
- Coste se amortiza con valor de negocio (no es coste muerto).

### Contras
- **Datos desfasados** — UAT no refleja el estado actual de prod (salvo refresh
  periódico, lo cual añade operativa).
- **No es failover válido** — si SpainC cae, esta copia no es recovery (está desfasada).
- Compromete las decisiones de las otras estrategias (no es decommission, no es DAG
  bidireccional).

### Workflow

```
T+24h validacion OK
T+72h Romper DAG_Migrate, dejar AG_NorthEU como instancia standalone
       Recovery de la BD legacy (read-write)
T+1w  Renombrar BD a <AppDb>_uat
       Refresh manual mensual con backup de prod restaurado
       Provisionar logins UAT (lectura + escritura aislada)
T+permanente
```

### Cuándo NO elegirla
- Si ya existe un entorno UAT con otra herramienta — no dupliques.
- Si la BD es muy grande y el refresh mensual es pesado.

---

## Tabla comparativa de las 4 estrategias

| Atributo | A) Decommission | B) Upgrade in-place AG1 | C) Pivot a MI | D) UAT |
|---|---|---|---|---|
| Coste mensual incremental | 0 (post-decom) | ~300-400 €/mes | 0 + coste MI | ~300 €/mes |
| Failback online cross-region | ❌ | ✅ | ❌ | ❌ |
| Complejidad operativa | Mínima | Alta | Media (corta) | Media |
| Plazo hasta MI | Sin compromiso | Largo (meses) | **Rápido** | Largo |
| RTO en disaster SpainC | Horas (restore) | Minutos (failback) | Horas | Horas |
| Reutiliza infra existente | ❌ | ✅ | ❌ | ✅ |
| Recomendado para… | Migración con MI como objetivo claro | DR cross-region SQL-only permanente | Equipo con MI como objetivo principal | Cliente con necesidad UAT no cubierta |

---

## Recomendación según objetivo final

### Si el objetivo final es **migrar a MI** (probablemente tu caso, dado el repo)
→ **Estrategia C (Pivot a MI)**. El paso por 2022 era el vehículo, ahora aprovecha la
inercia para llegar al destino real. Decommission el 2017 cuando MI esté operativo.

### Si el objetivo final es **DR cross-region SQL Server-only**
→ **Estrategia B (Upgrade in-place)**. Te deja con la arquitectura permanente que querías
desde el principio.

### Si el budget es duro y MI todavía es lejano
→ **Estrategia A (Decommission)**. Más simple, riesgo aceptable durante T+ventana_seguridad.

### Si hay demanda interna de UAT no cubierta
→ **Estrategia D**. Justifica el coste con valor de negocio.

---

## Decisión que tomar antes del cutover

Esta no es una decisión post-hoc. **Decide la estrategia antes del cutover** porque:

- Afecta cómo se gestiona el AG_NorthEU durante el cutover.
- Afecta el dimensionado de Blob (cuánto retener de backups).
- Afecta el plan de comunicación (cuándo se anuncia decommission).
- Afecta el budget aprobado (estrategia B sube coste recurrente).

**Output de la decisión**: una sección en [`cutover-plan.md`](cutover-plan.md) que diga
"Tras el cutover, ejecutar Plan X".

---

## Referencias

- [Distributed availability groups — Migrate to higher SQL Server versions](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups#migrate-to-higher-sql-server-versions)
- [Failover to a secondary availability group](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-distributed-availability-groups#failover)
- [Upgrade SQL Server using the migration component in SSMS](https://learn.microsoft.com/ssms/migrate/upgrade-sql-server)
- [Plan a SQL Server installation](https://learn.microsoft.com/sql/sql-server/install/planning-a-sql-server-installation)
- [Azure SQL Managed Instance link feature overview](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-feature-overview)
