# Guía oficial de Microsoft para esta migración

Este documento recoge **literalmente** lo que la documentación oficial de Microsoft dice
sobre los caminos posibles para migrar SQL Server 2017 (NorthEU) → SQL Server 2022 (SpainC)
en VMs Azure. Sirve como ground truth para validar y/o cuestionar el diseño elegido en
[`decision-rationale.md`](decision-rationale.md) y [`architecture.md`](architecture.md).

Todas las citas con URL para auditoría.

---

## 1. Métodos oficiales según MS Learn

La página maestra es
**[Migration overview: SQL Server to SQL Server on Azure VMs](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/overview)**.
MS clasifica las opciones en dos estrategias:

### Estrategia "Lift and shift" (no cambia versión)

| Método oficial | Cuándo | Versión |
|---|---|---|
| [Azure Migrate](https://learn.microsoft.com/azure/migrate/index) | Mover SQL Server tal cual, sin upgrade | Mín 2008 SP4 → 2012 SP4 |
| [Azure Site Recovery](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/move-sql-vm-different-region) | Mover una VM SQL ya en Azure a otra región | N/A — replica VM, no upgrade |

**Veredicto para nuestro caso**: descartados. Nuestro caso **requiere cambio de versión**
(2017 → 2022), por tanto la estrategia "Lift and shift" no aplica.

### Estrategia "Migrate" (sí cambia versión)

MS lista 7 métodos. Cita literal:

> "The following table details all available methods to migrate your SQL Server database to
> SQL Server on Azure VMs"

| # | Método oficial | Min source | Min target | Notas MS (extracto) |
|---|---|---|---|---|
| 1 | **[Distributed availability group](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/distributed-availability-group-prerequisites)** | 2016 | 2016 | "This method minimizes downtime." |
| 2 | [Backup to a file](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/guide#migrate) | 2008 SP4 | 2012 SP4 | "Simple and well-tested." |
| 3 | [Backup to URL](https://learn.microsoft.com/sql/relational-databases/backup-restore/sql-server-backup-to-url) | 2012 SP1 CU2 | idem | Para BD ≤ 1 TB con buena conectividad. |
| 4 | [SSMS Migration Component](https://learn.microsoft.com/ssms/migrate-sql-server-component) | 2005 | 2012 SP4 | "Includes capability to migrate SQL and Windows logins." |
| 5 | [Detach and attach from URL](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/guide#detach-and-attach-from-a-url) | 2008 SP4 | 2014 | Útil con BD muy grandes en Blob. |
| 6 | [Log shipping](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/guide#migrate) | 2012 SP4 Windows | idem | "Less configuration overhead than AG." |
| 7 | [Convert to Hyper-V VHD + Azure Blob](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/guide#convert-vm) | 2012 | 2012 | Para BYOL y/o BDs viejas. |

**Lo que MS NO menciona aquí pero existe**:

- **[Azure DMS online](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/database-migration-service-online)** — sí soporta SQL Server → SQL Server VM, **lo cubre un tutorial dedicado**.
- **[Azure Arc-enabled SQL Server migration to Azure VMs (preview)](https://learn.microsoft.com/sql/sql-server/azure-arc/migrate-to-sql-server-on-azure-vms)** — requiere que el origen esté Arc-enabled.

---

## 2. Lo que MS dice **específicamente** sobre cross-version (2017 → 2022)

Fuente:
**[Distributed availability groups — Migrate to higher SQL Server versions](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups)**.
Sección "Cautions when using distributed availability groups to migrate to higher SQL Server versions".

### Citas literales (traducidas) — críticas

> "When you configure the distributed AG with a SQL Server migration target that is a higher
> version than the source, **autoseeding isn't supported** so the seeding mode must be set to
> `MANUAL`. If you don't disable AUTO-SEEDING, your migration will fail and you'll see error
> 946 'Cannot open database DistributionAG version xxx. Upgrade the database to the latest
> version'."

**Implicación crítica para nuestro módulo**:
- ❌ **AUTOMATIC seeding NO funciona** cross-version 2017→2022.
- ✅ **MANUAL seeding obligatorio**: backup full + log en NorthEU → restore en SpainC con
  `NORECOVERY` → añadir BD al AG con seeding manual.
- Esto **corrige** lo que decía la primera versión de [`architecture.md`](architecture.md).

> "You won't have read access to any of the replica databases on the secondary AG as long as
> the primary AG is at a lower version."

**Implicación**: durante la fase pre-cutover, **el secundario en SpainC (2022) no es legible**.
No se pueden hacer test queries de validación contra él hasta que sea promocionado. Plan B:
restaurar un .bak por separado a otra instancia 2022 temporal para validar paridad.

> "Once the distributed AG is failed over to the higher version (AG2), AG2 should become
> Healthy. During this time, fail-back to AG1 won't be possible, as it is at a lower version.
> Because AG1 is at a lower version, updates from AG2 after failover to AG2 won't be
> replicated over to AG1."

**Implicación**: confirma que el rollback **no puede ser via DAG**. Las 4 capas externas son
necesarias (ya cubierto en [`rollback-plan.md`](rollback-plan.md)).

> "From here, choose if you want to decommission the original (primary) AG, or if you want to
> upgrade AG1 and maintain the distributed AG. If you choose to maintain the distributed AG,
> then upgrade the SQL Server version for AG1 to match AG2. Once AG1 is upgraded, AG1
> becomes healthy, the distributed AG becomes healthy, the replicas catch up to
> synchronize, and **fail-back becomes possible**."

**OPCIÓN ESTRATÉGICA OFICIAL** que merece su propio documento:
- **Post-cutover**, si se hace un upgrade in-place del 2017 a 2022 en NorthEU (la VM
  original), el DAG vuelve a estar healthy y se habilita failback.
- Esto da un **patrón de "burning bridges controlado"**: vives 1-2 semanas con el DAG roto
  pero el primario intacto como rollback, y cuando todo está estable haces upgrade del
  origen para tener failback nativo para siempre.
- Cubierto en detalle en [`post-cutover-strategies.md`](post-cutover-strategies.md) (pendiente
  de crear).

---

## 3. El protocolo oficial de cutover con RPO 0

Fuente: misma página de Distributed AG.

> "To complete the migration to the new configuration, at the end of the process, **stop all
> data traffic to the original availability group, and change the distributed availability
> group to synchronous data movement.** This action ensures that the primary replica of the
> second availability group is fully synchronized, so there would be no data loss. After
> you've verified the synchronization, fail over the distributed availability group to the
> secondary availability group."

**Implicación para [`rpo-options.md`](rpo-options.md)**:
- La cita de MS menciona "change to synchronous data movement" como **una** forma de
  asegurar que no hay pérdida de datos antes del failover. Pero **no es la única ni es
  obligatoria**: lo esencial es garantizar que la réplica está totalmente al día antes del
  failover, y eso se consigue igual de bien en asíncrono drenando escrituras y verificando
  que la cola de envío está a 0.
- **Pasos recomendados (asíncrono, por defecto)**:
  1. **Drain writes** en NorthEU (app deja de escribir).
  2. **Esperar a que el asíncrono vacíe la cola** (`log_send_queue_size = 0` y
     `redo_queue_size = 0`) y los `last_hardened_lsn` coincidan en ambos lados.
  3. **Failover** del DAG hacia SpainC (`FORCE_FAILOVER_ALLOW_DATA_LOSS` — no pierde nada
     porque ya está todo verificado).
  4. **App repoint**.
- **Opcional**: cambiar a síncrono unos segundos antes del failover solo si quieres una
  señal de estado `SYNCHRONIZED` más explícita que mirar las colas. No es necesario para
  el RPO 0, y como las escrituras ya están paradas, la latencia no penaliza. Es comodidad
  operativa, no un requisito.

> 📖 **Matiz del failover del DAG** ([Configure DAG — Fail over](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-distributed-availability-groups#fail-over-a-distributed-availability-group)):
> *"For a distributed availability group, the only supported failover type is a manual
> user-initiated `FORCE_FAILOVER_ALLOW_DATA_LOSS`. Therefore, to prevent data loss, you must
> take extra steps... to ensure data is synchronized between the two replicas before
> initiating the failover."*
> Por eso lo importante es verificar la sincronización **antes** del failover — y eso se
> hace perfectamente en asíncrono mirando colas + LSN.

> "If you're not sure which to use, then set both [availability modes] to asynchronous commit
> mode **until you're ready to fail over**."

**Confirmación oficial** de la recomendación del modo A en `rpo-options.md`: ASYNC durante
toda la replicación **y también en el cutover** (drain + cola a 0 + failover). El síncrono
solo aporta en DR con RPO 0 permanente, que no es el caso de esta migración.

---

## 4. Tutorial oficial paso a paso para nuestro caso exacto

MS tiene un **tutorial específico** que casi cubre nuestro escenario (single-instance, no
AG en origen):

**[Use distributed AG to migrate databases from a standalone instance](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/distributed-availability-group-migrate-standalone-instance)**

Nuestro origen **sí tiene AG ya** (del módulo MI Link existente), así que aplica más bien:

**[Use distributed AG to migrate availability group](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/distributed-availability-group-migrate-availability-group)**

Ambos tutoriales son ahora la referencia base de nuestros scripts en
[`../../../scripts/modules/sql2017-to-sql2022/`](../../../scripts/modules/sql2017-to-sql2022/).

### Lo que el tutorial estándar **asume y nosotros NO tenemos**

| Asunción tutorial | Nuestra realidad | Mitigación |
|---|---|---|
| Source y target en el **mismo dominio** (o federados) | Sin dominio común NorthEU↔SpainC | **Cert auth en endpoints** (en lugar de Windows auth). Cubierto en [`architecture.md`](architecture.md). |
| **Mismo instance name** en source y target (`MSSQLSERVER`) | Asumir mismo nombre (Marketplace default) | Validar; si no, **manual seeding obligatorio**. |
| AUTOMATIC seeding | **Imposible cross-version** | Manual seeding con backup/restore previo. |
| Misma versión SQL Server | 2017 → 2022 | Seguir las "cautions" del DAG cross-version. |

---

## 5. Comparativa de los 3 caminos oficiales más relevantes

Resumen ejecutivo para nuestro caso (cross-region + cross-version + zero downtime + RPO 0):

| Atributo | DAG cross-region | DMS online | SSMS Migration Component |
|---|---|---|---|
| Soporte oficial cross-version 2017→2022 | ✅ Con seeding MANUAL | ✅ | ✅ (con SSMS 21+) |
| Soporte oficial cross-region | ✅ Cualquier red routable | ✅ Vía SHIR + Blob | ✅ (vía share network) |
| Downtime cutover | **Segundos** | Minutos (cutover final = tail-log + restore) | Minutos (backup → copy → restore) |
| RPO en cutover planificado | **0** (drain + cola a 0 en ASYNC) | 0 (con último tail-log) | 0 (con stop app + backup full) |
| Necesita servicio Azure adicional | No | DMS + Data Factory + SHIR | No |
| Logins migrados automáticamente | ❌ Manual via script | ❌ Manual | ✅ Sí, el wizard los incluye |
| Jobs SQL Agent | ❌ Manual | ❌ Manual | ❌ Manual (script desde SSMS) |
| Reproducible en script (sin GUI) | ✅ Todo T-SQL + PS | ⚠️ Wizard portal o ARM | ❌ GUI only |
| Adecuado para repo "infra-as-code" | ✅ | ⚠️ | ❌ |
| Costos extra mensuales | 0 (sólo VMs) | DMS por horas + Data Factory | 0 |
| Madurez | GA años | GA | GA (componente nuevo en SSMS 21) |
| Tu equipo ya lo conoce (por MI Link) | ✅ Mismo patrón | ❌ Nuevo | ❌ Nuevo |

### Veredicto basado en la oficial MS

✅ **DAG cross-region sigue siendo la elección correcta** para nuestro caso, **con dos correcciones**:

1. **Seeding MANUAL obligatorio** (no AUTOMATIC como recomendaba la primera versión de
   `architecture.md`).
2. **Protocolo de cutover en ASYNC**: drenar escrituras, esperar a que la cola de
   replicación llegue a 0 y los LSN coincidan, y entonces hacer el failover. No hace falta
   cambiar a síncrono (opcional, solo por comodidad de tener una señal `SYNCHRONIZED` más
   explícita). El síncrono solo aporta en DR con RPO 0 permanente, que no es este caso.

Ambas correcciones se aplicarán a los docs correspondientes y a los scripts que se generen.

### Cuándo elegirías una alternativa

- **Elegirías DMS online** si: no tienes acceso para crear endpoints/AGs en el origen, o
  prefieres operativa via portal Azure en vez de T-SQL. Trade-off: cutover de minutos, no
  segundos.
- **Elegirías SSMS Migration Component** si: la migración es un evento único, no
  recurrente, y quieres GUI con migración de logins integrada. Trade-off: no encaja con
  un repo infra-as-code; downtime de minutos.
- **Elegirías Backup + Restore** si: ventana de mantenimiento de horas es aceptable, BD
  enorme con buen ancho de banda a Blob. Simplísimo, pero no es zero downtime.

---

## 6. Lo que MS dice sobre objetos out-of-band

Fuente: [Migration overview — Server objects](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/overview#server-objects).

> "Depending on the setup in your source SQL Server, there might be other SQL Server features
> that require manual intervention to migrate them to SQL Server on Azure VM by generating
> scripts in Transact-SQL (T-SQL) using SQL Server Management Studio and then running the
> scripts on the target SQL Server on Azure VM. Some of the commonly used features are:
> Logins and roles, Linked servers, External Data Sources, Agent jobs, Alerts, Database Mail,
> Replication."

> "For a complete list of metadata and server objects that you need to move, see
> [Manage Metadata When Making a Database Available on Another Server](https://learn.microsoft.com/sql/relational-databases/databases/manage-metadata-when-making-a-database-available-on-another-server)."

Esto **confirma** la lista de [`out-of-band-objects.md`](out-of-band-objects.md) (pendiente)
y añade **External Data Sources** y **Replication** que no había mencionado. Hay que
añadirlos.

---

## 7. Lo que MS recomienda para Business Intelligence (si aplica)

Fuente: [Migration overview — Business Intelligence](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/overview#business-intelligence).

Si la BD migrada usa SSIS/SSRS/SSAS:

| Servicio | Recomendación oficial |
|---|---|
| SSIS | Backup/restore del SSISDB (es una BD), o redeploy paquetes |
| SSRS | Migración manual con tooling SSRS, o migrar reports a Power BI Paginated Reports |
| SSAS | SSMS, AMO, o XMLA scripts. Alternativa: Azure Analysis Services |

**Fuera de scope de este módulo** salvo que la BD a migrar tenga dependencia funcional con
SSIS catalog. Documentar como "consideración adicional" en `out-of-band-objects.md`.

---

## 8. Resumen de correcciones que requieren los docs existentes

Cambios identificados al revisar la documentación oficial:

| Doc afectado | Corrección | Motivo |
|---|---|---|
| `architecture.md` § 6 (Seeding strategy) | Marcar AUTOMATIC como **NO soportado cross-version**. MANUAL es obligatorio. | [Distributed AG — cautions](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups#cautions-when-using-distributed-availability-groups-to-migrate-to-higher-sql-server-versions) |
| `rpo-options.md` § cutover | Cutover en ASYNC (drain + cola a 0 + failover). SYNC opcional, solo señal de estado | [Configure DAG — Fail over](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-distributed-availability-groups#fail-over-a-distributed-availability-group) |
| `decision-rationale.md` § DMS | Subir el rating de DMS — sí está soportado oficialmente para SQL VM → SQL VM con tutorial dedicado | [DMS online tutorial](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/database-migration-service-online) |
| `decision-rationale.md` (nueva entrada) | Añadir SSMS Migration Component como opción evaluada | [SSMS Migration Component](https://learn.microsoft.com/ssms/migrate/upgrade-sql-server) |
| `decision-rationale.md` (nueva entrada) | Añadir Azure Arc migration to Azure VMs (preview) como opción evaluada (y descartada por requisito Arc) | [Arc migration](https://learn.microsoft.com/sql/sql-server/azure-arc/migrate-to-sql-server-on-azure-vms) |
| `out-of-band-objects.md` (pendiente) | Incluir External Data Sources y Replication artifacts | [Server objects list](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/overview#server-objects) |
| (Nuevo doc) `post-cutover-strategies.md` | Documentar la opción oficial de "upgrade AG1 in-place al 2022 post-cutover para restaurar DAG y habilitar failback" | [DAG cautions — Migrate to higher SQL Server versions](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups#migrate-to-higher-sql-server-versions) |

---

## Referencias maestras (todas las URLs citadas en este doc)

### Documentos de visión global
- [Migration overview: SQL Server to SQL Server on Azure VMs](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/overview)
- [Migration guide: SQL Server to SQL Server on Azure Virtual Machines](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/guide)
- [Choose a Database Engine upgrade method](https://learn.microsoft.com/sql/database-engine/install-windows/choose-a-database-engine-upgrade-method)

### Distributed AG
- [Distributed availability groups (overview + cautions)](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups)
- [Use distributed AG to migrate from a standalone instance](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/distributed-availability-group-migrate-standalone-instance)
- [Use distributed AG to migrate an availability group](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/distributed-availability-group-migrate-availability-group)
- [Distributed AG prerequisites](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/distributed-availability-group-prerequisites)
- [Complete migration using a distributed AG](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/distributed-availability-group-migrate-complete)
- [Configure DAG (manual seeding tab)](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-distributed-availability-groups)

### Otros métodos oficiales
- [Azure DMS online — SQL Server → SQL Server VM tutorial](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/database-migration-service-online)
- [SSMS Migration Component (upgrade SQL Server)](https://learn.microsoft.com/ssms/migrate/upgrade-sql-server)
- [Azure Site Recovery — Move SQL VM to another region](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/move-sql-vm-different-region)
- [Azure Arc-enabled SQL Server migration to Azure VMs (preview)](https://learn.microsoft.com/sql/sql-server/azure-arc/migrate-to-sql-server-on-azure-vms)
- [SQL Server backup to URL](https://learn.microsoft.com/sql/relational-databases/backup-restore/sql-server-backup-to-url)

### Soporte y compat
- [Supported version and edition upgrades (SQL Server 2022)](https://learn.microsoft.com/sql/database-engine/install-windows/supported-version-and-edition-upgrades-2022)
- [Issues when upgrading to SQL Server 2022](https://learn.microsoft.com/troubleshoot/sql/database-engine/install/windows/issues-upgrading-sql-server-2022)
- [Manage metadata when making a database available on another server](https://learn.microsoft.com/sql/relational-databases/databases/manage-metadata-when-making-a-database-available-on-another-server)
