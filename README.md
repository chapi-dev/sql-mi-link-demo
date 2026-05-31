# SQL Server → Azure SQL Managed Instance via MI Link (cross-region)

Guía técnica para migrar una base de datos desde **SQL Server** (on-prem o en VM)
hacia **Azure SQL Managed Instance** en otra región usando **Managed Instance link**,
con un mecanismo de rollback robusto para escenarios donde el link es unidireccional
(SQL Server 2016/2017/2019).

La guía se valida en el escenario más estricto: **SQL Server 2017** → **MI** cross-region.

---

## Cuándo usar esta guía

| Escenario | ¿Aplica esta guía? |
|---|---|
| SQL Server 2016/2017/2019 → MI | ✅ Sí. El link es **one-way**, hay que diseñar rollback aparte. |
| SQL Server 2022 → MI | ✅ Sí, pero puedes simplificar el rollback usando el propio link en reverso. |
| SQL Server 2025 → MI | ✅ Sí, link bidireccional nativo. Mantén Capa 1 como defensa adicional. |
| SQL Server → SQL Server (sin pasar por MI) | ❌ Usa Always On AG o Log Shipping. |
| MI → MI cross-region | ❌ Usa **failover groups** o geo-replication nativa de MI. |

Ver [`docs/version-comparison.md`](docs/version-comparison.md) para la decisión de
quedarse en 2017 vs upgrade previo.

---

## Arquitectura

```
                Región origen                      Región destino
        ┌─────────────────────────┐     ┌────────────────────────────┐
        │  SQL Server (VM o on-prem) │     │  Azure SQL Managed Instance│
        │  Always On AG habilitado │     │  AAD-only auth recomendado │
        │  CU compatible con MI Link│     │  Update policy alineada    │
        │  (ver prereqs)           │     │  con la versión origen     │
        │                         │     │                            │
        │  Endpoint 5022 ◄────────┼─────┼────►  Endpoint 5022        │
        │  DAG primary            │     │  DAG secondary             │
        └─────────────────────────┘     └────────────────────────────┘
                  ▲                                  ▲
                  └──────── Global VNet peering ─────┘
                  (o ExpressRoute/Site-to-Site VPN)
                  Puerto 5022/TCP abierto en NSG + Windows Firewall
```

**Componentes lógicos por debajo del link:**

1. **AG local clusterless** en SQL Server origen (`CLUSTER_TYPE = NONE`).
2. **Distributed AG** entre el AG local y la réplica lógica del MI.
3. **Cert exchange** bidireccional (cada lado tiene el cert público del otro).
4. **Endpoint TCP 5022** en ambos lados con autenticación por certificado.

Detalles de cada componente en [`docs/architecture.md`](docs/architecture.md).

---

## Estructura del repo

```
.
├── README.md                                  # esta página
├── docs/
│   ├── architecture.md                        # diseño detallado de red, identidad, certificados
│   ├── version-comparison.md                  # SQL 2017 vs 2022 vs 2025 — decisión de upgrade
│   ├── runbook.md                             # secuencia técnica para levantar el escenario
│   ├── azure-connect-pack.md                  # paquete crítico para SQL Server 2017 (KB5050533)
│   ├── ssms-wizard-guide.md                   # ruta recomendada: wizard
│   ├── manual-link-setup.md                   # fallback al wizard: setup vía T-SQL + REST
│   ├── migration-rollback-plan.md             # plan de migración + 4 capas de rollback
│   ├── rollback-verification.md               # cómo verificar empíricamente cada capa
│   ├── troubleshooting.md                     # códigos de error frecuentes y resolución
│   └── images/
│       ├── wizard-walkthrough/                # capturas del SSMS Wizard
│       └── rollback-docs/                     # capturas de docs MS Learn de referencia
└── scripts/
    ├── 00-enable-alwayson.ps1                 # habilita Always On AG en la VM
    ├── 01-infra.ps1                           # provisiona RGs, VNets, peering, VM, MI
    ├── install-sql2017-cu31.ps1               # aplica un CU sobre SQL Server 2017
    ├── 01-prepare-sql.sql                     # TF, master key, cert, endpoint 5022
    ├── 02-restore-sample-db.sql               # crea BD demo + backup full/log
    ├── 03-mi-link-setup.sql                   # AG local + Distributed AG con MI
    ├── 04-cutover.sql                         # corta el link (cutover unidireccional)
    ├── 05-pre-cutover-backup.sql              # Capa 1: backup nativo full+log
    ├── 06-pre-cutover-backup.ps1              # wrapper PS del script 05
    ├── 07-enable-azure-backup-vm.ps1          # Capa 2: Recovery Services Vault + on-demand snapshot
    ├── 08-rollback-immediate.sql              # Capa 3: rollback inmediato post-cutover
    ├── 09-rollback-restore-from-blob.sql      # Capa 1: restore desde .bak (rollback nuclear)
    ├── 10-post-cutover-freeze-primary.sql     # Capa 3: dejar primary READ_ONLY + auditing
    └── cleanup.ps1                            # borra los RGs del entorno de pruebas
```

---

## Por dónde empezar

1. **Decide la versión del origen**: lee [`docs/version-comparison.md`](docs/version-comparison.md).
2. **Levanta el entorno de validación**: sigue [`docs/runbook.md`](docs/runbook.md).
3. **Para SQL Server 2017**: instala el [Azure Connect Pack (KB5050533)](docs/azure-connect-pack.md).
   Sin él el wizard falla.
4. **Configura el link**: usa la [guía del wizard SSMS](docs/ssms-wizard-guide.md).
5. **Diseña el rollback antes del cutover real**: lee
   [`docs/migration-rollback-plan.md`](docs/migration-rollback-plan.md) y verifica con
   [`docs/rollback-verification.md`](docs/rollback-verification.md).

---

## Limitaciones relevantes según versión del origen

| Característica | SQL 2016/2017/2019 | SQL 2022 | SQL 2025 |
|---|---|---|---|
| Replicación SQL → MI (one-way) | ✅ | ✅ | ✅ |
| Link bidireccional + failback online | ❌ | ✅ (con MI update policy *SQL Server 2022*) | ✅ (con MI update policy *SQL Server 2025*) |
| Wizard SSMS funcional out-of-the-box | ⚠️ Requiere paquetes extra | ✅ | ✅ |
| Rollback gestionado por el propio link | ❌ Externo (4 capas) | ✅ Reverse migration | ✅ Reverse migration |

Detalles y matriz extendida en [`docs/version-comparison.md`](docs/version-comparison.md).

---

## Referencias oficiales

- [Managed Instance link — overview](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-feature-overview)
- [MI link prerequisites](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-preparation)
- [SSMS wizard for MI Link](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-use-ssms-to-replicate-database)
- [Manual T-SQL setup](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-create-replication-script)
- [Migrate with the link (cutover)](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-migrate)
- [Disaster recovery & two-way replication](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-disaster-recovery)
- [Update policy in SQL MI](https://learn.microsoft.com/azure/azure-sql/managed-instance/update-policy)
- [SQL Server 2017 Azure Connect Pack (KB5050533)](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect)
