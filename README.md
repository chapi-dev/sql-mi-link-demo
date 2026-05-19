# SQL MI Link demo: SQL Server 2017 → Azure SQL Managed Instance (cross-region)

Demo end-to-end de **Managed Instance link** que replica una base de datos
desde un **SQL Server 2017** alojado en una VM de Azure en **France Central**
hacia un **Azure SQL Managed Instance** en **Spain Central**.

Reproduce el escenario real de un cliente que quiere migrar entre regiones
con downtime mínimo, usando SQL Server 2017 (no SQL 2022).

## ✅ Veredicto final (mayo 2026) — **MI Link FUNCIONA con SQL Server 2017**

Tras dos sesiones de troubleshooting, **MI Link cross-region con SQL Server 2017 funciona
end-to-end**. El bloqueador que diagnosticamos inicialmente como "incompatibilidad estructural"
era en realidad un **paquete que faltaba en la VM**: el
**[Azure Connect Pack para SQL Server 2017](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect)**
(KB5050533, v14.0.3490.10, publicado el **6 de marzo de 2025**).

### El requisito real (no documentado en la matriz principal)

Para MI Link, SQL Server 2017 necesita **DOS paquetes**:

1. **CU31** (14.0.3456.2) o un GDR posterior como **CU31-GDR (KB5046858, 14.0.3485.1)** — base.
2. **Azure Connect Pack (KB5050533, 14.0.3490.10)** — añade las SPs
   `sp_certificate_add_issuer`, `sp_get_endpoint_certificate` y el soporte de parser para
   `LISTENER_URL ... ;Server=[<MI_NAME>]` que la MI necesita para redirigir a la réplica lógica.

Sin el Azure Connect Pack, **el SSMS Wizard falla** en *Create Microsoft PKI certificate* con
`Msg 2812: Could not find stored procedure 'sp_certificate_add_issuer'`, y la **ruta T-SQL manual
también falla** con `Msg 19499 invalid listener URL` cuando se incluye `;Server=[…]`.

### Resultado verificado en el entorno demo

| Componente | Estado |
|---|---|
| VM `vm-sql2017` versión engine | 14.0.3490.10 (Azure Connect Pack instalado) |
| SSMS Wizard (link `SQLMI-link-test-02`) | **11/11 tareas Success**, sin errores |
| AG local `MILinkAG` en VM | `SYNCHRONIZED / HEALTHY` |
| Distributed AG `demo-link` (cross-region) | `SYNCHRONIZING / HEALTHY` (modo Async, normal) |
| LogQueue / RedoQueue en réplica MI | `0 / 0` (al día) |
| `DemoLink` visible en MI Object Explorer | ✅ (Tables, Views, Programmability, etc.) |
| Marker row `Id=504 VM-WIZARD-OK-LIVE` insertada en VM | ✅ replicada a MI |

![Replicación verificada: DemoLink Synchronized en VM y DemoLink visible en MI](docs/images/wizard-walkthrough/19-success-demolink-replicated-both-sides.png)

### Documentación detallada

- **[`docs/azure-connect-pack-install.md`](docs/azure-connect-pack-install.md)** — la receta exacta
  para descargar e instalar KB5050533 en una VM con SQL 2017 (BITS + silent install).
- **[`docs/wizard-attempt-sql2017-walkthrough.md`](docs/wizard-attempt-sql2017-walkthrough.md)** —
  walkthrough completo del SSMS Wizard con 19 capturas, incluyendo el fallo inicial, la causa real
  y el reintento exitoso tras instalar el Azure Connect Pack.
- **[`docs/gotchas.md`](docs/gotchas.md)** — todas las advertencias operativas (auth AAD-only,
  Agent XPs, API versions, peering, NSG, etc.).

### Conclusión

La matriz oficial **es correcta**: SQL Server 2017 CU31+ soporta MI Link. Pero el requisito del
**Azure Connect Pack** vive en una página aparte
([troubleshoot/sql/releases/sqlserver-2017/azureconnect](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect))
y es **fácil pasarlo por alto**. Si te encuentras con `Msg 2812 sp_certificate_add_issuer` o con
`Msg 19499 invalid listener URL`, no es un bug del engine — falta el Azure Connect Pack.


## 🎯 Objetivo
Demostrar que MI link funciona cross-region con SQL 2017 y validar el
cutover unidireccional (única opción de failover en 2017).

## 🏗️ Arquitectura

```
                France Central                   Spain Central
        ┌─────────────────────────┐     ┌────────────────────────────┐
        │  VM: vm-sql2017         │     │  SQL MI: mi-link-demo-fra… │
        │  Win Server 2019        │     │  GP Gen5 4 vCores, AAD-only│
        │  SQL Server 2017 CU31   │     │  Subnet 10.20.0.0/24       │
        │  Subnet 10.10.1.0/24    │     │  (delegated)               │
        │                         │     │                            │
        │  Endpoint 5022 ◄────────┼─────┼────►  Endpoint 5022        │
        │  DAG primary            │     │  DAG secondary             │
        └─────────────────────────┘     └────────────────────────────┘
                  ▲                                  ▲
                  └──────── Global VNet peering ─────┘
                     (allow_vnet_access, 5022 NSG)
```

| Componente | Recurso | Notas |
|---|---|---|
| Sub | `ME-MngEnvMCAP184496-antonioch-1` | MSDN/MCAP. MCAPS deny policy fuerza AAD-only auth en MI |
| RG VM | `rg-sqlmilink-vm-fra` (France Central) | |
| RG MI | `rg-sqlmilink-mi-esp` (Spain Central) | |
| VNet VM | `vnet-vm-fra` 10.10.0.0/16 | subnet `snet-vm` 10.10.1.0/24 |
| VNet MI | `vnet-mi-esp` 10.20.0.0/16 | subnet `ManagedInstance` 10.20.0.0/24 delegated |
| Peering | `fra-to-esp` ↔ `esp-to-fra` | Global, bidireccional |
| VM | `vm-sql2017`, Standard_L2as_v4 | Windows Server 2019 + SQL 2017 Developer image |
| MI | `mi-link-demo-fraesp` | GP Gen5 4 vCores 32 GB, LicenseIncluded, AAD-only |

## 📁 Estructura del repo

```
.
├── README.md                              # este archivo
├── scripts/
│   ├── 01-infra.ps1                       # Provisiona Azure (RGs, VNets, peering, VM, MI)
│   ├── 00-enable-alwayson.ps1             # En la VM: habilita Always On AG feature
│   ├── install-sql2017-cu31.ps1           # En la VM: instala CU31 (MI Link requiere CU31+ Y Azure Connect Pack)
│   ├── 01-prepare-sql.sql                 # T-SQL: TF, master key, cert, endpoint 5022
│   ├── 02-restore-sample-db.sql           # T-SQL: crea DB demo + backup full/log
│   ├── 03-mi-link-setup.sql               # T-SQL: AG local + Distributed AG con la MI
│   ├── 04-cutover.sql                     # T-SQL: corta el link (cutover unidireccional)
│   └── cleanup.ps1                        # Borra los RGs
└── docs/
    ├── runbook.md                         # Guia paso a paso
    ├── ssms-wizard-guide.md               # Cómo usar el wizard SSMS (versión teórica)
    ├── wizard-attempt-sql2017-walkthrough.md  # ⭐ Walkthrough REAL con capturas + resolución
    ├── azure-connect-pack-install.md      # ⭐ Cómo instalar KB5050533 (el fix real)
    ├── handoff.md                         # Estado del entorno live + retomar sesión
    ├── gotchas.md                         # Avisos y limitaciones SQL 2017
    ├── reporte-viabilidad.md              # Análisis de viabilidad
    └── images/wizard-walkthrough/         # 19 capturas del recorrido del wizard
```

## ⚠️ Limitaciones reales de SQL 2017 (con MI Link funcionando)
- **Requiere CU31+ Y Azure Connect Pack (KB5050533)**. Sin el Connect Pack, el wizard falla con
  `Msg 2812 sp_certificate_add_issuer` y T-SQL manual falla con `Msg 19499`.
- **Solo replicación unidireccional**: SQL 2017 → MI. No hay managed failback (eso solo existe
  en SQL 2022 CU13+).
- **No hay managed failover** en SQL 2017: el cutover es manual (poner BD read-only,
  esperar a que la cola de log llegue a 0, romper el Distributed AG).
- Rollback solo manual (restaurar backup en SQL Server) — al cortar, la BD en MI queda en
  formato MI nativo y ya no se puede importar de vuelta.
- Un link por base de datos.
- Replicación cross-region usa `ASYNCHRONOUS_COMMIT` → el estado normal es `SYNCHRONIZING / HEALTHY`
  (no `SYNCHRONIZED`); lo importante es que `LogQueue` y `RedoQueue` se mantengan bajos/en cero.

## 🚀 Para reproducir
Consulta [`docs/runbook.md`](docs/runbook.md).

## 💸 Coste aproximado
- VM Standard_L2as_v4: ~$140/mes (apagar cuando no se use).
- SQL MI GP 4 vCore 32 GB: ~$700-800/mes prorrateado (~$25/día).
- Global VNet peering + tráfico cross-region: <$5/mes para esta demo.
- **Total demo activa 1 semana**: ~$50.

Borra los RGs con `scripts/cleanup.ps1` cuando termines.

## 🔗 Referencias
- [Azure docs: Managed Instance link](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-feature-overview)
- [MI link prerequisites (SQL 2016/2017/2019/2022)](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-preparation)
- [SSMS wizard for MI Link](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-use-ssms-to-replicate-database)
- [**SQL Server 2017 Azure Connect Pack (KB5050533) — el paquete crítico que faltaba**](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect)
- [Manual T-SQL setup script](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/managed-instance-link-create-replication-script)
