# Migración de la topología real del cliente (3 AG + 2 standalone) a Spain Central

> **Propósito**: documentar en detalle (a) lo que ya montamos y validamos en la POC, y
> (b) cómo migrar la topología real del cliente —**8 máquinas** en North Europe: 3
> Availability Groups (AG-A, AG-B, AG-C) con HA local + 2 standalone (vm-sa-log, vm-sa-rpt)— a nuevas
> máquinas SQL Server 2022 en Spain Central.

> ⚠️ **Nivel de confianza de este documento**:
> - **Parte A (lo montado)**: hechos reales de la POC. Alta confianza.
> - **Parte B (topología origen)**: inventario confirmado por diagrama de arquitectura del
>   cliente (8 VMs, SKUs, discos). Faltan por confirmar: BDs por AG y el mecanismo de copia
>   entre AGs (❓).
> - **Partes C-G (estrategia y runbook)**: diseño basado en el patrón DAG ya documentado
>   en este módulo. Los pasos marcados **[VALIDAR]** deben probarse en un entorno de test
>   antes de producción.

---

## Parte A — Lo que ya montamos y validamos (POC real)

Montamos el patrón base (SQL 2017 France Central → SQL 2022 Spain Central) con una BD
demo, para validar la mecánica antes de aplicarla a la topología real. Esto **funcionó**:

| Componente | Resultado |
|---|---|
| Infra Spain Central (RG, VNet 10.30.0.0/16, subnet, NSG 5022) | ✅ |
| Peering France Central ↔ Spain Central (bidireccional, Connected) | ✅ |
| VM SQL Server 2022 (Marketplace, CU25) con Always On | ✅ (con fixes) |
| Discos data/log + carpetas + firewall 5022 | ✅ |
| Master key + certificado `SpainCCert` + endpoint `Hadr_endpoint` (TCP 5022) | ✅ |
| Cert exchange bidireccional (`MILinkCert` ↔ `SpainCCert`) + logins + GRANT CONNECT | ✅ |
| Conectividad TCP 5022 France → Spain (`Test-NetConnection` = True) | ✅ |
| BD demo `MigPocDb` con datos de ejemplo | ✅ |
| **Seeding manual (BACKUP/RESTORE)** | ⚠️ bloqueado por policy MCAP → workaround azcopy+MI |

**Fixes reales que tuvimos que aplicar** (documentados en [`troubleshooting.md`](troubleshooting.md) §0):
1. `az vm create --nsg ""` no funciona → escape `'""'` + comprobar `$LASTEXITCODE`.
2. CD-ROM ocupa `D:\` en VMs Windows → moverlo a `Z:\` antes de inicializar discos.
3. `az vm run-command` trunca output a 4096 chars → transferir ficheros con azcopy, no base64.
4. Sub MCAP prohíbe shared-key en Storage → `--auth-mode login` + user-delegation SAS.
5. User-delegation SAS caduca a <7 días → cap a 6 días.
6. Imagen Marketplace SQL: solo `sa` sysadmin (deshabilitado) → single-user mode + añadir
   `NT AUTHORITY\SYSTEM` y `BUILTIN\Administrators`.
7. **SQL Server 2017 NO soporta user-delegation SAS** para `BACKUP TO URL` → azcopy + Managed
   Identity como transporte del `.bak`.

Estos mismos fixes aplican a la migración real (son del entorno, no del escenario).

---

## Parte B — La topología real de origen (North Europe / Ireland)

Inventario confirmado por diagrama de arquitectura del cliente. **8 máquinas** en
`vnet-origen-prod` (10.10.0.0/16), subnet `snet-data` (10.10.10.0/24), región **North Europe
(Ireland)**.

### Inventario de VMs

| Rol | VM | SKU | vCPU / RAM | Discos (Premium) | Datos aprox |
|---|---|---|---|---|---|
| **AG-A** primary | `vm-aga-01` | D48s_v3 | 48 / 192 GB | 4×P40 + 1×P20 | ~8,5 TB prov |
| **AG-A** secondary (sync) | `vm-aga-02` | D48s_v3 | 48 / 192 GB | 4×P40 + 1×P20 | ~8,5 TB prov |
| **AG-B** primary | `vm-agb-01` | D48s_v3 | 48 / 192 GB | 2×P40 + 1×P30 | ~5 TB prov |
| **AG-B** secondary (sync) | `vm-agb-02` | D48s_v3 | 48 / 192 GB | 2×P40 + 1×P30 | ~5 TB prov |
| **AG-C** primary | `vm-agc-01` | DS14_v2 | 16 / 112 GB | 2×P30 + 1×P20 | ~2,5 TB prov |
| **AG-C** secondary (sync) | `vm-agc-02` | DS14_v2 | 16 / 112 GB | 2×P30 + 1×P20 | ~2,5 TB prov |
| **Standalone (SPOF)** | `vm-sa-log` | DS3_v2 | 4 / 14 GB | 2×P30 + 1×P20 | ~1,15 TB usado |
| **Standalone (SPOF)** | `vm-sa-rpt` | DS12_v2 | 4 / 28 GB | 1×P20 | ~0,25 TB usado |

> P40 = 2 TB, P30 = 1 TB, P20 = 512 GB (tamaños de disco Azure Premium SSD).

### Diagrama

```
   Azure Region · North Europe (Ireland) · vnet-origen-prod 10.10.0.0/16 · subnet snet-data 10.10.10.0/24

   ┌─ Always On AG · AG-A ──────────────────────────────────────────────┐
   │  vm-aga-01 (PRIMARY, D48s_v3) ◄─ sync ─► vm-aga-02 (SECONDARY)│
   └───────────────────────────────────────────────────────────────────┘
   ┌─ Always On AG · AG-B ──────────────────────────────────────────────┐
   │  vm-agb-01 (PRIMARY, D48s_v3) ◄─ sync ─► vm-agb-02 (SECONDARY)│
   └───────────────────────────────────────────────────────────────────┘
   ┌─ Always On AG · AG-C ─────────────────────────────────────────────┐
   │  vm-agc-01 (PRIMARY, DS14_v2)◄─ sync ─►vm-agc-02 (SECONDARY)│
   └───────────────────────────────────────────────────────────────────┘
   ┌─ Standalone · SIN HA (Single Points of Failure) ──────────────────┐
   │  vm-sa-log (DS3_v2, ~1,15 TB)      vm-sa-rpt (DS12_v2, ~0,25 TB)│
   └───────────────────────────────────────────────────────────────────┘
```

### Observaciones clave

- **3 Availability Groups** (AG-A, AG-B, AG-C), cada uno con HA local (2 nodos, sync commit
  intra-región). → migran con el patrón **DAG nuevo en paralelo** (una por AG).
- **2 standalone SIN HA** (vm-sa-log, vm-sa-rpt). No tienen AG, así que **no** pueden usar DAG
  directamente. Necesitan uno de estos enfoques (ver Parte D §Standalone):
  - crear un AG de un nodo sobre ellas + DAG (método "migrate from standalone instance"), o
  - backup/restore + log shipping con cutover corto.
- **AG-C** (probablemente "Integración") es el candidato a alojar la lógica de **copia de
  tablas entre AG-B y AG-A** ❓. Confirmar con los queries de abajo — decide el orden de cutover.
- Las 2 standalone son **SPOF**: buena oportunidad para, al migrar, **darles HA** en Spain
  (montarlas en un AG) si el cliente quiere eliminar esos puntos únicos de fallo.

### Puntos a confirmar ❓ (con los queries de abajo)

1. **BDs por AG**: qué bases hay en AG-A, AG-B, AG-C respectivamente.
2. **Mecanismo de copia entre AGs** (¿va por AG-C? ¿replicación? ¿ETL/linked server?).
   Crítico para el orden de cutover.
3. **Versión y edición exactas** de cada instancia (2017 CU?, Enterprise/Standard).
4. **Qué contienen vm-sa-log y vm-sa-rpt** (logging / reporting) y su criticidad — decide si se migran
   con AG+DAG o con backup/restore simple.

### Comandos para levantar el inventario exacto (ejecútalos en cada instancia)

```sql
-- En CADA instancia (aga-01, aga-02, agb-01, agb-02, agc-01, agc-02, vm-sa-log, vm-sa-rpt):
SELECT @@SERVERNAME AS server, @@VERSION AS version, SERVERPROPERTY('Edition') AS edition;

-- AGs y DAGs (en los nodos con AG)
SELECT name, is_distributed, cluster_type_desc FROM sys.availability_groups;

-- Réplicas y roles
SELECT ag.name AS ag, ar.replica_server_name, ar.availability_mode_desc,
       ar.failover_mode_desc, ar.seeding_mode_desc, ar.endpoint_url
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id;

-- BDs en cada AG
SELECT ag.name AS ag, adc.database_name
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id
ORDER BY ag.name, adc.database_name;

-- BDs en las standalone (vm-sa-log, vm-sa-rpt)
SELECT name, state_desc, recovery_model_desc,
       CAST(SUM(size)*8/1024/1024 AS DECIMAL(10,1)) AS size_gb
FROM sys.master_files mf JOIN sys.databases d ON d.database_id = mf.database_id
WHERE d.database_id > 4 GROUP BY name, state_desc, recovery_model_desc;

-- Read-only routing configurado
SELECT ag.name AS ag, ar.replica_server_name, ar.read_only_routing_url,
       rl.routing_priority, rr.replica_server_name AS routes_to
FROM sys.availability_read_only_routing_lists rl
JOIN sys.availability_replicas ar ON ar.replica_id = rl.replica_id
JOIN sys.availability_replicas rr ON rr.replica_id = rl.read_only_replica_id
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
ORDER BY ag.name, rl.routing_priority;

-- Replicación (por si la copia entre AGs es transactional/snapshot)
SELECT name, is_published, is_subscribed, is_distributor FROM sys.databases;

-- Linked servers (por si la copia es via linked server / jobs)
SELECT name, product, provider, data_source FROM sys.servers WHERE is_linked = 1;
```

---

## Parte C — Estrategia de migración

### Principio clave (verificado antes en este módulo)

Un mismo Availability Group **puede participar en varios Distributed AGs a la vez**. Esto
nos permite **no tocar** el DAG de producción `DAG_EXISTENTE`: creamos DAGs **nuevos** en
paralelo hacia Spain.

> 📖 Referencia (ya verificada en [`decision-rationale.md`](decision-rationale.md) y
> [`official-microsoft-guidance.md`](official-microsoft-guidance.md)): *"a primary replica
> can participate in different distributed availability groups... you can deploy two
> distributed availability groups from the same availability group"*.

### Topología objetivo en Spain Central (espejo)

```
   ORIGEN (North Europe)                         DESTINO (Spain Central) SQL 2022
   AG-A  (aga-01+aga-02)   ──── DAG_A_MIG ────►  AG-A'  (aga-01'+aga-02')
   AG-B  (agb-01+agb-02)   ──── DAG_B_MIG ────►  AG-B'  (agb-01'+agb-02')
   AG-C (agc-01+02)   ──── DAG_C_MIG ───►  AG-C' (agc-01'+agc-02')

   Standalone vm-sa-log  ──── (AG 1-nodo + DAG)  o (backup/restore) ────► vm-sa-log'
   Standalone vm-sa-rpt  ──── (AG 1-nodo + DAG)  o (backup/restore) ────► vm-sa-rpt'

   Cada DAG_*_MIG es NUEVO y va en paralelo a los DAGs/HA existentes (que NO se tocan
   durante la fase de copia). Tras el cutover se recrea el espejo (HA local + copia
   entre AGs) en Spain.
```

### Fases

1. **Provisionar destino en Spain** (8 VMs espejo: 6 en AG + 2 standalone, o darles HA).
2. **Cert exchange** de cada AG origen con su destino (3 AGs) + las 2 standalone.
3. **Crear AG local** en cada destino 2022 (AG-A', AG-B', AG-C').
4. **Crear DAG nuevo** (DAG_A_MIG, DAG_B_MIG, DAG_C_MIG) en paralelo a lo existente.
5. **Standalone vm-sa-log/vm-sa-rpt**: crear AG de 1 nodo + DAG, o backup/restore (ver §Standalone).
6. **Seeding MANUAL** cross-version (backup/restore vía azcopy+MI por la policy).
7. **Migrar objetos out-of-band** (logins, jobs, **routing lists**, linked servers, y el
   mecanismo de copia entre AGs — probablemente por AG-C).
8. **Cutover ordenado** (respetando la dependencia entre AGs; ver Parte D §7).
9. **Recrear el espejo** (HA local + copia entre AGs) en Spain.
10. **Marcha atrás** disponible durante T+24-72h.

---

## Parte D — Runbook paso a paso

> Los scripts base están en [`../../../scripts/modules/sql2017-to-sql2022/`](../../../scripts/modules/sql2017-to-sql2022/).
> Aquí se indican adaptados a la topología real (3 AGs + 2 standalone). **Ejecutar primero
> en un entorno de test** que replique la topología (aunque sea con 1 nodo por AG).

### Fase 1 — Provisionar destino en Spain Central

Espejo de las 8 máquinas (SKUs y discos del inventario de la Parte B):

```powershell
# Infra (una vez): RG, VNet Spain, subnet, NSG 5022, peering North Europe <-> Spain
.\scripts\modules\sql2017-to-sql2022\01-infra-spain.ps1 -SubId "<sub>"

# 6 VMs en AG (mismo SKU que origen):
#   aga-01', aga-02'  -> D48s_v3, discos 4×P40 + 1×P20
#   agb-01', agb-02'  -> D48s_v3, discos 2×P40 + 1×P30
#   agc-01', agc-02' -> DS14_v2, discos 2×P30 + 1×P20
# 2 standalone:
#   vm-sa-log' -> DS3_v2 (o mejor: subir para darle HA), ~1,15 TB
#   vm-sa-rpt' -> DS12_v2, ~0,25 TB
.\scripts\modules\sql2017-to-sql2022\02-install-sql2022.ps1 `
    -SubId "<sub>" -VmName "vm-aga-01-spain" -VmSize "Standard_D48s_v3" -VmAdminPwd "<pwd>"
# ... repetir para cada VM con su SKU y discos.
```

> ⚠️ **Coste**: 8 VMs (2 de ellas D48s_v3 con ~8,5 TB de disco) durante semanas de copia es
> caro. Considerar: (a) apagar réplicas secundarias destino hasta cerca del cutover, o
> (b) migrar por AG en oleadas (AG-C primero por ser el más pequeño, como piloto).

> 💡 **Oportunidad**: las 2 standalone son SPOF hoy. Al migrar, se les puede dar **HA** en
> Spain montándolas en un AG de 2 nodos. Decisión del cliente (más coste, menos riesgo).

### Fase 2 — Preparar SQL + cert exchange (por cada AG y cada standalone)

```
# En cada VM destino: master key + cert + endpoint 5022 (ajustar memoria/MAXDOP al SKU real)
scripts/.../05-prepare-sql2022.sql

# Cert exchange por AG (origen primary <-> destino):
scripts/.../06-cert-exchange.ps1 -VmNE vm-aga-01 -VmSC vm-aga-01-spain ...
scripts/.../06-cert-exchange.ps1 -VmNE vm-agb-01 -VmSC vm-agb-01-spain ...
scripts/.../06-cert-exchange.ps1 -VmNE vm-agc-01 -VmSC vm-agc-01-spain ...
# + las 2 standalone (vm-sa-log, vm-sa-rpt) con su destino
```

> **TDE**: en healthcare es muy probable que haya BDs con TDE. Ejecutar
> `07-migrate-tde-cert.ps1` **antes** del seeding en cada destino afectado, o el restore
> falla con "Cannot find server certificate". Ver [`out-of-band-objects.md`](out-of-band-objects.md) §6.

### Fase 3 — AG local en cada destino

```sql
-- En vm-agb-01-spain: crear AG local (equivalente a 12-create-local-ag-spainc.sql)
-- En vm-aga-01-spain: idem
-- Recordar: GRANT CREATE ANY DATABASE en el AG destino (necesario para seeding).
```

### Fase 4 — Crear DAG nuevo en paralelo (PA→PA' y FA→FA')

> **[VALIDAR]** Este es el paso más delicado: crear un DAG nuevo **desde el AG existente**
> `AG_ORIGEN_A` hacia el AG destino, **sin tocar** `DAG_EXISTENTE`. El AG origen participará
> en 2 DAGs a la vez.

```sql
-- En el primario del AG origen A (agb-01):
CREATE AVAILABILITY GROUP [DAG_PA_MIG]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
    N'AG_ORIGEN_A' WITH (
        LISTENER_URL = N'TCP://<listener-o-fqdn-AG-B>:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = MANUAL          -- OBLIGATORIO cross-version 2017->2022
    ),
    N'<AG_PAN_Spain>' WITH (
        LISTENER_URL = N'TCP://<fqdn-vm-agb-01-spain>:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = MANUAL
    );
GO
-- Repetir análogo para los otros 2 AGs:
--   DAG_A_MIG  entre vm-aga-01 (AG-A)  y su AG destino en Spain.
--   DAG_C_MIG entre vm-agc-01 (AG-C) y su AG destino en Spain.
```

### Fase 4b — Standalone (vm-sa-log, vm-sa-rpt): no tienen AG

Las 2 standalone no pueden usar DAG directamente. Dos opciones:

**Opción 1 — AG de 1 nodo + DAG (downtime de segundos, igual que los AGs):**
```sql
-- En vm-sa-log (y vm-sa-rpt): crear un AG local de un solo nodo (clusterless), luego DAG a Spain.
-- Es el método oficial "migrate from a standalone instance" (script 09 del módulo adaptado).
-- Requiere que la BD esté en FULL recovery.
CREATE AVAILABILITY GROUP [AG_SALOG_MIG]
WITH (CLUSTER_TYPE = NONE, FAILOVER_MODE = MANUAL)
FOR DATABASE [<db>]
REPLICA ON N'vm-sa-log' WITH (
    ENDPOINT_URL = N'TCP://vm-sa-log:5022',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL,
    SEEDING_MODE = MANUAL, SECONDARY_ROLE(ALLOW_CONNECTIONS = NO));
-- luego DAG_SALOG_MIG hacia vm-sa-log' en Spain (igual patrón).
```

**Opción 2 — Backup/restore + log shipping (cutover de minutos):**
- Más simple, sin AG. Backup full + logs periódicos → restore en vm-sa-log'/vm-sa-rpt'.
- Cutover: último tail-log + restore + recovery + repoint. Ventana de minutos.
- Aceptable si vm-sa-log/vm-sa-rpt no son críticas 24/7 (revisar qué contienen: logging / reporting).

> 💡 Como hoy son **SPOF**, es buena ocasión para darles HA en Spain (montarlas en un AG de
> 2 nodos). Decisión del cliente.

### Fase 5 — Seeding MANUAL (por la policy, vía azcopy + Managed Identity)

Cross-version 2017→2022 **exige seeding manual** (error 946 con automático). Y en esta sub
`BACKUP TO URL` está bloqueado desde 2017, así que:

```
Por cada BD de cada AG (AG-A, AG-B, AG-C) y cada standalone:
 1. BACKUP DATABASE + BACKUP LOG a disco local en el primario origen.
 2. azcopy (con Managed Identity) sube el .bak/.trn a un Storage.
 3. azcopy (con Managed Identity) baja a la VM destino.
 4. RESTORE DATABASE ... WITH NORECOVERY + RESTORE LOG ... WITH NORECOVERY.
 5. ALTER DATABASE ... SET HADR AVAILABILITY GROUP = <AG destino>.
```

> ⚠️ **Volumen real grande** (AG-A ~8,5 TB, AG-B ~5 TB por nodo). El seeding inicial de varios
> TB puede tardar **horas o días**. Automatizar en bucle por BD, con backup comprimido y
> striped. **[VALIDAR]** los tiempos con una BD grande real antes de planificar la ventana.
> No es downtime (la app sigue en North Europe), pero condiciona el calendario.

### Fase 6 — Objetos out-of-band (¡incluye routing lists!)

Migrar a cada destino (ver [`out-of-band-objects.md`](out-of-band-objects.md)):
- Logins con SIDs (`sp_help_revlogin` o dbatools).
- SQL Agent jobs (deshabilitados hasta el cutover).
- **Read-only routing lists** — recrearlas en el destino con los nombres de las VMs de Spain.
- Linked servers.
- **El mecanismo de copia entre AGs** ❓ (probablemente por AG-C; replicación / ETL / jobs)
  — recrearlo en Spain.

### Fase 7 — Cutover ordenado

> **[VALIDAR]** El orden depende de las dependencias entre AGs y de qué hace AG-C. Regla
> general: migrar **en la misma ventana coordinada** los AGs que se copian datos entre sí, o
> respetar el orden origen→destino de la copia, para no romperla a mitad. **AG-C es buen
> candidato a piloto** (el más pequeño) para validar el procedimiento antes de AG-A/AG-B.

Por cada AG (ver protocolo completo en [`cutover-plan.md`](cutover-plan.md)):
1. Drain de escrituras en el AG origen.
2. Esperar a que el DAG de migración vacíe la cola (`log_send_queue_size = 0`,
   `redo_queue_size = 0`) y los LSN coincidan. **En asíncrono** (no hace falta síncrono).
3. `FORCE_FAILOVER_ALLOW_DATA_LOSS` del DAG de migración hacia Spain (sin pérdida porque ya
   está verificado).
4. Reapuntar apps (escritura **y** lectura) al destino — alias DNS o connection string.
5. Habilitar jobs en destino, deshabilitar en origen.

### Fase 8 — Recrear el espejo en Spain

Tras el cutover de los 3 AGs + standalone:
- Recrear el/los DAG(s) que enlazaban los AGs en origen, ahora entre los AGs de Spain.
- Recrear la copia de tablas entre AGs ❓ (por AG-C) con los nuevos nombres.
- Validar routing read-only en los 3 AGs.
- Si se decidió dar HA a vm-sa-log/vm-sa-rpt, montar sus AGs de 2 nodos.

---

## Parte E — Marcha atrás

- El AG origen (France) **se queda intacto** con su routing list durante T+24-72h.
- Si algo va mal, se reapuntan las apps (escritura **y** lectura juntas) al origen.
- **No hay failback automático** por el DAG (2017 es versión menor); es "reapuntar al
  origen", perdiendo lo escrito en Spain desde el cutover (recuperable manualmente si es poco).
- Capas de backup (pre-cutover .bak + snapshot VM) como red adicional. Ver
  [`rollback-plan.md`](rollback-plan.md).

> ⚠️ **El punto que te preocupaba (routing list)**: el routing del origen **no se toca**, así
> que la vuelta es limpia en cuanto a routing. Lo único crítico es mover lectura y escritura
> **a la vez** en ambos sentidos.

---

## Parte F — Cómo probarlo (entorno de test)

Para validar sin tocar producción ni gastar de más:

1. **Test reducido**: 1 nodo por lado (AG-B'+AG-A' single-replica) con 2-3 BDs pequeñas que
   imiten la relación PA→FA. Suficiente para validar el flujo DAG-nuevo-en-paralelo + seeding
   + cutover ordenado.
2. **Test fiel**: espejo con 2 nodos por lado (4 VMs) si se quiere validar HA local + routing.
   Más caro; hacerlo solo antes del go-live real.

La POC ya validó el 60% (infra, cert, conectividad, prepare). Falta validar en test:
seeding en bucle multi-BD, DAG nuevo en paralelo, y el cutover ordenado de 2 AGs.

---

## Parte G — Preguntas abiertas / a validar con el equipo de SQL

1. Confirmar BDs por AG (AG-A, AG-B, AG-C) y contenido de las standalone (vm-sa-log, vm-sa-rpt) con los
   queries de la Parte B.
2. Identificar el mecanismo de copia de datos **entre AGs** (¿lo hace AG-C? ¿replicación?
   ¿ETL/linked server?) — decide el orden de cutover.
3. ¿Destino con HA local (2 nodos por AG, espejo exacto) o single-replica en la primera fase?
   ¿Y a las standalone vm-sa-log/vm-sa-rpt se les da HA en Spain (hoy son SPOF)?
4. **[VALIDAR]** que un AG origen participando en 2 DAGs (los existentes + el de migración)
   no afecta a la HA/replicación de producción durante la copia.
5. Confirmar ediciones/versiones exactas de las 8 instancias (edición debe soportar AG).
6. Ventana y método de seeding para el volumen real (AG-A ~8,5 TB, AG-B ~5 TB por nodo):
   ¿backup striped comprimido + azcopy? ¿tiempos aceptables?
7. Sobre la policy MCAP + SQL 2017 (esto es de mi entorno de pruebas; en el del cliente hay
   que revisar SUS policies): ¿`BACKUP TO URL` funciona en su sub, o hace falta el workaround
   azcopy+MI / Azure Files / excepción de policy?
8. Orden de oleadas: ¿empezamos por AG-C (el más pequeño) como piloto y luego AG-A/AG-B?

---

## Referencias internas del módulo
- [`architecture.md`](architecture.md) — diseño del DAG cross-region + cert auth + seeding manual
- [`official-microsoft-guidance.md`](official-microsoft-guidance.md) — citas oficiales verificadas
- [`cutover-plan.md`](cutover-plan.md) — protocolo de cutover en asíncrono
- [`rollback-plan.md`](rollback-plan.md) — marcha atrás por capas
- [`out-of-band-objects.md`](out-of-band-objects.md) — logins, jobs, routing, linked servers
- [`troubleshooting.md`](troubleshooting.md) §0 — los 12 bugs reales de la POC
- [`poc-validation-findings.md`](poc-validation-findings.md) — qué se validó y qué se bloqueó
