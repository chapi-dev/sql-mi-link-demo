# HANDOFF: estado real del entorno y cómo retomarlo

> Documento creado al cerrar la sesión de demo automatizada y **actualizado en mayo 2026** tras
> resolver el bloqueo del wizard instalando el **Azure Connect Pack (KB5050533)**.
> Las **contraseñas y secretos NO están en este repo** — viven en tu
> sesión local (`session-state/856f30fa-.../files/handoff.json`).

## ✅ VEREDICTO TRAS LA SESIÓN (mayo 2026) — RESUELTO

**MI Link desde SQL Server 2017 a SQL Managed Instance cross-region FUNCIONA** una vez instalado el
**Azure Connect Pack (KB5050533, v14.0.3490.10)** sobre CU31-GDR. Sin ese paquete, las dos rutas
oficiales (SSMS Wizard y T-SQL manual) fallan.

| Camino | Antes de KB5050533 | Tras instalar KB5050533 |
|---|---|---|
| SSMS Wizard | ❌ `Msg 2812 sp_certificate_add_issuer` | ✅ **11/11 tareas Success**, link creado |
| T-SQL manual con `LISTENER_URL ... ;Server=[…]` | ❌ `Msg 19499 invalid listener URL` | ✅ parser acepta la sintaxis |
| T-SQL manual SIN `;Server=` | ❌ `error 41976 / LinkInitError` | n/a (ya no hace falta) |

Walkthrough completo en [`wizard-attempt-sql2017-walkthrough.md`](./wizard-attempt-sql2017-walkthrough.md).
Procedimiento de instalación del Connect Pack en
[`azure-connect-pack-install.md`](./azure-connect-pack-install.md).

**Estado de la replicación tras el segundo intento del wizard:**

- AG local `MILinkAG` en VM: `SYNCHRONIZED / HEALTHY`.
- Distributed AG `demo-link` (cross-region): `SYNCHRONIZING / HEALTHY` (modo `ASYNCHRONOUS_COMMIT`,
  es lo correcto en cross-region; `LogQueue=0`, `RedoQueue=0` = al día).
- Réplica en MI: `AG_DemoLink_MI` operativa.
- `DemoLink` visible en MI Object Explorer con todas sus carpetas (Tables, Views, Programmability…).
- Marker row `Id=504 VM-WIZARD-OK-LIVE` insertada en la VM y verificada presente en MI.

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
SELECT * FROM sys.server_trust_certificates;        -- SQLServerVMCert (subido por el wizard)
SELECT * FROM sys.database_mirroring_endpoints;     -- DBM STARTED
SELECT * FROM sys.availability_groups;              -- AG_DemoLink_MI (creado por el wizard)
SELECT * FROM sys.distributed_availability_groups;  -- demo-link
-- Verificar la BD replicada:
USE DemoLink;
SELECT TOP 5 Id, Origin, Note, InsertedAt FROM dbo.DemoRows ORDER BY Id DESC;
-- Debe incluir la fila marker Id=504 'VM-WIZARD-OK-LIVE'.
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

### Si la MI está parada (estado `Stopped` por auto-shutdown MCAPS)
```powershell
# OJO: el comando usa --mi, no -n
az sql mi start -g rg-sqlmilink-mi-esp --mi mi-link-demo-fraesp --no-wait
# Polling del estado (de Starting → Ready puede tardar 5-30 min)
az sql mi show -g rg-sqlmilink-mi-esp -n mi-link-demo-fraesp --query state -o tsv
```

## Lo que falta probar (sugerencias)

> **Actualización mayo 2026 (día 2)**: tras instalar el **Azure Connect Pack (KB5050533)** en la VM,
> tanto el SSMS Wizard como la ruta T-SQL manual completan correctamente. El walkthrough con la
> resolución está en [`wizard-attempt-sql2017-walkthrough.md`](./wizard-attempt-sql2017-walkthrough.md)
> y la receta de instalación del paquete en
> [`azure-connect-pack-install.md`](./azure-connect-pack-install.md).

### Opción 1 (✅ RESUELTA): SSMS Wizard
1. Asegúrate de que la VM tiene **CU31-GDR + Azure Connect Pack (14.0.3490.10)**: 
   `SELECT @@VERSION` debe devolver `14.0.3490.10` o superior.
2. Conecta SSMS al SQL Server VM (Public IP o RDP, Windows auth).
3. Click derecho `DemoLink` → Tasks → Azure SQL Managed Instance link → New.
4. Sigue el wizard. **Resultado real (con Connect Pack instalado)**: **11/11 tareas Success**,
   Distributed AG `demo-link` creado y replicando.

### Opción 2 (✅ FUNCIONA): T-SQL manual + REST API
Útil si quieres scriptar el setup sin SSMS.
1. Crear el cert en SQL Server, exportar `.cer`, subirlo a MI vía REST API
   (`PUT .../serverTrustCertificates/<name>?api-version=2023-08-01`).
2. Crear el AG local clusterless en SQL Server con `DemoLink`.
3. Crear el Distributed AG en SQL Server con la sintaxis completa
   `LISTENER_URL = N'tcp://<MI_FQDN>:5022;Server=[<MI_NAME>]'` (el Azure Connect Pack añade
   soporte de este parser).
4. Crear el lado MI con `PUT .../distributedAvailabilityGroups/<name>?api-version=2023-08-01`.

### Opción 3 (alternativa): upgrade SQL Server
Si quieres evitar el paquete extra, puedes ir directamente a:
- SQL Server 2019 CU15+ (acepta el parser nativamente).
- SQL Server 2022 CU13+ (recomendado, soporta managed failover y failback bidireccional).
La infra de red existente (VNet peering, MI, NSG, certs subidos) es reutilizable.

### Opción 4: Migración alternativa (si no quieres MI Link)
- **Azure DMS** offline si aceptas downtime de horas.
- **BACPAC export/import** si la BD es pequeña.
- **Log shipping manual** (BACKUP/RESTORE periódico).

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
| 41976 | Encrypt/decrypt endpoint msg / LinkInitError | **Causa real (resuelta en mayo 2026 día 2)**: faltaba el Azure Connect Pack (KB5050533) en SQL Server 2017. Sin él, la `LISTENER_URL` no podía llevar `;Server=[…]` y MI registraba "redirect string is empty". **Fix: instalar KB5050533** → el parser acepta la sintaxis y el link se establece. |
| 2812  | `Could not find stored procedure 'sp_certificate_add_issuer'` | En SQL 2017 esta SP la añade el **Azure Connect Pack (KB5050533)**. En SQL 2022 viene a partir de CU13. **Fix: instalar KB5050533**. |
| 18452 | Login from untrusted domain (Integrated Auth) | Cambiar el dropdown de Auth de "Windows Authentication" a "Microsoft Entra MFA" en el diálogo Connect to Server. La MI MCAPS es AAD-only. |
| 19499 | Specified listener URL is invalid | En SQL 2017 sin Azure Connect Pack, el parser rechaza `;Server=[…]`. **Fix: instalar KB5050533** (extiende el parser). |
| 40532 | Cannot open server requested by the login | La MI está apagada (estado `Stopped` por auto-shutdown MCAPS). Arrancarla: `az sql mi start -g <RG> --mi <name> --no-wait` (ojo: usa `--mi`, no `-n`). |
