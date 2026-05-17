# Gotchas y limitaciones conocidas

## Específicas de SQL Server 2017
| Limitación | Impacto | Mitigación |
|---|---|---|
| Solo replicación unidireccional (SQL → MI) | No hay failback gestionado | Planificar cutover sin retorno; tener backup completo en SQL Server por si toca rollback manual |
| No hay "managed failover" | El cutover es manual: poner BD read-only, esperar drain, romper DAG | Usar ventana de bajo tráfico + retry logic en la app |
| Requiere CU20+ | Imagen Marketplace trae CU17 | Instalar CU31 (último disponible) con `install-sql2017-cu31.ps1` |
| Un link por DB | Si tienes N BDs, configurar N links | Automatizar con T-SQL/PowerShell |

## Tenants MCAPS / Microsoft internos
- La policy `AzureSQLMI_WithoutAzureADOnlyAuthentication_Deny` impide crear MI con SQL admin/password.
- Solución: crear MI con `--enable-ad-only-auth` + `--external-admin-*`.
- Para conectar luego, usa AAD auth (token).

## Red
- **Global VNet peering** funciona entre regiones EU sin problemas, pero suma latencia (~25-30 ms FRA↔ESP).
- A más latencia, más lag en la cola de log. Si la app es muy write-intensive, considera regiones más cercanas o BC tier en la MI.
- NSG: 5022 TCP debe estar permitido en **ambos** sentidos. Si dejas las reglas default de Azure (AllowVnetInBound), basta con que las VNets estén peered.

## VM SKU
- En France Central muchas SKUs B-series tienen capacity restrictions. Usa `Standard_L2as_v4` (storage optimized, NVMe local) o cualquier `Dasv5`/`Eav5` disponible.

## SQL MI Free offer
- Está disponible solo en algunas regiones (no Spain Central a fecha actual).
- 12 vCores GP, 100 GB, auto-pause 12h/día, 12 meses.
- Solo una por suscripción.

## Provisioning lento de MI
- 4-6 horas es lo normal. Si pasa de 8h sin progreso, abrir caso de soporte.
- Estados visibles: `Creating` → `Created` (la VM virtual cluster ya existe).

## Versión MI
- La MI siempre está en la última versión del engine (≥ SQL 2022 internamente). El link adapta los formatos.
- Tras el cutover, la BD en MI ya estará en formato MI nativo — no hay vuelta a SQL 2017.

## SSMS
- Usa **SSMS 19+** para el wizard de MI Link. Versiones anteriores no lo tienen.
- Si el wizard falla en el paso "Test connection MI → SQL Server", revisa NSG, firewall de Windows y el endpoint 5022 (`SELECT * FROM sys.tcp_endpoints`).

## Certificados
- El wizard de SSMS gestiona el intercambio de certs automáticamente.
- Manualmente: `BACKUP CERTIFICATE` en SQL Server, importar en MI con `sys.sp_set_instance_server_trust_certificate`, descargar el cert de MI con `Get-AzSqlInstanceServerTrustCertificate`, importar en SQL Server con `CREATE CERTIFICATE … FROM FILE`.
