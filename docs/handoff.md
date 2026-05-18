# HANDOFF: estado real del entorno y cómo retomarlo

> Documento creado al cerrar la sesión de demo automatizada y **actualizado en mayo 2026** tras la
> sesión de validación del SSMS Wizard.
> Las **contraseñas y secretos NO están en este repo** — viven en tu
> sesión local (`session-state/856f30fa-.../files/handoff.json`).

## ⚠️ VEREDICTO TRAS LA SESIÓN DEL WIZARD (mayo 2026)

**MI Link desde SQL Server 2017 CU31-GDR a SQL Managed Instance NO se puede completar** con la
última versión disponible de SQL 2017. Ver el walkthrough exhaustivo con capturas:
[`wizard-attempt-sql2017-walkthrough.md`](./wizard-attempt-sql2017-walkthrough.md).

Resumen del bloqueo (los dos caminos oficiales fallan):

| Camino | Error | Por qué |
|---|---|---|
| SSMS Wizard | `Msg 2812: Could not find stored procedure 'sp_certificate_add_issuer'` | SP solo existe en SQL 2022 CU13+ |
| T-SQL manual con `LISTENER_URL ... ;Server=[…]` | `Msg 19499: invalid listener URL` | URL parser de SQL 2017 no acepta el sufijo |
| T-SQL manual SIN `;Server=` | `error 41976 / LinkInitError`, log "redirect string is empty" | MI necesita el redirect string para enrutar |

**Lo importante**: la red, los NSG, el peering, los certs, el endpoint 5022 y la auth AAD están
**todos validados como correctos por el propio wizard de SSMS** (Network Checker 11/11 verde,
Validation 8/8 verde). El bloqueo es de la **versión del engine**, no del entorno.

Para que la demo funcione end-to-end, hay que upgradear a SQL Server 2019 CU15+ o 2022 CU13+.

## Recursos desplegados (LIVE)

| Recurso | Detalle |
|---|---|
| Suscripción | `ME-MngEnvMCAP184496-antonioch-1` (57b74ad7-4e8a-4221-b993-59b7df78c096) |
| RG VM | `rg-sqlmilink-vm-fra` (France Central) |
| RG MI | `rg-sqlmilink-mi-esp` (Spain Central) |
| VM | `vm-sql2017` Standard_L2as_v4, IP pública `20.199.105.61`, privada `10.10.1.4` |
| MI | `mi-link-demo-fraesp` FQDN privado `mi-link-demo-fraesp.332838295123.database.windows.net` |
| MI Public Endpoint | `mi-link-demo-fraesp.public.332838295123.database.windows.net,3342` |
| Private DNS | Zona `sqllink.internal` con A record `vm-sql2017 → 10.10.1.4` |
| Auth MI | AAD-only, admin = `admin@MngEnvMCAP184496.onmicrosoft.com` |
| Free MI offer | No aplicado (Spain Central no admite). MI es pago (~$25/día). |

## Estado lógico SQL listo para link

### En el SQL Server (VM)
```sql
SELECT name, port, state_desc FROM sys.tcp_endpoints WHERE name='Hadr_endpoint';
SELECT name FROM sys.certificates WHERE name IN ('MILinkCert','MICert');
SELECT name FROM sys.server_principals WHERE name='MIAGLogin';
SELECT name, recovery_model_desc FROM sys.databases WHERE name='DemoLink';
SELECT name FROM sys.availability_groups;
```
Esperado:
- Endpoint `Hadr_endpoint` STARTED en 5022.
- Cert `MILinkCert` (del SQL) y `MICert` (importado del MI).
- Login `MIAGLogin` con CONNECT en endpoint.
- DB `DemoLink` en FULL con 3 filas seed.
- AG `MILinkAG` clusterless con DemoLink SYNCHRONIZED.

### En el MI
```sql
-- Conecta con: mi-link-demo-fraesp.public.332838295123.database.windows.net,3342
-- Auth: AAD interactive (admin@MngEnvMCAP184496.onmicrosoft.com)
SELECT * FROM sys.server_trust_certificates;        -- debe aparecer SQLServerVMCert
SELECT * FROM sys.database_mirroring_endpoints;     -- DBM STARTED
SELECT * FROM sys.availability_groups;              -- (vacío tras el último cleanup)
```

## Conectar desde tu máquina

### A la VM (RDP)
```powershell
mstsc /v:20.199.105.61
# usuario: azureuser
# password: ver handoff.json
```

### Al MI (SSMS o sqlcmd)
1. Asegúrate de que tu IP pública esté permitida en NSG:
```powershell
$myIp = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing).Content.Trim()
az network nsg rule update -g rg-sqlmilink-mi-esp --nsg-name nsg-mi-esp `
  -n allow_my_ip_3342 --source-address-prefixes "$myIp/32"
```
2. SSMS:
   - Server: `mi-link-demo-fraesp.public.332838295123.database.windows.net,3342`
   - Auth: **Azure Active Directory - Universal with MFA**
   - User: `admin@MngEnvMCAP184496.onmicrosoft.com`
   - Encrypt: True; Trust Server Cert: False

### Si la VM está deallocated (MCAPS auto-shutdown)
```powershell
az vm start -g rg-sqlmilink-vm-fra -n vm-sql2017
```

## Lo que falta probar (sugerencias)

> **Actualización mayo 2026**: las opciones 1 y 2 ya se probaron y ambas fallan estructuralmente en
> SQL Server 2017 CU31-GDR. Ver [`wizard-attempt-sql2017-walkthrough.md`](./wizard-attempt-sql2017-walkthrough.md).

### Opción 1 (PROBADA - FALLA): SSMS Wizard
1. Conecta SSMS al SQL Server VM (via Public IP, SQL Auth con `sa` / pwd del handoff, o Windows auth via RDP).
2. Click derecho `DemoLink` → Tasks → Azure SQL Managed Instance link → New.
3. Sigue el wizard. **Resultado real**: falla en el step "Create Microsoft PKI certificate" con
   `Msg 2812: Could not find stored procedure 'sp_certificate_add_issuer'`. La SP solo existe en
   SQL Server 2022 CU13+.

### Opción 2 (PROBADA - FALLA): T-SQL manual + REST API
1. Reusar el cert `MILinkCert` ya existente en master.
2. Subirlo al MI como ServerTrustCertificate vía REST API
   (`PUT .../serverTrustCertificates/SQLServerVMCert?api-version=2023-08-01`) — **funciona**.
3. Crear el Distributed AG en SQL Server vía `CREATE AVAILABILITY GROUP [MILinkDAG] WITH (DISTRIBUTED)…`
   — funciona **sin** la cláusula `;Server=[<MI_NAME>]`; con ella SQL 2017 devuelve
   `Msg 19499 invalid listener URL`.
4. Crear el lado MI vía `PUT .../distributedAvailabilityGroups/MILinkDAG?api-version=2023-08-01` —
   API acepta pero replica queda en `LinkInitError` / `error 41976` porque sin redirect string el MI
   no sabe a qué réplica lógica enrutar.

### Opción 3 (RECOMENDADA): upgrade SQL Server
- Provisionar otra VM con SQL Server 2019 CU15+ o SQL Server 2022 CU13+.
- Reutilizar toda la infra de red existente (VNet peering, MI, NSG, etc.).
- Reusar el cert `SQLServerVMCert` que ya está subido al MI o regenerar.
- Esto SÍ permitiría completar el link end-to-end.

### Opción 4: Migración alternativa
- **Azure DMS** offline si aceptas downtime de horas.
- **BACPAC export/import** si la BD es pequeña.
- **Log shipping manual** (BACKUP/RESTORE periódico) si quieres mantener SQL 2017 como origen.

## Si quieres apagar todo para no pagar

```powershell
# Solo parar VM (mantiene MI corriendo, ~$25/día)
az vm deallocate -g rg-sqlmilink-vm-fra -n vm-sql2017

# Borrar TODO (recomendado si ya no necesitas la demo)
az group delete -n rg-sqlmilink-vm-fra --yes --no-wait
az group delete -n rg-sqlmilink-mi-esp --yes --no-wait
az network private-dns zone delete -g rg-sqlmilink-vm-fra -n sqllink.internal --yes
```

## Resumen de scripts útiles en este repo

| Script | Para qué |
|---|---|
| `scripts/01-infra.ps1` | Provisionar todo desde cero |
| `scripts/setup-sql-v3.ps1` | Setup completo SQL Server lado VM (necesita `$env:MASTER_KEY_PWD`) |
| `scripts/elevate-v2.ps1` | Workaround para hacer SYSTEM sysadmin (single-user mode) |
| `scripts/create-ag.ps1` | Crea AG local clusterless |
| `scripts/import-mi-cert.ps1` | Importa cert MI en SQL Server con login + GRANT |
| `scripts/check-ports.ps1` | Diagnóstico ports y Firewall en VM |
| `scripts/cleanup.ps1` | Borra los RGs |

## Códigos de error que vimos

| Code | Significado | Cómo lo arreglamos |
|---|---|---|
| 41986 | No TCP a endpoint | Abrir 5022 en Windows Firewall de la VM (la NSG no basta) |
| 41974 | Auth/handshake falla | Importar cert MI + GRANT CONNECT al login |
| 41976 | Encrypt/decrypt endpoint msg | **Confirmado en sesión mayo 2026: bloqueador estructural de SQL Server 2017.** Causa real: SQL 2017 no acepta `;Server=[…]` en LISTENER_URL → MI no puede hacer redirect interno → registra "Tried to send redirect request but the redirect string is empty" y el link queda en LinkInitError. **No tiene fix en SQL 2017; requiere SQL 2019 CU15+ o 2022 CU13+.** |
| 2812  | `Could not find stored procedure 'sp_certificate_add_issuer'` | SP solo existe en SQL 2022 CU13+. El wizard SSMS 21.x intenta usarla siempre. **No tiene fix en SQL 2017**. |
| 18452 | Login from untrusted domain (Integrated Auth) | Cambiar el dropdown de Auth de "Windows Authentication" a "Microsoft Entra MFA" en el diálogo Connect to Server. La MI MCAPS es AAD-only. |
| 19499 | Specified listener URL is invalid | SQL Server 2017 rechaza `;Server=[…]` en LISTENER_URL. **No tiene fix en SQL 2017**. |
