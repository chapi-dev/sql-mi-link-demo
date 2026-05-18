# SQL MI Link demo: SQL Server 2017 → Azure SQL Managed Instance (cross-region)

Demo end-to-end de **Managed Instance link** que replica una base de datos
desde un **SQL Server 2017** alojado en una VM de Azure en **France Central**
hacia un **Azure SQL Managed Instance** en **Spain Central**.

Reproduce el escenario real de un cliente que quiere migrar entre regiones
con downtime mínimo, usando SQL Server 2017 (no SQL 2022).

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
├── README.md                          # este archivo
├── scripts/
│   ├── 01-infra.ps1                   # Provisiona Azure (RGs, VNets, peering, VM, MI)
│   ├── 00-enable-alwayson.ps1         # En la VM: habilita Always On AG feature
│   ├── install-sql2017-cu31.ps1       # En la VM: instala CU31 (MI Link requiere CU20+)
│   ├── 01-prepare-sql.sql             # T-SQL: TF, master key, cert, endpoint 5022
│   ├── 02-restore-sample-db.sql       # T-SQL: crea DB demo + backup full/log
│   ├── 03-mi-link-setup.sql           # T-SQL: AG local + Distributed AG con la MI
│   ├── 04-cutover.sql                 # T-SQL: corta el link (cutover unidireccional)
│   └── cleanup.ps1                    # Borra los RGs
└── docs/
    ├── runbook.md                     # Guia paso a paso
    └── gotchas.md                     # Avisos y limitaciones SQL 2017
```

## ⚠️ Limitaciones críticas en SQL 2017
- MI Link requiere **CU20+** (instalamos CU31).
- **Solo replicación unidireccional**: SQL 2017 → MI. No hay managed failback como en SQL 2022.
- Cutover = romper el link → MI se vuelve primaria standalone → repuntar la app.
- Rollback solo manual (restaurar backup en SQL Server).
- Un link por base de datos.

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
