# Por qué Distributed AG (y no otras alternativas)

Este módulo usa **Distributed Availability Group cross-region clusterless** para mover la BD
de SQL Server 2017 (NorthEU) a SQL Server 2022 (SpainC). Hay otras formas técnicamente
viables — este documento explica **por qué se descartaron** y **en qué casos sí elegirías
otra**.

> Si ya tienes la decisión tomada y sólo quieres ejecutar, lee directamente
> [`architecture.md`](architecture.md) y [`runbook.md`](runbook.md). Este doc es para defender
> el diseño en una revisión técnica.

---

## Criterios de evaluación

Las alternativas se valoran contra **estos cinco requisitos** (los de este módulo):

| # | Requisito | Tipo |
|---|---|---|
| R1 | RPO 0 en cutover planificado | Duro |
| R2 | Sin cortar servicio (app reconecta en segundos, no minutos) | Duro |
| R3 | Cross-region (NorthEU → SpainC) | Duro |
| R4 | Cross-version (2017 → 2022) | Duro |
| R5 | Rollback realista en T+24h post-cutover | Duro |

Y estos cuatro **deseables**:

| # | Deseable |
|---|---|
| D1 | Setup reproducible en script (sin GUI) |
| D2 | Mínima infra incremental (no agentes adicionales, no servicios PaaS extra) |
| D3 | Conocimiento ya presente en el repo (operacionalmente coherente con el patrón MI Link) |
| D4 | Soportado por MS para upgrade cross-version |

---

## Alternativa 1 — Distributed AG cross-region ✅ (la elegida)

### Descripción
AG local single-replica en cada región + DAG ASYNC entre ambos. Patrón idéntico al que
usa MI Link en este repo, sustituyendo el "AG lógico de MI" por un "AG real en otra VM SQL".

### Cómo cumple los requisitos

| Req | Cumple | Detalle |
|---|---|---|
| R1 RPO 0 cutover | ✅ | Protocolo de drain + wait LSN. Modo ASYNC default; SYNC opcional. |
| R2 No downtime | ✅ | Planned failover en segundos. App reconecta. |
| R3 Cross-region | ✅ | Diseñado para esto. Cert auth, no necesita dominio común. |
| R4 Cross-version | ✅ | 2017→2022 forward compat, soportado oficialmente. |
| R5 Rollback T+24h | ⚠️ | DAG no permite failback (versión asimétrica). Rollback por capas externas. **Aceptable**. |

### Pros
- Coherente con el resto del repo (mismo patrón mental).
- Sin agentes ni servicios PaaS adicionales.
- Soporte oficial MS para upgrade cross-version.
- Failover **manual y deliberado** — no hay magia automática que pueda fallar.

### Contras
- Failback post-cutover requiere capas externas (es por diseño del DAG cross-version).
- Hay que entender bien la diferencia AG local vs DAG vs failover modes — curva de
  aprendizaje no trivial.

### Veredicto
✅ **Elegida**. Cumple todos los requisitos duros, sólo R5 con asterisco que se mitiga
en [`rollback-plan.md`](rollback-plan.md).

---

## Alternativa 2 — AG directo cross-region (un solo AG, 2 réplicas)

### Descripción
Un único AG con réplica primaria en NorthEU y secundaria en SpainC. Sin DAG, sin AGs
locales separados.

### Por qué se descarta

| Req | Cumple | Detalle |
|---|---|---|
| R1 RPO 0 | ✅ | Igual que el DAG (mismo protocolo de cutover). |
| R2 No downtime | ✅ | Failover idem. |
| R3 Cross-region | ✅ | Posible. |
| R4 Cross-version | ⚠️ | Soportado para upgrade window — pero el **listener cross-region requiere multi-subnet failover** y la app necesita driver compatible. Más complejidad. |
| R5 Rollback | ❌ | **Failback directo está sujeto al mismo problema de forward-only**. Sin DAG no tienes la capa de aislamiento donde decidir "rompo el DAG y dejo el AG local intacto post-cutover". |

### Comparado con DAG
- El DAG **te da una capa extra de aislamiento**: puedes dejar el AG local de NorthEU
  intacto después del cutover (sólo retiras la membresía del DAG), lo que mantiene la
  BD primaria operativa en 2017 como botón de pánico instantáneo.
- En un AG directo, la BD del 2017 pasa a ser secundaria del 2022 inmediatamente al
  fallover — y por la forward-only compat queda **rota** (`RESOLVING` o `NOT
  SYNCHRONIZING/RECOVERY_PENDING`). Se complica el rollback.

### Veredicto
❌ Descartada. Cumple los requisitos duros pero **complica el rollback** sin aportar
beneficio frente al DAG.

---

## Alternativa 3 — Log Shipping

### Descripción
Backup periódico de log en NorthEU + restore (NORECOVERY) en SpainC. Job de SQL Agent
en ambos lados orquestando.

### Por qué se descarta

| Req | Cumple | Detalle |
|---|---|---|
| R1 RPO 0 | ❌ | RPO mínimo = intervalo de log shipping (típicamente 5-15 min). En el cutover hay que aplicar el último tail-log manualmente; manejable pero **NO es zero loss automático**. |
| R2 No downtime | ⚠️ | Cutover requiere parar app, hacer tail-log backup, restore, app repoint. **Minutos**, no segundos. |
| R3 Cross-region | ✅ | El share/blob intermedio funciona. |
| R4 Cross-version | ✅ | Soporta upgrade 2017→2022. |
| R5 Rollback | ✅ | **El primario sigue intacto**. Es de hecho su mayor ventaja. |

### Pros
- Robusto, viejo y conocido.
- Primario nunca se compromete.
- Sin certificados ni endpoints — sólo backups y restores.

### Contras
- **Rompe R1 (RPO 0)** salvo que se haga tail-log + restore manual en el cutover,
  proceso de minutos no segundos.
- **Rompe R2 (no downtime)** porque la ventana de cutover es minutos.
- Operacionalmente diferente al patrón MI Link de este repo — añade otro patrón mental.

### Cuándo SÍ elegirías log shipping
- BD muy grande con red intermitente entre regiones.
- Requisito de RPO laxo (minutos, no segundos).
- Equipo más cómodo con backup/restore que con AGs.

### Veredicto
❌ Descartada. Rompe R1 y R2.

---

## Alternativa 4 — Transactional Replication

### Descripción
Configurar publicación en NorthEU y suscripción push/pull a SpainC. Cada transacción se
replica como comando individual.

### Por qué se descarta

| Req | Cumple | Detalle |
|---|---|---|
| R1 RPO 0 | ❌ | RPO de segundos en estado normal, pero el cutover **no es seamless** — requiere reconfiguración y la suscripción no es failover-aware. |
| R2 No downtime | ❌ | El cutover implica re-apuntar publicador/suscriptor — minutos al menos. |
| R3 Cross-region | ✅ | Posible. |
| R4 Cross-version | ✅ | Soporta 2017→2022. |
| R5 Rollback | ✅ | Bidireccional fácil (peer-to-peer transactional). |

### Pros
- Bidireccional nativo (al contrario que el DAG).
- Granularidad por tabla (puedes replicar sólo lo necesario).

### Contras
- **Schema constraints**: no soporta ciertos features (TDE en algunas configs, certain
  data types, `XML`/`varbinary(max)` con tamaños grandes — depende).
- **Operacionalmente complejo**: agentes (snapshot, log reader, distribution), distribuidor
  separado, troubleshooting peculiar.
- **El cutover no es transparente** — la app conecta a un publicador o a un suscriptor y
  cambiar requiere coordinación.
- **No replica DDL** out of the box en todos los escenarios.

### Cuándo SÍ elegirías replicación transaccional
- Migración **selectiva** de un subset de tablas.
- Necesitas bidireccionalidad continua post-migración (escenario raro).
- La BD tiene patrones de uso que el AG no soporta bien (raros).

### Veredicto
❌ Descartada. Rompe R1 y R2, complejidad operativa alta.

---

## Alternativa 5 — Backup + Restore con tail-log

### Descripción
1. Backup full de NorthEU → Blob.
2. Restore (`NORECOVERY`) en SpainC.
3. Backups de log periódicos durante una ventana.
4. En el cutover: stop app, tail-log backup, restore final, `WITH RECOVERY`, repoint app.

### Por qué se descarta

| Req | Cumple | Detalle |
|---|---|---|
| R1 RPO 0 | ⚠️ | **Sí**, si el tail-log se hace bien. Pero **bajo presión humana, no automatizado**. |
| R2 No downtime | ❌ | Cutover = stop app, tail-log, restore, recovery, repoint. **5-30 minutos típicos**. |
| R3 Cross-region | ✅ | Blob intermedio. |
| R4 Cross-version | ✅ | Forward compat. |
| R5 Rollback | ✅ | Primario intacto. |

### Pros
- Lo más simple conceptualmente.
- Lo más robusto (cero state distribuido).
- Ya hay un script en el repo para esto en el contexto POC ([`05-pre-cutover-backup.sql`](../../../scripts/05-pre-cutover-backup.sql)).

### Contras
- **Cutover de minutos**, no segundos. Rompe R2.
- Operación crítica humana (el tail-log puede salir mal con presión).

### Cuándo SÍ elegirías este enfoque
- Migración con ventana de mantenimiento aceptable (típico fin de semana).
- BD pequeña/mediana donde el restore tarda minutos.
- Cero tolerancia a complejidad de AG cross-region.

### Veredicto
❌ Descartada como método principal. **Sí se usa como capa de rollback** (Capa 1 del
plan, ver [`rollback-plan.md`](rollback-plan.md)).

---

## Alternativa 6 — Azure Database Migration Service (DMS) online

### Descripción
Servicio PaaS que orquesta migraciones SQL Server a SQL MI / SQL DB / SQL Server VM.
**Sí soportado oficialmente para SQL Server → SQL Server VM** con tutorial dedicado:
[Tutorial: Migrate SQL Server to SQL Server on an Azure VM with Azure DMS (online)](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/database-migration-service-online).

### Cómo funciona
1. Backup full y log de NorthEU a network share o directamente a Blob.
2. **Self-Hosted Integration Runtime** (SHIR) lee los backups y los sube/orquesta.
3. DMS hace **restore continuo** en SpainC en background.
4. Cuando llega el cutover: el operador hace último log backup, DMS lo restaura, y
   completa con `WITH RECOVERY`.

### Por qué se descarta para nuestro caso

| Req | Cumple | Detalle |
|---|---|---|
| R1 RPO 0 | ✅ | El último tail-log antes del cutover garantiza zero loss. |
| R2 No downtime | ⚠️ | Cutover real: stop app, tail-log, esperar restore, recovery, repoint. **Minutos**, no segundos. |
| R3 Cross-region | ✅ | Blob accesible desde ambos sitios. |
| R4 Cross-version | ✅ | Soporta 2017→2022. |
| R5 Rollback | ✅ | NorthEU intacto. |

### Pros
- **Servicio gestionado** — menos T-SQL manual, UI en portal Azure.
- Migración de logins integrada (parcial — Windows logins requieren ajustes manuales).
- Buen monitoring nativo (estado de cada BD en portal).
- Útil cuando no tienes acceso para crear AGs/endpoints en origen.

### Contras
- **Cutover real son minutos** — no segundos como con DAG (rompe R2 estricto).
- Añade **3 recursos PaaS** adicionales: DMS instance + Azure Data Factory + SHIR.
- SHIR requiere una VM/server extra en NorthEU con conectividad outbound a DMS.
- **Operacionalmente diferente** al patrón MI Link del repo — añade otro modelo mental.
- Coste mensual: DMS Premium SKU (~$300/mes mientras está activo) + Data Factory.

### Cuándo SÍ elegirías DMS
- Migración **única, no recurrente** (este patrón no se repite).
- Equipo **no familiarizado con AGs**, prefiere UI guiada.
- **No tienes permisos** para crear AGs en el origen (escenarios outsourced).
- **Ventana de mantenimiento de minutos** es aceptable.

### Veredicto
❌ Descartada para nuestro caso. Soporta cross-version y cross-region, pero el cutover
de minutos rompe R2 estricto. **El equipo de este repo además ya conoce el patrón DAG**
por el módulo MI Link existente (D3 deseable).

---

## Alternativa 7 — Azure Site Recovery (ASR)

### Descripción
Servicio de DR que replica VMs Azure entre regiones a nivel de disco.

### Por qué se descarta

| Req | Cumple | Detalle |
|---|---|---|
| R1 RPO 0 | ❌ | ASR es **crash-consistent**, no app-consistent. RPO de segundos a minutos. |
| R4 Cross-version | ❌ | Replica la VM, **no hace upgrade**. La VM destino seguiría siendo SQL 2017. |

### Veredicto
❌ Descartada. **No hace upgrade de versión** — fuera de scope para este módulo.

---

## Alternativa 8 — SSMS Migration Component (nuevo en SSMS 21+)

### Descripción
Componente integrado en SSMS 21+ (workload "Hybrid and Migration") que combina:
- Upgrade assessment (compatibility, breaking changes, deprecated features)
- Migración física por backup-copy-restore desde GUI
- **Migración de logins automática** (SQL y Windows logins)

Doc oficial: [Upgrade SQL Server using the migration component in SSMS](https://learn.microsoft.com/ssms/migrate/upgrade-sql-server).

### Por qué se descarta

| Req | Cumple | Detalle |
|---|---|---|
| R1 RPO 0 | ⚠️ | Sólo si se hace stop app + último backup tras stop. Bajo presión humana, no automático. |
| R2 No downtime | ❌ | Cutover = backup → copy → restore final. **Minutos**, no segundos. |
| R3 Cross-region | ⚠️ | Requiere **network share accesible desde ambas instancias**, lo cual cross-region es no trivial. |
| R4 Cross-version | ✅ | Es su caso de uso principal. |
| R5 Rollback | ✅ | Origen intacto. |

### Pros
- **Logins migrados con un clic** — incluye Windows logins.
- Assessment + migración en el mismo wizard.
- GUI sólida, buen feedback visual.
- Útil para upgrades cross-machine en el mismo sitio.

### Contras
- **GUI-driven**: no encaja con un repo infra-as-code. Rompe D1.
- **Network shares cross-region en Azure son complicadas** (rompe R3 limpio).
- **No soporta FILESTREAM** databases.
- Operacionalmente única — no se repite, no se script-ea fácilmente.
- Cutover de minutos.

### Cuándo SÍ elegirías este componente
- Migración **single-shot** cross-machine, mismo sitio o mismo VNet.
- Equipo familiarizado con SSMS, no con T-SQL/AG.
- Origen sin AG montado y sin posibilidad de montarlo.
- Logins masivos a migrar y se valora el wizard que los hace.

### Veredicto
❌ Descartada. GUI no encaja con el repo. R3 cross-region no se cubre bien con shares
de red.

---

## Alternativa 9 — Azure Arc-enabled SQL Server migration to Azure VMs (preview)

### Descripción
Servicio nuevo en preview ([doc oficial](https://learn.microsoft.com/sql/sql-server/azure-arc/migrate-to-sql-server-on-azure-vms))
para migrar SQL Server gestionado vía Azure Arc hacia SQL Server on Azure VM.

### Por qué se descarta

| Req | Cumple | Detalle |
|---|---|---|
| R1-R5 | N/A | **Requiere origen Arc-enabled**. Nuestro origen es una VM Azure ya, no on-prem Arc-enabled. |

### Veredicto
❌ Descartada. Caso de uso distinto. Mencionado por completitud — si el origen fuera
on-prem con Arc, sería opción a evaluar.

---

## Tabla comparativa final

| Alternativa | R1 RPO0 | R2 Down=0 | R3 X-region | R4 X-version | R5 Rollback | Veredicto |
|---|---|---|---|---|---|---|
| **DAG cross-region** | ✅ | ✅ | ✅ | ✅ (seeding MANUAL) | ⚠️ (capas externas) | ✅ **Elegida** |
| AG directo cross-region | ✅ | ✅ | ✅ | ⚠️ | ❌ | Descartada (rollback) |
| Log Shipping | ❌ | ⚠️ | ✅ | ✅ | ✅ | Descartada (RPO+downtime) |
| Replicación transaccional | ❌ | ❌ | ✅ | ✅ | ✅ | Descartada (cutover) |
| Backup + restore | ⚠️ | ❌ | ✅ | ✅ | ✅ | Descartada (downtime); **usada como capa rollback** |
| **DMS online (oficial)** | ✅ | ⚠️ (min) | ✅ | ✅ | ✅ | Descartada (cutover min); ✅ válida si R2 no es estricto |
| ASR | ❌ | — | ✅ | ❌ | — | Descartada (no upgrade) |
| **SSMS Migration Component** | ⚠️ | ❌ | ⚠️ | ✅ | ✅ | Descartada (GUI + share x-region) |
| **Arc migration to Azure VMs (preview)** | N/A | N/A | N/A | N/A | N/A | N/A (origen no Arc) |

> **Cambio respecto a la primera versión de este doc**: Tras revisar la documentación
> oficial MS, **DMS online sube de "no soportado bien" a "soportado oficialmente pero
> cutover de minutos"**. Si el cliente acepta una ventana de cutover de 5-15 min, DMS es
> una alternativa válida y más sencilla operativamente que el DAG. Fuente:
> [official-microsoft-guidance.md](official-microsoft-guidance.md) y
> [tutorial DMS oficial](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/database-migration-service-online).

---

## Por qué este patrón también funciona para la fase siguiente (2022 → MI)

Una vez en SpainC con SQL 2022, ir a MI puede usar **el mismo patrón mental**:

- Si el MI está en la misma región (SpainC) o paired, MI Link bidireccional con update
  policy *SQL Server 2022* funciona y permite failback.
- El equipo ya entiende AGs locales + DAG por haber hecho esta fase — el aprendizaje
  se reutiliza.
- El rollback de la fase MI puede ser más limpio (failback nativo del Link) en vez de
  las 4 capas externas.

**Conclusión estratégica**: la fase de upgrade a 2022 no es sólo "necesaria para llegar
a MI"; también **es la práctica perfecta del patrón** que luego se usará para MI con
mucho menos riesgo.

---

## Referencias

- [DAG vs other replication options — MS Learn](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups)
- [SQL Server upgrade options](https://learn.microsoft.com/sql/database-engine/install-windows/upgrade-database-engine)
- [Azure DMS supported scenarios](https://learn.microsoft.com/azure/dms/dms-overview)
- [Azure Site Recovery for Azure VMs](https://learn.microsoft.com/azure/site-recovery/azure-to-azure-architecture)
