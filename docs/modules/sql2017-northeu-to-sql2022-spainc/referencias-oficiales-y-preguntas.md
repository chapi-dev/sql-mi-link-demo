# Referencias oficiales — latencia y modos de réplica (cross-region SQL 2017 → 2022)

Documento de apoyo para la conversación con el equipo de SQL Server. Todos los links
verificados (HTTP 200) el 2026-06-22.

> 💡 Si copias una URL a mano y da 404, es porque se cuela un espacio en palabras largas
> como `windows` o `sql-server`. Haz clic en los enlaces de abajo en vez de copiarlos.

---

## ¿Cuánta latencia se requiere para North Europe ↔ Spain Central?

**Respuesta: no hay un umbral mínimo de latencia que bloquee la migración.**

| Modo | Cuándo se usa | ¿La latencia importa? |
|---|---|---|
| **ASYNCHRONOUS_COMMIT** | Replicación continua (días/semanas) + cutover | ❌ No — diseñado para distancias grandes |
| **SYNCHRONOUS_COMMIT** | Solo los segundos del cutover, con writes parados | ❌ No — no hay throughput que penalizar |
| SYNCHRONOUS_COMMIT 24/7 | HA permanente cross-region (NO es el caso de migración) | ✅ Sí, penaliza cada commit |

### Cita oficial que lo respalda (literal)

De [Differences between availability modes for an Always On availability group](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/availability-modes-always-on-availability-groups):

> *"Asynchronous-commit mode is a disaster-recovery solution that works well when the
> availability replicas are distributed over considerable distances. If every secondary
> replica is running under asynchronous-commit mode, the primary replica doesn't wait for
> any of the secondary replicas to harden the log... The primary replica runs with minimum
> transaction latency."*

→ El modo asíncrono está **diseñado para réplicas separadas por distancias considerables**
(= regiones distintas). North Europe ↔ Spain entra de sobra.

**Microsoft NO publica un máximo de latencia** para Always On AG / Distributed AG. La guía
es: síncrono dentro de la misma región, **asíncrono entre regiones**.

---

## "¿Es el método recomendado?" — la verdad matizada

La doc **no** llama al Distributed AG "el recomendado" a secas:

- El **recomendado por defecto** es backup nativo + copiar a Azure
  ([Migration overview](https://learn.microsoft.com/en-us/data-migration/sql-server/virtual-machines/overview#migrate)):
  > *"The recommended migration approach is to take a native SQL Server backup locally, and
  > then copy the file to Azure."*

- El Distributed AG es el método que **minimiza downtime**
  ([misma página, tabla de métodos](https://learn.microsoft.com/en-us/data-migration/sql-server/virtual-machines/overview#migrate)):
  > *"This method minimizes downtime. Use when you have an availability group configured."*

- Para downtime mínimo (el requisito del cliente), la guía oficial dice
  ([sección Considerations](https://learn.microsoft.com/en-us/data-migration/sql-server/virtual-machines/overview#considerations)):
  > *"To minimize downtime during database migration, use Always On availability groups."*

**Conclusión defendible**: el Distributed AG no es "el recomendado universal", es
**"el recomendado cuando el requisito es downtime mínimo cross-region/cross-version"** —
que es exactamente el caso del cliente.

---

## Links oficiales (verificados HTTP 200 el 2026-06-22)

| Tema | Título para buscar en learn.microsoft.com | Link directo |
|---|---|---|
| Modos de réplica (async cross-region) | *Differences between availability modes for an Always On availability group* | [abrir](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/availability-modes-always-on-availability-groups) |
| Overview migración SQL→SQL en VMs | *Migration overview: SQL Server to SQL Server on Azure VMs* | [abrir](https://learn.microsoft.com/en-us/data-migration/sql-server/virtual-machines/overview) |
| Distributed AG (concepto + avisos cross-version) | *Distributed availability groups* | [abrir](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/distributed-availability-groups) |
| Distributed AG prerequisitos (migración) | *Prerequisites for migrating with a distributed availability group* | [abrir](https://learn.microsoft.com/en-us/data-migration/sql-server/virtual-machines/distributed-availability-group-prerequisites) |
| Guía de migración (detalle de métodos) | *Migration guide: SQL Server to SQL Server on Azure VMs* | [abrir](https://learn.microsoft.com/en-us/data-migration/sql-server/virtual-machines/guide) |

> ⚠️ Nota cross-version (2017→2022): la tabla del overview pone "Minimum target version:
> SQL Server 2016", pero el escenario cross-version tiene avisos propios en
> [Distributed availability groups](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/distributed-availability-groups)
> — sección "Cautions when using distributed availability groups to migrate to higher SQL
> Server versions": **seeding MANUAL obligatorio** y **no failback hasta igualar versiones**.

---

## Preguntas para el equipo de SQL Server

1. Vamos a usar Distributed AG en **asíncrono** para la replicación cross-region North
   Europe → Spain, y solo cambiar a **síncrono los segundos del cutover** para garantizar
   RPO 0. ¿Confirmáis que es el enfoque correcto y que no hay límite de latencia que nos
   afecte en este patrón?

2. ¿Confirmáis que Distributed AG cross-region es el método adecuado para 2017→2022 con
   downtime de segundos, o en estos casos empujáis hacia Azure DMS / Log Replay u otra
   herramienta?

3. El objetivo del cliente es tener **failback**. ¿Confirmáis que el camino correcto es
   2017 → 2022 → Managed Instance (con MI Link bidireccional), o veis una ruta mejor?

4. Para el seeding inicial: el origen es SQL 2017 y el Storage de la sub tiene
   `allowSharedKeyAccess=false` (policy MCAP). SQL 2017 no soporta user-delegation SAS, así
   que `BACKUP TO URL` falla. Validamos **azcopy + Managed Identity** como workaround.
   ¿Es aceptable, o recomendáis otra vía (Azure Files con Kerberos/Entra, exención de
   policy, etc.)?

5. RPO 0 con commit síncrono entre regiones: ¿qué latencia consideráis aceptable
   North Europe ↔ Spain? ¿Tenéis números reales de otros despliegues?
