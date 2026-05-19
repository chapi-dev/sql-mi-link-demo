# Gotchas y limitaciones conocidas

## ✅ Requisito obligatorio en SQL Server 2017: Azure Connect Pack (KB5050533)

Para que MI Link funcione con SQL Server 2017 hay que instalar **DOS** paquetes en orden:

1. **CU31** (`14.0.3456.2`) o un GDR posterior (p. ej. `CU31-GDR KB5046858 14.0.3485.1`).
2. **Azure Connect Pack — KB5050533 — v14.0.3490.10** (publicado el 6-marzo-2025).
   👉 [Página oficial](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect)

Sin el Azure Connect Pack obtendrás **uno de estos errores** intentando crear el link:

| Ruta | Error sin Azure Connect Pack | Por qué |
|---|---|---|
| **SSMS Wizard (Microsoft PKI)** | `Msg 2812: Could not find stored procedure 'sp_certificate_add_issuer'` | La SP la añade el Connect Pack. |
| **T-SQL manual con `LISTENER_URL ... ;Server=[<MI_NAME>]`** | `Msg 19499: invalid listener URL` | El parser de SQL 2017 no acepta `;Server=[…]` hasta que el Connect Pack lo extiende. |
| **T-SQL manual sin `;Server=`** | `error 41976 / LinkInitError`, log "Tried to send redirect request but the redirect string is empty" | Sin `;Server=` el MI no sabe a qué réplica lógica enrutar. |

Procedimiento detallado de descarga e instalación (BITS + silent install) en
[`azure-connect-pack-install.md`](./azure-connect-pack-install.md).

**Validación rápida post-install (debe devolver 1 fila):**
```sql
SELECT @@VERSION;  -- Debe ser 14.0.3490.10 (o superior)
SELECT name FROM sys.system_objects
 WHERE name IN ('sp_certificate_add_issuer','sp_get_endpoint_certificate');
```

## Limitaciones operativas reales de SQL Server 2017 (con MI Link funcionando)
| Limitación | Impacto | Mitigación |
|---|---|---|
| Solo replicación unidireccional (SQL → MI) | No hay failback gestionado (eso es de SQL 2022 CU13+) | Planificar cutover sin retorno; tener backup completo en SQL Server por si toca rollback manual |
| No hay "managed failover" en 2017 | El cutover es manual: poner BD read-only, esperar drain, romper DAG | Usar ventana de bajo tráfico + retry logic en la app |
| Cross-region usa `ASYNCHRONOUS_COMMIT` | Estado normal = `SYNCHRONIZING / HEALTHY` (no `SYNCHRONIZED`) | Monitorizar `LogQueue` y `RedoQueue` — si crecen, hay lag |
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
- ⚠️ SSMS 21.x usa la ruta "Microsoft PKI" que requiere `sp_certificate_add_issuer` →
  **en SQL Server 2017 esa SP la trae el Azure Connect Pack (KB5050533)**. Sin el Connect Pack,
  el wizard falla con `Msg 2812`. Solución: instalar el Connect Pack (ver arriba).
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
  tiene la SP `sp_certificate_add_issuer`** (en SQL 2017 la añade el **Azure Connect Pack
  KB5050533**; en SQL 2022 viene a partir de CU13). Sin esa SP, falla con `Msg 2812`.
- Manualmente: `BACKUP CERTIFICATE` en SQL Server, importar en MI con
  `New-AzSqlInstanceServerTrustCertificate` (o REST API
  `PUT .../serverTrustCertificates/{name}?api-version=2023-08-01` con body
  `{"properties":{"publicBlob":"<hex>"}}`), descargar el cert de MI con
  `Get-AzSqlInstanceServerTrustCertificate` o REST API
  `GET .../endpointCertificates?api-version=2023-08-01`, importar en SQL Server con
  `CREATE CERTIFICATE … FROM BINARY = 0x…`.

## URL parser del LISTENER_URL en SQL Server 2017
- **Sin Azure Connect Pack**: SQL Server 2017 (incluso CU31-GDR) **rechaza**
  `tcp://<host>:5022;Server=[<MI_NAME>]` con `Msg 19499 invalid listener URL`.
- **Con Azure Connect Pack (KB5050533)**: el parser acepta la sintaxis y el wizard / T-SQL manual
  pueden establecer el link correctamente.
- SQL Server 2019 CU15+ y SQL Server 2022 RTM+ aceptan la sintaxis nativamente sin paquetes extra.

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
