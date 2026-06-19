# Módulo: SQL Server 2017 (North Europe) → SQL Server 2022 (Spain Central)

Migración cross-region **entre versiones de SQL Server en VMs Azure**, como **fase intermedia**
antes de saltar a Azure SQL Managed Instance.

## Por qué este módulo existe

Si tu origen es **SQL Server 2017**, migrar directamente a MI te deja con un link
**unidireccional** sin failback nativo (ver [`../../migration-rollback-plan.md`](../../migration-rollback-plan.md)).
El rollback hay que diseñarlo a mano con 4 capas.

Si primero pasas a **SQL Server 2022**, ganas:

- **Failback bidireccional nativo** cuando luego subas a MI con update policy *SQL Server 2022*.
- Características modernas (Query Store siempre on, Intelligent Query Processing, etc.).
- Plataforma soportada más tiempo.

Coste: una migración extra. Beneficio: la migración crítica (la que va a MI) se hace con
red de seguridad real.

## Objetivos de esta fase

| Objetivo | Compromiso |
|---|---|
| Sin cortar servicio | App reconecta en segundos durante el cutover. Cero ventana de mantenimiento programada. |
| RPO = 0 en el cutover planificado | Protocolo de drain + LSN sync + planned failover. Cero transacciones perdidas. |
| Botón de pánico | AG local de origen **intacto** durante T+24 h post-cutover + 2 capas de backup independiente. |
| Cross-region | North Europe (origen actual) → Spain Central (destino). |
| Cross-version | 2017 → 2022. Forward-compat ✅. Failback al 2017 requiere capas externas (no del log). |

## Arquitectura en una imagen

```
       North Europe (origen)                Spain Central (destino)
   ┌────────────────────────────┐       ┌────────────────────────────┐
   │ VM SQL Server 2017 CU31    │       │ VM SQL Server 2022 CUx     │
   │ Always On AG local         │       │ Always On AG local         │
   │ (AG_NorthEU, single replica)│      │ (AG_SpainC, single replica)│
   │ DB en FULL recovery        │       │ Seeding AUTOMATIC          │
   │                            │       │                            │
   │ Endpoint 5022 ◄────────────┼───────┼──► Endpoint 5022           │
   │ Cert auth                  │       │ Cert auth                  │
   └────────────────────────────┘       └────────────────────────────┘
                ▲                                    ▲
                │       Distributed AG (DAG_Migrate) │
                │       Modo según rpo-options.md    │
                └───────────── Global VNet peering ──┘
                              (10.10/16 ↔ 10.30/16)
                              5022/TCP en NSG + WinFW
```

Patrón idéntico al usado para MI Link en este repo, pero entre dos VMs SQL Server de
distinta versión.

## Por dónde empezar

1. **Lee primero la guía oficial MS**: [`official-microsoft-guidance.md`](official-microsoft-guidance.md)
   — ground truth con citas oficiales y URLs. Si algún otro doc del módulo contradice esto, este gana.
2. **⚠️ CRÍTICO antes de empezar**: lee [`poc-validation-findings.md`](poc-validation-findings.md)
   — findings empíricos de POC real en sub MCAP. Hay un bloqueante crítico si tu sub
   tiene policy `allowSharedKeyAccess=false` + origen es SQL Server 2017.
3. **Decide el modo de replicación** (ASYNC / SYNC / híbrido): [`rpo-options.md`](rpo-options.md).
4. **Entiende el diseño**: [`architecture.md`](architecture.md).
5. **Por qué este patrón y no log shipping / replicación / backup-restore / DMS / SSMS migration**: [`decision-rationale.md`](decision-rationale.md).
6. **Red**: [`networking.md`](networking.md).
7. **Bugs típicos y workarounds**: [`troubleshooting.md`](troubleshooting.md) §0 (12 findings empíricos).
8. **Ejecuta**: sigue [`runbook.md`](runbook.md).
9. **Objetos out-of-band** (logins, jobs, linked servers): [`out-of-band-objects.md`](out-of-band-objects.md).
10. **Diseña el cutover y rollback antes del go-live**: [`cutover-plan.md`](cutover-plan.md) + [`rollback-plan.md`](rollback-plan.md).
11. **Estrategias post-cutover**: [`post-cutover-strategies.md`](post-cutover-strategies.md).
12. **Valida**: [`post-migration-validation.md`](post-migration-validation.md).

## Scripts

Viven en [`../../../scripts/modules/sql2017-to-sql2022/`](../../../scripts/modules/sql2017-to-sql2022/).
Numerados según orden de ejecución (mismo criterio que el resto del repo).

## Estado del módulo

🧪 **POC empírica ejecutada** (2026-06-18). Documentación completa, scripts validados con
12 fixes aplicados. Ver [`poc-validation-findings.md`](poc-validation-findings.md) para
findings y limitaciones reales en sub MCAP.
