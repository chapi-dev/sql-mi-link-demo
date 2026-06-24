# Plan de cutover: SQL 2017 NorthEU → SQL 2022 SpainC

Protocolo end-to-end para el momento del cutover. Asume que toda la fase de **build &
sync** está completa (AGs locales arriba, DAG sincronizando, manual seeding completado,
objetos out-of-band migrados). Si no, vuelve a [`runbook.md`](runbook.md) primero.

> 🎯 **Goal**: pasar el tráfico de escritura de NorthEU a SpainC **en una ventana de 30-90
> segundos** con **RPO = 0** (cero transacciones perdidas) y plan de rollback armado.

> 📘 Basado en el protocolo oficial MS:
> [Distributed availability groups — migration scenarios](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups).

---

## 1. Decisiones que tomar ANTES del cutover

Estas decisiones condicionan los pasos del runbook y no son post-hoc.

### 1.1 Estrategia post-cutover
Lee [`post-cutover-strategies.md`](post-cutover-strategies.md) y **elige UNA**:
- A) Decommission NorthEU tras T+72h
- B) Upgrade in-place AG_NorthEU a 2022 (DAG bidireccional permanente)
- C) Pivot inmediato a MI
- D) NorthEU como UAT

→ Output: variable `$POST_CUTOVER_STRATEGY` en este plan.

### 1.2 Ventana de mantenimiento
Aunque el cutover sea de 30-90 s, **anuncia 5 min de ventana** por seguridad
(retries de aplicación, validación, etc.). Comunicación a usuarios:

```
Ventana de mantenimiento del servicio <NombreApp>
Fecha:    <YYYY-MM-DD>
Hora:     <HH:MM> CET — duración estimada 5 min
Impacto:  La aplicación puede no responder o devolver errores transitorios durante
          la ventana. No se requiere acción del usuario; reintentar tras 5 min.
Razón:    Migración planificada de base de datos a nueva infraestructura.
```

### 1.3 Equipo necesario en la ventana
- **Owner técnico** (ejecuta los pasos del cutover).
- **DBA backup** (segundo par de ojos, valida queries).
- **Owner de la app** (verifica health post-cutover).
- **Comunicación** (postea status en Slack/Teams).
- **Decision maker** (puede dar el "go/no-go" del rollback).

### 1.4 Connection string nueva (preparada con antelación)
La app debe poder apuntar al destino con un **único cambio de configuración**:

```
Server=vm-sql2022.spaincentral.cloudapp.azure.com;
Database=<AppDb>;
Encrypt=true;
TrustServerCertificate=false;
Connection Timeout=30;
ConnectRetryCount=3;
ConnectRetryInterval=10;
MultiSubnetFailover=true;
```

→ **Tener ya preparado el PR / config update / feature flag** que cambia esto. NO se
edita a mano durante la ventana.

### 1.5 Triggers de rollback (acuerda umbrales antes)
| Métrica | Umbral que dispara rollback |
|---|---|
| Tasa de error HTTP 5xx de la app | > 5% sostenido > 60 s post-cutover |
| Latencia P95 de queries críticas | > 3× baseline durante > 2 min |
| Errores SQL en logs de app (login failed, deadlock, timeout) | > 10/min sostenido |
| Validación smoke falla | Cualquier fallo crítico |
| El DAG no levanta como esperado | Inmediato |

Si **cualquiera** se dispara → ejecutar [`rollback-plan.md`](rollback-plan.md).

---

## 2. Timeline general del cutover

```
T-7d   Comms inicial a stakeholders
T-3d   Dry-run del protocolo en entorno de staging (si existe)
T-24h  Snapshot Azure Backup VM 2017 (Capa 2 de rollback)
       Backup full pre-cutover a Blob (Capa 1)
T-1h   Comms reminder
       Health check final del DAG (HEALTHY, colas de replicación bajas)
       Inicio de fase 1 (drain progresivo si la app lo permite)

T-0    [CUTOVER WINDOW START]
T+0min Stop writes app
T+1min Esperar a que el async vacíe la cola (send_queue = 0, redo_queue = 0)
T+2min Verificar LSN paridad final
T+3min Failover del DAG (FORCE_FAILOVER_ALLOW_DATA_LOSS — sin pérdida, ya verificado)
T+4min App repoint a vm-sql2022
T+5min [CUTOVER WINDOW END] — smoke tests empiezan

T+5-30min Smoke tests + perf baseline rápido
T+30min   GO / NO-GO decision (continuar o rollback)
T+1h      Si GO → ejecutar pasos de "stabilization"
T+24h     Validación extendida — confirmar estrategia post-cutover
T+72h     Si estrategia A o C → empezar decommission NorthEU
          Si estrategia B → planificar upgrade in-place
```

---

## 3. Pre-cutover checklist (T-7d a T-1h)

### T-7d — Comms inicial
- [ ] Email a stakeholders con fecha, hora, duración, impacto.
- [ ] Crear canal de Slack/Teams `#cutover-<fecha>` para coordinación.
- [ ] Programar war room (puente físico o videocall) para la ventana.

### T-3d — Dry-run (opcional pero recomendado)
- [ ] Ejecutar el protocolo entero contra un AG_NorthEU_test / AG_SpainC_test si existe staging.
- [ ] Cronometrar cada paso.
- [ ] Detectar pasos lentos antes de la ventana real.

### T-24h — Backups y snapshots
- [ ] **Backup full + log** de la BD legacy a Blob (Capa 1 rollback):
  ```sql
  BACKUP DATABASE [AppDb]
  TO URL = 'https://<sa>.blob.core.windows.net/cutover-backups/AppDb_full_T-24h.bak'
  WITH COMPRESSION, CHECKSUM, FORMAT, MAXTRANSFERSIZE = 4194304, BUFFERCOUNT = 64;

  BACKUP LOG [AppDb]
  TO URL = 'https://<sa>.blob.core.windows.net/cutover-backups/AppDb_log_T-24h.trn'
  WITH COMPRESSION, CHECKSUM, FORMAT;
  ```
- [ ] **Snapshot Azure Backup VM 2017** (Capa 2 rollback):
  ```powershell
  # Ver scripts/07-enable-azure-backup-vm.ps1 del modulo MI Link del repo
  Backup-AzRecoveryServicesBackupItem -Item $bkpItem -BackupType Full -EnableCompression
  ```
- [ ] Verificar que los backups son **restorables** (en una VM cualquiera de test).

### T-1h — Health checks finales

#### 1. Estado del DAG
```sql
-- En vm-sql2022 (forwarder):
SELECT
    ag.name                                  AS ag_name,
    rs.is_local,
    rs.synchronization_state_desc,
    rs.synchronization_health_desc,
    rs.log_send_queue_size                   AS send_kb,
    rs.redo_queue_size                       AS redo_kb,
    rs.last_commit_time,
    rs.last_hardened_lsn
FROM sys.dm_hadr_database_replica_states rs
JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
WHERE ag.name IN ('AG_SpainC', 'DAG_Migrate');
```

Aceptables:
- `synchronization_health_desc` = `HEALTHY`
- `synchronization_state_desc` = `SYNCHRONIZED` o `SYNCHRONIZING` (es ASYNC, lo segundo es OK)
- `log_send_queue_size` < 5000 KB
- `redo_queue_size` < 5000 KB
- `last_commit_time` lag vs primary < 5 s

Si **cualquiera falla** → posponer el cutover y diagnosticar.

#### 2. Latencia de red NorthEU ↔ SpainC
```powershell
# Desde vm-sql2017
Test-NetConnection -ComputerName vm-sql2022.spaincentral.cloudapp.azure.com -Port 5022
# RTT debe estar en el rango medido en POC (~25-35 ms)
```

#### 3. Espacio en disco
```sql
-- En ambas instancias
SELECT
    db.name,
    mf.physical_name,
    mf.size * 8 / 1024 AS size_mb,
    FILEPROPERTY(mf.name, 'SpaceUsed') * 8 / 1024 AS used_mb,
    (mf.size - FILEPROPERTY(mf.name, 'SpaceUsed')) * 8 / 1024 AS free_mb
FROM sys.master_files mf
JOIN sys.databases db ON db.database_id = mf.database_id
WHERE db.name = 'AppDb';
```
LDF de NorthEU debe tener **espacio para sostener log durante la ventana** (mínimo 1 GB libre).

#### 4. Sesiones activas
```sql
-- En vm-sql2017
SELECT COUNT(*) AS active_sessions
FROM sys.dm_exec_sessions
WHERE database_id = DB_ID('AppDb') AND is_user_process = 1;
```
Si hay muchas (>50), considera comunicar a app que reduzca conexiones antes del cutover.

#### 5. Validar plan de rollback armado
- [ ] Backup Capa 1 en Blob — restoreable (testeado en T-24h).
- [ ] Snapshot Capa 2 — listed.
- [ ] Script Capa 3 (`12-rollback-immediate.sql`) — listo a ejecutar.
- [ ] Owner de cada capa identificado.

---

## 4. Protocolo del cutover (T-0 a T+5min)

> ⏱️ **Cronómetro al arrancar T-0**. Cada paso debe completarse en su slot.

### T+0 — Stop writes en la app (segundo 0-30)

Tres opciones, según la app:

**Opción A — Feature flag**
```
La app comprueba un flag remoto. Activar:
  flag: "db_readonly_mode" = true
```

**Opción B — Read-only mode en la BD**
```sql
-- En vm-sql2017
ALTER DATABASE [AppDb] SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;
-- Solo admins/dbo/db_owner pueden conectar.
```

**Opción C — Stop del frontend de la app**
```powershell
# Si la app tiene un load balancer:
az network application-gateway rule delete -g <rg> --gateway-name <gw> --name <rule>
# O parar el servicio:
Get-Service "AppFrontendService" | Stop-Service
```

**Verificar que NO entran writes nuevos**:
```sql
-- En vm-sql2017
SELECT
    SUM(CASE WHEN command IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE') THEN 1 ELSE 0 END)
    AS write_requests
FROM sys.dm_exec_requests
WHERE database_id = DB_ID('AppDb');
-- Debe ser 0 antes de continuar.
```

### T+1 — Esperar a que el asíncrono vacíe la cola (segundo 30-120)

Con las escrituras paradas, dejamos que el asíncrono termine de replicar lo que quedaba en
vuelo. **No cambiamos a síncrono** (no hace falta para RPO 0; ver
[`rpo-options.md`](rpo-options.md)).

```sql
-- Ejecutar repetidamente (cada 5 s) hasta que send_queue y redo_queue lleguen a 0
SELECT
    ag.name,
    ar.replica_server_name,
    rs.synchronization_state_desc,    -- en ASYNC sera 'SYNCHRONIZING' (esperado, no es error)
    rs.log_send_queue_size  AS send_kb,    -- debe llegar a 0
    rs.redo_queue_size      AS redo_kb,    -- debe llegar a 0
    rs.last_hardened_lsn,
    rs.last_commit_time
FROM sys.dm_hadr_database_replica_states rs
JOIN sys.availability_replicas ar ON ar.replica_id = rs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
WHERE ag.name IN ('DAG_Migrate');
-- Continuar solo cuando send_queue = 0 Y redo_queue = 0.
```

> 💡 **Opcional**: si prefieres una señal de estado más explícita que mirar las colas, puedes
> cambiar el DAG a síncrono unos segundos aquí (`MODIFY AVAILABILITY GROUP ON 'AG_SpainC'
> WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT)`) y esperar a `synchronization_state_desc =
> SYNCHRONIZED`. Es solo comodidad operativa — con las escrituras paradas la latencia no
> penaliza nada. Pero **no es necesario**: con la cola a 0 y los LSN iguales (paso T+2) ya
> tienes RPO 0. El camino por defecto es quedarse en asíncrono.

### T+2 — Verificación final de LSN paridad (segundo 120-150)

```sql
-- Comparar LSN hardened primary vs forwarder.
-- Deben ser EXACTAMENTE iguales. Como las escrituras estan paradas, una vez
-- igualados ya no divergen.
DECLARE @primary_lsn NUMERIC(25, 0);
DECLARE @forwarder_lsn NUMERIC(25, 0);

SELECT @primary_lsn = last_hardened_lsn
FROM sys.dm_hadr_database_replica_states rs
JOIN sys.availability_replicas ar ON ar.replica_id = rs.replica_id
WHERE ar.replica_server_name = 'vm-sql2017' AND rs.is_local = 1;

-- Conectarse a vm-sql2022 y ejecutar:
-- SELECT @forwarder_lsn = last_hardened_lsn
-- FROM sys.dm_hadr_database_replica_states rs ...

SELECT @primary_lsn AS primary_lsn,
       @forwarder_lsn AS forwarder_lsn,
       CASE WHEN @primary_lsn = @forwarder_lsn THEN 'PROCEED' ELSE 'STOP' END AS decision;
```

Si **PROCEED** (LSN iguales + colas a 0): avanzar al failover.
Si **STOP**: investigar. **NO hacer failover**.

### T+3 — Failover del DAG (segundo 150-180)

> 📖 **Importante**: en un Distributed AG el **único** comando de failover soportado es
> `FORCE_FAILOVER_ALLOW_DATA_LOSS` (no existe un "planned failover" como en un AG normal).
> No pierde datos **porque ya hemos verificado** que la cola está a 0 y los LSN coinciden —
> ese es el motivo de los pasos T+1 y T+2. Ref:
> [Configure DAG — Fail over](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-distributed-availability-groups#fail-over-a-distributed-availability-group).

```sql
-- DESDE vm-sql2022 (el target del failover):
ALTER AVAILABILITY GROUP [DAG_Migrate] FORCE_FAILOVER_ALLOW_DATA_LOSS;
GO

-- Verificar nuevo estado:
SELECT
    ag.name,
    ar.replica_server_name,
    rs.role_desc,
    rs.operational_state_desc
FROM sys.dm_hadr_database_replica_states rs
JOIN sys.availability_replicas ar ON ar.replica_id = rs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
WHERE ag.name IN ('DAG_Migrate');
-- vm-sql2022 debe aparecer como PRIMARY.
```

> 📖 **Nota**: confirma la sintaxis exacta de tu CU de SQL Server 2022 (hay diferencias entre
> 2019 y 2022 por el setting `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT`). **Probarlo en
> dry-run T-3d.**

### T+4 — Sacar la BD del modo restricted en el destino (segundo 180-210)

```sql
-- En vm-sql2022 (ahora primario):
ALTER DATABASE [AppDb] SET MULTI_USER;
```

Verificar que la BD acepta conexiones:
```sql
SELECT state_desc, user_access_desc FROM sys.databases WHERE name = 'AppDb';
-- state_desc=ONLINE, user_access_desc=MULTI_USER
```

### T+4.5 — App repoint (segundo 210-270)

**Cambiar la configuración** (preparada en T-1h) para que la app apunte a vm-sql2022:

```
# Opción 1: actualizar config en runtime
kubectl set env deployment/app DATABASE_HOST=vm-sql2022.spaincentral.cloudapp.azure.com

# Opción 2: rolling restart con nueva config
kubectl rollout restart deployment/app

# Opción 3: feature flag flip
flag "active_db" = "spainc"
```

Si la app usa DNS para resolver el SQL, también puedes usar el CNAME y solo cambiar el DNS
record (más simple, sin restart). Esto tarda lo que tarde el TTL en propagar.

### T+5 — Habilitar writes y validar conectividad (segundo 270-300)

Si usaste **read-only mode** o **stop frontend**, revertir:

```sql
-- Si pusiste RESTRICTED_USER en NorthEU (innecesario ya, pero por limpieza):
-- (omitir si app ya no usa NorthEU)
ALTER DATABASE [AppDb] SET MULTI_USER;
```

```powershell
# Reiniciar servicios de app
Get-Service "AppFrontendService" | Start-Service
```

**Smoke test inmediato**: una query trivial desde la app o curl al endpoint.

```sql
-- Manual desde la app o desde una console:
SELECT GETUTCDATE() AS now_utc, @@SERVERNAME AS server, DB_NAME() AS db;
-- Debe devolver server=vm-sql2022 y db=AppDb
```

---

## 5. Validación post-cutover (T+5 a T+30min)

### Smoke tests funcionales

Suite mínima (adaptar a la app real):

```sql
-- 1) Connectividad básica
SELECT @@SERVERNAME, @@VERSION;

-- 2) BD accesible
USE [AppDb];
SELECT COUNT(*) FROM <tabla_principal>;

-- 3) Tx de escritura simple (idempotente)
BEGIN TRAN;
INSERT INTO smoke_test_log (timestamp, message) VALUES (GETUTCDATE(), 'post-cutover smoke');
ROLLBACK;

-- 4) Query crítica de negocio (la peor que tenga la app)
SET STATISTICS TIME ON;
<la query critica>;
SET STATISTICS TIME OFF;
-- Comparar duración con baseline pre-cutover. Aceptable hasta 2× degradación.

-- 5) Jobs SQL Agent básicos
SELECT name, enabled, last_run_outcome
FROM msdb.dbo.sysjobs
WHERE enabled = 1;

-- 6) Linked servers
EXEC sp_testlinkedserver '<linked_server_name>';

-- 7) Logins funcionan
EXECUTE AS LOGIN = 'app_user';
SELECT SUSER_NAME();
REVERT;
```

### Métricas a observar (T+5 a T+30min)

| Métrica | Fuente | Umbral OK |
|---|---|---|
| Tasa de error HTTP de la app | Application Insights / logs | < baseline + 20% |
| Latencia P95 de queries | Query Store en SQL 2022 | < 2× baseline |
| Sesiones activas | `sys.dm_exec_sessions` | Volviendo al baseline en 5-10 min |
| Wait stats anómalos | `sys.dm_os_wait_stats` | Sin nuevos en top 10 |
| Errores en error log SQL | `sys.fn_get_audit_file` o errorlog | Cero login failures |
| CPU/memoria VM 2022 | Azure Monitor | < 80% sostenido |

---

## 6. GO / NO-GO decision (T+30min)

Reunión rápida del war room (5 min).

| Pregunta | Respuesta |
|---|---|
| ¿Smoke tests pasan? | sí/no |
| ¿Métricas dentro de umbrales? | sí/no |
| ¿Algún error crítico en logs? | sí/no |
| ¿Owner de app valida funcionalidad? | sí/no |

**Todas sí → GO** → continuar al apartado §7 stabilization.
**Alguna no → NO-GO** → ejecutar [`rollback-plan.md`](rollback-plan.md) inmediatamente.

> Establecer **un único decision maker** que tome la decisión. Sin esto, las dudas en
> grupo alargan la ventana de pánico.

---

## 7. Stabilization (T+30min a T+24h)

### T+30min — Comms a stakeholders
```
Status: COMPLETADO ✅
Migración finalizada a las <HH:MM>. La app está operativa en la nueva infraestructura.
Validación inicial OK. Continuamos monitorizando durante las próximas 24h.
```

### T+1h — Apagar el "modo migración"
- [ ] Quitar feature flags temporales.
- [ ] Disable de cualquier query route que apuntara a NorthEU.
- [ ] Confirmar que NorthEU **no recibe tráfico** (logs vacíos durante T+1h).

### T+2h — Backup full del destino (nueva línea base)
```sql
-- En vm-sql2022
BACKUP DATABASE [AppDb]
TO URL = 'https://<sa>.blob.core.windows.net/cutover-backups/AppDb_post_cutover_full.bak'
WITH COMPRESSION, CHECKSUM, FORMAT;
```
Este backup es la **nueva línea base** del entorno. A partir de aquí, los backups regulares
salen de SpainC.

### T+24h — Validación extendida
- [ ] Revisar Query Store: queries con regresión > 2× → investigar.
- [ ] Revisar wait stats acumulados (últimas 24h).
- [ ] Comparar volumen de transacciones día-a-día con la semana anterior.
- [ ] Revisar logs de aplicación: errores, retries, latencias.

Si todo OK → confirmar la **estrategia post-cutover elegida** ([`post-cutover-strategies.md`](post-cutover-strategies.md))
y empezar a ejecutarla:

| Estrategia | Acción T+24h |
|---|---|
| A) Decommission | Comms anunciando decommission en T+72h |
| B) Upgrade in-place AG_NorthEU | Programar ventana para in-place upgrade |
| C) Pivot a MI | Empezar diseño de fase MI Link |
| D) UAT | Reconfigurar AG_NorthEU como UAT |

---

## 8. Anatomía del rollback durante el cutover

Si en cualquier momento entre T+0 y T+30min se dispara un trigger de rollback (§1.5):

### Si la BD nueva en SpainC NO recibe writes aún (T+0 a T+4.5)
**Rollback fácil**: simplemente
1. Cancela el `ALTER ... FAILOVER` si está en curso.
2. Devuelve DAG a ASYNC (estado original).
3. Saca BD legacy de `RESTRICTED_USER`.
4. Reactiva app apuntando a NorthEU.
5. Tiempo: ~3 minutos.

### Si la BD nueva ya recibió writes (T+4.5 en adelante)
**Rollback Capa 3** (inmediato):
1. Stop app inmediatamente.
2. Apagar / read-only BD en SpainC para evitar split-brain.
3. Reactivar BD en NorthEU (probablemente reactivar AG local que quedó intacto, o llevarla
   a `MULTI_USER` y RECOVERY si se sacó del AG).
4. App repoint de vuelta a NorthEU.
5. **Pérdida**: las transacciones escritas en SpainC durante T+4.5 → T+rollback.
6. Recuperar esas tx (manual): extraer de Query Store o transaction log de SpainC y
   re-aplicar a NorthEU si son críticas.
7. Tiempo: ~10-20 minutos.

Ver [`rollback-plan.md`](rollback-plan.md) para el detalle de las 4 capas.

---

## 9. Template de log del cutover

Llevar este log durante la ventana (escribirlo en el canal de Slack):

```
T-0:   Empezando cutover. Owner: <nombre>. Equipo: <…>
T+0:   Stop writes (método: <feature flag / RESTRICTED_USER / stop frontend>)
T+1:   Esperando vaciado de cola async — send_queue: <X> KB → 0
T+2:   LSN paridad: <primary_lsn> = <forwarder_lsn> ✅
T+3:   Failover DAG ejecutado (FORCE_FAILOVER_ALLOW_DATA_LOSS, sin pérdida)
T+4:   vm-sql2022 ahora PRIMARY. BD MULTI_USER.
T+4.5: App repoint ejecutado. Connection string nueva activa.
T+5:   App acepta tráfico. Smoke test: <ok / detalles>
T+10:  HTTP 5xx rate: <X>%. Latencia P95: <Y>ms.
T+20:  Métricas estables. War room en standby.
T+30:  GO/NO-GO decision: GO ✅
T+1h:  Modo migración apagado. Backup nueva BD ejecutado.
T+24h: Validación extendida — OK
```

---

## 10. Lessons learned (escribir post-mortem T+72h)

Plantilla obligatoria post-cutover:

```markdown
# Post-mortem cutover SQL 2017→2022 (<fecha>)

## Resultado
- ¿GO o NO-GO? <…>
- Duración real de la ventana: <X> min (vs estimado 5 min)
- Incidentes: <ninguno | listar>

## Lo que salió bien
- ...

## Lo que mejoraría próxima vez
- ...

## Métricas reales medidas
- Tiempo vaciado de cola async (send_queue → 0): <X>s
- Tiempo failover: <Y>s
- Errores HTTP post-cutover: <Z>%
- Latencia query crítica antes/después: <a>ms / <b>ms

## Cambios al runbook
- <…>

## Acciones de seguimiento
- <…>
```

Este post-mortem alimenta el [`runbook.md`](runbook.md) y este mismo plan para el
**próximo cutover** (la fase MI siguiente puede beneficiar de las lecciones).

---

## Referencias

- [Distributed availability groups — migration scenarios](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups#migration-scenarios)
- [Failover to a secondary availability group](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-distributed-availability-groups#failover)
- [sys.dm_hadr_database_replica_states](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-hadr-database-replica-states-transact-sql)
- [Query Store usage scenarios](https://learn.microsoft.com/sql/relational-databases/performance/query-store-usage-scenarios)
- [`rpo-options.md`](rpo-options.md) — opciones SYNC/ASYNC y por qué el cutover va en ASYNC
- [`rollback-plan.md`](rollback-plan.md) — 4 capas de rollback (pendiente)
- [`post-cutover-strategies.md`](post-cutover-strategies.md) — qué hacer post-cutover
