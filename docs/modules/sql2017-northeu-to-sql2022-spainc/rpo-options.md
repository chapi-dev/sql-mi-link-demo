# Opciones de RPO para Distributed AG cross-region (SQL 2017 NorthEU → SQL 2022 SpainC)

Tres modos viables, con compromisos muy distintos entre **pérdida potencial de datos**
y **impacto en throughput de escritura**. Este documento existe para que la decisión sea
**basada en datos**, no en la lista de deseos.

> **TL;DR**
>
> | Modo | RPO ante crash | RPO en cutover planificado | Coste de cada write |
> |---|---|---|---|
> | **A) ASYNC commit** | Segundos (típico < 5 s) | **0** con protocolo de drain + wait sync | ~0 (commit local) |
> | **B) SYNC commit cross-region puro** | **0** | **0** | RTT entre regiones (~25-35 ms) por commit |
> | **C) Híbrido SYNC local + ASYNC cross-region** | Segundos a nivel cross-region; 0 local | **0** con protocolo idéntico al modo A | ~0 (sin réplica local sync, el modelo se reduce al A; ver matiz abajo) |
>
> **Recomendación operativa:** modo **A** por defecto. Mover a **B** sólo si el negocio justifica
> el coste de latencia **y** la POC muestra latencia inter-region < 5 ms (raro fuera de
> regiones emparejadas con baja distancia física). El modo **C** sólo aporta si tienes una
> 3ª réplica local en NorthEU como insurance — añade complejidad significativa.

---

## Conceptos base (para que el resto del documento se lea bien)

Antes de las opciones, dos términos que se usan en todo el documento:

- **AG local**: Always On Availability Group dentro de **una sola** región, sobre uno o varios
  nodos (en este módulo, clusterless `CLUSTER_TYPE = NONE`, single-replica por lado).
- **Distributed AG (DAG)**: AG **de AGs**. Enlaza el AG local de NorthEU con el AG local de
  SpainC. Tiene **su propio modo de commit** (SYNC/ASYNC), independiente del de los AGs locales.

**Lo crítico:** el modo SYNC/ASYNC se aplica **al DAG**, no a las réplicas locales. Eso es lo
que controla el RPO inter-region.

Y un dato físico de partida (medirlo en POC, no fiarse):

| Origen ↔ Destino | RTT esperado | RTT P99 | Comentario |
|---|---|---|---|
| North Europe (Dublín) ↔ Spain Central (Madrid) | **~25-35 ms** | ~40-50 ms | Backbone Azure. **A medir empíricamente** con el script de POC. |
| Intra-región (mismo AZ) | < 1 ms | < 2 ms | Para referencia. |
| Intra-región (AZ distintos) | 1-2 ms | 3-5 ms | Para referencia. |

> **Por qué importa el RTT**: en SYNC commit, cada transacción confirmada en el primario
> tiene que **esperar el acuse de recibo del secundario** antes de devolver `COMMIT` al
> cliente. Cada commit paga **un RTT entero**. A 30 ms RTT, un workload OLTP con 1.000 commits/s
> se vuelve inviable.

---

## Opción A — ASYNC commit en el DAG **(recomendado por defecto)**

### Cómo funciona

```
   App ──┐
         │ writes
         ▼
   ┌────────────────────┐       ┌────────────────────┐
   │ Primary (NorthEU)  │       │ Secondary (SpainC) │
   │ SQL 2017           │       │ SQL 2022           │
   │                    │       │                    │
   │ COMMIT devuelve OK │       │ Recibe log records │
   │ tras escribir LDF  │──────►│ asíncronamente     │
   │ local. NO espera   │  log  │ Aplica al LDF      │
   │ al secundario.     │  flow │ local.             │
   └────────────────────┘       └────────────────────┘
```

El primario confirma transacciones contra **su propio log local** y envía el log al
secundario en background. Si el primario cae **antes** de que el log se haya enviado, esas
transacciones se pierden.

### RPO real

| Escenario | RPO |
|---|---|
| **Desastre súbito del primario** (VM crash, región caída) | Segundos (típico < 5 s; ver `redo_queue_size` y `log_send_queue_size` en `sys.dm_hadr_database_replica_states`) |
| **Cutover planificado** con drain + wait LSN sync + planned failover | **0** |
| **Failover forzado** sin drain | Lo que haya en la `log_send_queue` en ese instante |

> **Por qué cutover planificado da RPO 0 incluso en ASYNC**: porque pausas escrituras
> en el primario, esperas a que la cola se vacíe (`log_send_queue_size = 0` y
> `redo_queue_size = 0`), y sólo entonces haces el failover. Cero datos en vuelo, cero
> pérdida. Esto es exactamente el protocolo de [`cutover-plan.md`](cutover-plan.md).

### Ventajas

- **Cero impacto en throughput de escritura.** El commit no paga el RTT.
- **Sin sensibilidad a latencia inter-region.** Funciona bien aunque haya picos de 100 ms.
- **Soportado oficialmente en DAG cross-region** (es el modo recomendado por MS Learn para DR).
- **Tolerante a interrupciones de red**: si SpainC se cae 10 minutos, el primario sigue
  operando; el secundario re-sincroniza al volver (mientras la `log_send_queue` no desborde
  el tamaño del log primario).
- Cutover planificado sigue siendo RPO 0.

### Limitaciones

- **RPO ante crash no planificado del primario ≠ 0.** Si el datacenter de North Europe arde
  *ahora mismo*, pierdes las transacciones en vuelo (típicamente segundos, pero medible).
- **Crítico monitorizar la cola**: si `log_send_queue_size` crece sin control, el RPO real
  crece con ella. Necesita alerting.
- Si el primario sufre corruption mientras el secundario va con lag, esa corruption puede
  no haberse propagado todavía — bueno como insurance pero malo si el lag es de horas
  porque el RTO también crece.

### Cuándo usar este modo

- **OLTP normal de negocio** donde el coste de unos segundos de pérdida en un desastre
  catastrófico **es asumible** frente al coste de latencia 24/7.
- **Workloads write-heavy** (>500 commits/s) donde SYNC cross-region es directamente
  inviable.
- **Cualquier caso donde la app no tiene retry idempotente** — porque añadir latencia a
  cada query es peor que asumir el riesgo bajo de pérdida en disaster.

### Configuración T-SQL clave

```sql
CREATE AVAILABILITY GROUP DAG_Migrate
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
  'AG_NorthEU' WITH (
    LISTENER_URL = 'TCP://<vm-2017-fqdn>:5022',
    AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,   -- ← ASYNC
    FAILOVER_MODE = MANUAL,
    SEEDING_MODE = AUTOMATIC
  ),
  'AG_SpainC' WITH (
    LISTENER_URL = 'TCP://<vm-2022-fqdn>:5022',
    AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,   -- ← ASYNC
    FAILOVER_MODE = MANUAL,
    SEEDING_MODE = AUTOMATIC
  );
```

### Monitorización imprescindible (alerta)

```sql
SELECT
    drs.database_id,
    DB_NAME(drs.database_id)     AS db,
    drs.synchronization_state_desc,
    drs.log_send_queue_size      AS send_queue_kb,
    drs.log_send_rate            AS send_rate_kb_s,
    drs.redo_queue_size          AS redo_queue_kb,
    drs.redo_rate                AS redo_rate_kb_s,
    drs.last_commit_lsn,
    drs.last_commit_time
FROM sys.dm_hadr_database_replica_states drs
WHERE drs.is_local = 0;
```

Umbrales sugeridos (a calibrar con baseline):
- `log_send_queue_size > 50 MB` durante > 5 min → warning.
- `last_commit_time` del secundario lag > 30 s vs primario → critical.

---

## Opción B — SYNC commit cross-region puro

### Cómo funciona

```
   App ──┐
         │ writes
         ▼
   ┌────────────────────┐         ┌────────────────────┐
   │ Primary (NorthEU)  │ ──────► │ Secondary (SpainC) │
   │ SQL 2017           │  log    │ SQL 2022           │
   │                    │         │                    │
   │ COMMIT NO devuelve │ ◄────── │ HARDENED al LDF    │
   │ OK hasta que       │  ACK    │ local. Envía ACK.  │
   │ recibe ACK         │         │                    │
   └────────────────────┘         └────────────────────┘
        │
        ▼
    Cliente recibe OK del COMMIT
```

Cada transacción confirmada espera a que el secundario haya escrito el log a disco.

### RPO real

| Escenario | RPO |
|---|---|
| Desastre súbito del primario | **0** (si SpainC responde antes del crash; en la práctica algunas tx en vuelo pueden quedar en estado in-doubt) |
| Cutover planificado | **0** |
| Pérdida prolongada del secundario | El primario entra en estado `NOT SYNCHRONIZED` y los writes **se bloquean** (o degradan a ASYNC según configuración) |

### Ventajas

- **RPO 0 ante cualquier desastre del primario** (no sólo en cutover planificado).
- Garantía dura de paridad: el secundario está siempre **byte-by-byte sincronizado** con el primario hasta el último ACK.

### Limitaciones

- **Coste por commit = RTT inter-region.** Con ~30 ms RTT NorthEU↔SpainC, cada commit paga
  esos 30 ms. Un workload de:
  - 100 commits/s → throughput cap teórico ~33 commits/s **por conexión single-thread**;
    con paralelismo escala pero la latencia P50 sube a 30+ ms.
  - 1.000 commits/s → cuello de botella severo. Sesiones esperando en `HADR_SYNC_COMMIT`
    aparecerán como top wait.
- **Sensibilidad extrema a la latencia.** Un pico de red de 200 ms se traduce en commits
  de 200 ms para **toda** la aplicación durante ese pico.
- **Pérdida del secundario detiene escrituras** (a menos que se configure failover
  automático a ASYNC, lo cual rompe la garantía de RPO 0).
- En DAG cross-region, **el primario y secundario ya no son intercambiables sin coste** —
  cada commit en el "primario" lógico es lentísimo hasta que cambias la topología.
- Microsoft documenta SYNC commit en DAG como **soportado pero no recomendado** salvo casos
  con baja latencia validada.

### Cuándo usar este modo

- **Workloads write-light** (< 50 commits/s sostenidos) donde la latencia adicional no
  rompe nada.
- **Aplicaciones con SLA contractual de RPO = 0** que no se puede satisfacer con cutover
  planificado (porque el desastre puede ocurrir en cualquier momento).
- **Latencia inter-region medida estable y baja** (< 5 ms; típico sólo en regiones
  emparejadas como WestEU ↔ NorthEU, no NorthEU ↔ SpainC).
- **Sistemas financieros / regulatorios** donde la pérdida de cualquier transacción es
  inaceptable y la app puede absorber la latencia.

### Configuración T-SQL clave

```sql
CREATE AVAILABILITY GROUP DAG_Migrate
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
  'AG_NorthEU' WITH (
    LISTENER_URL = 'TCP://<vm-2017-fqdn>:5022',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,    -- ← SYNC
    FAILOVER_MODE = MANUAL,
    SEEDING_MODE = AUTOMATIC
  ),
  'AG_SpainC' WITH (
    LISTENER_URL = 'TCP://<vm-2022-fqdn>:5022',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,    -- ← SYNC
    FAILOVER_MODE = MANUAL,
    SEEDING_MODE = AUTOMATIC
  );
```

### Antes de elegir este modo: medir

**No actives SYNC cross-region sin haber hecho la POC de latencia.** El script de medición
([`poc-latency-measurement.ps1`](../../../scripts/modules/sql2017-to-sql2022/poc-latency-measurement.ps1),
pendiente) provisiona 2 VMs mínimas en ambas regiones y mide:

- RTT TCP a 5022 (P50, P95, P99) durante 1 hora.
- Estabilidad: % de muestras > 50 ms.
- Throughput sostenido inter-region (iperf).

Decisión orientativa:
- P99 RTT < 10 ms y % muestras > 50 ms < 1% → SYNC viable.
- P99 RTT 10–30 ms → SYNC sólo para workloads write-light.
- P99 RTT > 30 ms o picos frecuentes > 100 ms → SYNC inviable, usar ASYNC.

---

## Opción C — Híbrido: AG local SYNC + DAG cross-region ASYNC

### Cómo funciona

```
       North Europe                                      Spain Central
   ┌─────────────────────────┐                       ┌────────────────────┐
   │ AG_NorthEU              │                       │ AG_SpainC          │
   │                         │                       │                    │
   │ ┌───────┐   ┌───────┐   │  Distributed AG       │ ┌───────┐          │
   │ │Primary│──►│Replica│   │  ASYNC commit         │ │Primary│          │
   │ │SQL2017│   │ local │   │ ─────────────────────►│ │SQL2022│          │
   │ │       │   │SYNC   │   │                       │ │       │          │
   │ └───────┘   └───────┘   │                       │ └───────┘          │
   │                         │                       │                    │
   │ Failover local: RPO=0   │                       │                    │
   └─────────────────────────┘                       └────────────────────┘
```

Dos réplicas en NorthEU (primary + secondary intra-region en SYNC) + DAG ASYNC a la réplica
SpainC.

### RPO real

| Escenario | RPO |
|---|---|
| Crash del primario en NorthEU | **0** (failover local a la réplica SYNC; no toca SpainC) |
| Pérdida total de la región NorthEU | Segundos (queda lo que se haya replicado vía DAG ASYNC a SpainC) |
| Cutover planificado a SpainC | **0** (mismo protocolo que modo A) |

### Ventajas

- **RPO 0 ante fallos locales** (VM, disco, AZ) sin pagar latencia inter-region.
- Mantiene throughput intacto (porque el SYNC es intra-region, sub-ms).
- Útil si el AG local ya existe por otras razones (HA pre-existente que quieres preservar).

### Limitaciones

- **No cambia el RPO inter-region**: si la región NorthEU cae entera, sigues teniendo el RPO
  del modo A.
- **Coste de infra**: VM adicional en NorthEU (la réplica local).
- **Complejidad operativa**: gestionar failover local + failover cross-region son flujos
  distintos.
- **Solo útil durante la migración si vas a mantener la infra de origen activa post-migración**
  (escenario raro en una migración como esta).

### Cuándo usar este modo

- **Sólo si ya tienes** o vas a montar un AG local en NorthEU por razones de HA
  independientes de esta migración.
- **No tiene sentido montarlo expresamente para esta migración** — la migración es
  unidireccional y temporal; la complejidad no se amortiza.

### Veredicto para este módulo

**No recomendado** salvo que el cliente ya tenga AG local en producción que quiera
preservar. En el resto de los casos, el modo **A** es estrictamente mejor para esta
fase específica.

---

## Tabla comparativa final

| Atributo | A) ASYNC | B) SYNC cross-region | C) Híbrido |
|---|---|---|---|
| RPO crash súbito primario | Segundos | 0 | 0 local / Segundos cross-region |
| RPO cutover planificado | **0** | **0** | **0** |
| Coste latencia por commit | 0 | 1 × RTT inter-region (~30 ms) | 1 × RTT intra-region (< 1 ms) |
| Throughput write-heavy | OK | Degradado severamente | OK |
| Sensibilidad a picos red | Baja | **Muy alta** | Baja para escrituras locales |
| Coste infra adicional | 1 VM destino | 1 VM destino | 2 VMs (1 réplica local + destino) |
| Complejidad operativa | Baja | Media | Alta |
| Failover cross-region time | Manual, segundos | Manual, segundos | Manual, segundos |
| Soportado en DAG cross-region | ✅ Recomendado | ✅ Soportado, no recomendado | ✅ |
| **Recomendación módulo** | ✅ **Default** | ⚠️ Sólo con POC + perfil write-light | ⚠️ Sólo si ya hay AG local |

---

## Árbol de decisión

```
¿La app puede absorber pérdida de SEGUNDOS de datos en disaster catastrófico?
│
├── SÍ → Modo A (ASYNC). Fin.
│
└── NO → ¿La latencia P99 inter-region medida es < 10 ms y workload < 50 commits/s sostenidos?
            │
            ├── SÍ → Modo B (SYNC cross-region). Validar con POC de carga antes de prod.
            │
            └── NO → No se puede satisfacer el requisito con esta topología cross-region.
                     Opciones:
                     - Reducir requisito a "RPO 0 en cutover, segundos en disaster"  → Modo A
                     - Cambiar a regiones más cercanas (latencia < 5 ms)              → Modo B
                     - Añadir capa de transactional replication a un MI sync → otro proyecto
```

---

## RPO 0 en cutover planificado (independiente del modo)

**Esto se cumple en los tres modos**, porque el cutover es un protocolo, no una propiedad del modo.

> 📘 **Protocolo oficial MS** ([Distributed AG migration scenarios](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups)):
>
> "To complete the migration to the new configuration, at the end of the process, **stop all
> data traffic to the original availability group, and change the distributed availability
> group to synchronous data movement.** This action ensures that the primary replica of the
> second availability group is fully synchronized, so there would be no data loss. After
> you've verified the synchronization, fail over the distributed availability group to the
> secondary availability group."

### Protocolo recomendado (MS-aligned)

1. **Anuncio**: ventana de mantenimiento comunicada (aunque sea de 30 s).
2. **Drain**: app deja de escribir (feature flag, read-only mode, o stop deliberado).
3. **Cambiar DAG a SYNC commit** (sólo durante la ventana de cutover):
   ```sql
   ALTER AVAILABILITY GROUP [DAG_Migrate]
   MODIFY AVAILABILITY GROUP ON 'AG_SpainC' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
   ```
   Esto **garantiza** que el ACK del secundario ha vuelto para cada commit pendiente.
4. **Esperar estado SYNCHRONIZED** (no sólo `log_send_queue_size = 0`):
   ```sql
   SELECT synchronization_state_desc
   FROM sys.dm_hadr_database_replica_states
   WHERE is_local = 0;
   -- Esperar a que devuelva 'SYNCHRONIZED'
   ```
5. **Quiesce final**: opcional, congelar primario con `ALTER DATABASE ... SET RESTRICTED_USER`.
6. **Verificación final**: `last_hardened_lsn(primary) == last_hardened_lsn(secondary)`.
7. **Planned failover** del DAG hacia SpainC.
8. **App repoint**: cambiar connection string al FQDN del 2022.
9. **Validación smoke**: queries de paridad funcional + perf baseline.
10. **AG NorthEU se queda intacto** como botón de pánico durante T+24h.

> **Por qué el paso 3 es mejor que "wait LSN sync en ASYNC"**: en ASYNC el `last_hardened_lsn`
> puede coincidir por instantes y luego divergir si llega una tx tardía. SYNC garantiza
> **por protocolo** que no hay tx en vuelo sin ACK. Es la diferencia entre "esperar a que
> parezca igualado" y "garantizar igualdad mediante el propio mecanismo del AG".

Protocolo completo y T-SQL en [`cutover-plan.md`](cutover-plan.md).

---

## Referencias

- [Distributed Availability Groups — Microsoft Learn](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups)
- [Cross-cluster migration of AGs in Windows Server — MS Learn](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/cross-cluster-migration-of-always-on-availability-groups-for-os-upgrade)
- [HADR_SYNC_COMMIT wait type](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql)
- [sys.dm_hadr_database_replica_states](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-hadr-database-replica-states-transact-sql)
- [Azure region pairs — NorthEU/Spain Central considerations](https://learn.microsoft.com/azure/reliability/cross-region-replication-azure)
