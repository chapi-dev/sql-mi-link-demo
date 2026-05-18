# Gotchas y limitaciones conocidas

## 🚨 BLOCKER CRÍTICO: SQL Server 2017 NO completa MI Link cross-region (confirmado mayo 2026)

A pesar de que la [matriz oficial de Microsoft](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/managed-instance-link-preparation)
lista SQL Server 2017 CU31 como soportado para MI Link, en la práctica **no se puede completar el
link** con la última versión disponible (CU31-GDR, KB5046858, Oct 2024):

| Ruta | Resultado | Causa raíz |
|---|---|---|
| **SSMS Wizard (Microsoft PKI)** | ❌ `Msg 2812: Could not find stored procedure 'sp_certificate_add_issuer'` | La SP solo existe en SQL Server 2022 CU13+, nunca llegará a SQL 2017. El wizard nuevo no tiene fallback compatible. |
| **T-SQL manual con `LISTENER_URL ... ;Server=[<MI_NAME>]`** | ❌ `Msg 19499: invalid listener URL` | SQL 2017 CU31-GDR rechaza la sintaxis `;Server=[…]` que el MI necesita para redirect interno. |
| **T-SQL manual sin `;Server=`** | ❌ Link queda en `LinkInitError`, error 41976, log "Tried to send redirect request but the redirect string is empty" | Sin la cláusula de redirect, MI no sabe a qué réplica lógica enviar la conexión. |

**SQL Server 2017 está en extended support hasta oct 2027 pero solo recibe parches GDR de seguridad
— no habrá nuevos CUs que arreglen esto**. Ver el walkthrough completo con capturas en
[`wizard-attempt-sql2017-walkthrough.md`](./wizard-attempt-sql2017-walkthrough.md).

**Workarounds**: upgrade SQL Server a 2019 CU15+ o 2022 CU13+, usar Azure DMS, BACPAC, o log shipping.

## Otras limitaciones de SQL Server 2017 (cuando sí funcione el link, ej. en 2019/2022)
| Limitación | Impacto | Mitigación |
|---|---|---|
| Solo replicación unidireccional (SQL → MI) en 2017 | No hay failback gestionado | Planificar cutover sin retorno; tener backup completo en SQL Server por si toca rollback manual |
| No hay "managed failover" en 2017 | El cutover es manual: poner BD read-only, esperar drain, romper DAG | Usar ventana de bajo tráfico + retry logic en la app |
| Requiere CU20+ (en teoría) | Imagen Marketplace trae CU17 | Instalar CU31 con `install-sql2017-cu31.ps1` — pero ver bloqueador arriba |
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
- ⚠️ SSMS 21.x intenta usar la ruta "Microsoft PKI" que requiere `sp_certificate_add_issuer` →
  **falla en SQL Server 2017** con `Msg 2812`. Solo funciona contra SQL Server 2022 CU13+.
- Si el wizard falla en el paso "Test connection MI → SQL Server", revisa NSG, firewall de Windows y el endpoint 5022 (`SELECT * FROM sys.tcp_endpoints`).
- El wizard de SSMS necesita **SQL Server Agent corriendo** (y `Agent XPs = 1`) en la VM para
  ejecutar los trabajos del Network Checker. Si lo ves desactivado:
  ```powershell
  Set-Service -Name SQLSERVERAGENT -StartupType Automatic
  Start-Service -Name SQLSERVERAGENT
  ```
  ```sql
  EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
  EXEC sp_configure 'Agent XPs', 1;             RECONFIGURE;
  ```
- En el diálogo `Connect to Server` de la MI, **cambia Authentication a `Microsoft Entra MFA`** —
  por defecto pone `Windows Authentication` y devuelve `Error 18452 untrusted domain` (la MI está
  AAD-only en tenants MCAPS).
- **Use public endpoint (if enabled)**: dejar **desmarcado** si tienes VNet peering al MI. Solo
  marcarlo si no hay conectividad privada.

## Certificados
- El wizard de SSMS gestiona el intercambio de certs automáticamente — pero **solo si SQL Server
  tiene la SP `sp_certificate_add_issuer`** (SQL 2022 CU13+). Si no, falla con `Msg 2812`.
- Manualmente: `BACKUP CERTIFICATE` en SQL Server, importar en MI con
  `New-AzSqlInstanceServerTrustCertificate` (o REST API
  `PUT .../serverTrustCertificates/{name}?api-version=2023-08-01` con body
  `{"properties":{"publicBlob":"<hex>"}}`), descargar el cert de MI con
  `Get-AzSqlInstanceServerTrustCertificate` o REST API
  `GET .../endpointCertificates?api-version=2023-08-01`, importar en SQL Server con
  `CREATE CERTIFICATE … FROM BINARY = 0x…`.

## URL parser del LISTENER_URL en versiones antiguas
- SQL Server 2017 (incluso CU31-GDR de oct 2024) **NO acepta** la sintaxis
  `tcp://<host>:5022;Server=[<MI_NAME>]` que el MI requiere para redirección interna —
  devuelve `Msg 19499 invalid listener URL`.
- SQL Server 2019 CU15+ y SQL Server 2022 RTM+ sí la aceptan. Para MI Link cross-region,
  usa al menos SQL 2019 CU15.
- Sin esa cláusula, el MI registra "Tried to send redirect request but the redirect string is
  empty" y el link queda en `LinkInitError` con error 41976.

## API versions de REST API para MI
- Las API versions disponibles para `Microsoft.Sql/managedInstances` y subrecursos cambian por
  región. Spain Central a fecha actual tiene de `2021-05-01-preview` a `2025-02-01-preview`.
- La versión **2022-08-01 NO funciona** en Spain Central (responde `NoRegisteredProviderFound`).
- Versión recomendada para scripts: `2023-08-01` (stable) o `2024-05-01-preview` si necesitas
  features nuevas.
- Consulta las disponibles con:
  ```bash
  az provider show --namespace Microsoft.Sql \
    --query "resourceTypes[?contains(resourceType,'distributedAvailabilityGroups')].apiVersions"
  ```
