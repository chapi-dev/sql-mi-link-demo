# HANDOFF: estado real del entorno y cómo retomarlo

> Documento creado al cerrar la sesión de demo automatizada.
> Las **contraseñas y secretos NO están en este repo** — viven en tu
> sesión local (`session-state/856f30fa-.../files/handoff.json`).

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

### Opción 1 (recomendada): SSMS Wizard
1. Conecta SSMS al SQL Server VM (via Public IP, SQL Auth con `sa` / pwd del handoff, o Windows auth via RDP).
2. Click derecho `DemoLink` → Tasks → Azure SQL Managed Instance link → New.
3. Sigue el wizard (necesitarás credenciales Azure válidas).

### Opción 2: Reintentar setup manual con cert distinto
El error 41976 (encrypt msg) puede ser por mismatch de algoritmo. Prueba:
```sql
-- En SQL Server VM, recrear endpoint con AES explícito y RC4 fallback
USE master;
ALTER ENDPOINT [Hadr_endpoint]
FOR DATABASE_MIRRORING (
    AUTHENTICATION = CERTIFICATE MILinkCert,
    ENCRYPTION = REQUIRED ALGORITHM AES,
    ROLE = ALL
);
GO
```

### Opción 3: Capturar tráfico para diagnóstico
En la VM:
```powershell
netsh trace start capture=yes tracefile=C:\MILink\trace.etl IPv4.Address=10.20.0.0/24
# Lanzar el create DAG desde la API
# ...
netsh trace stop
# Analizar trace.etl con Microsoft Message Analyzer o Wireshark
```

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
| 41976 | Encrypt/decrypt endpoint msg | **Sin resolver** — probable mismatch algoritmo/padding |
