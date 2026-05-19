# SQL Server 2017 Azure Connect Pack (KB5050533) — descarga e instalación

> Este es el **paquete crítico** que SQL Server 2017 necesita para participar en MI Link
> (además de CU31 o GDR equivalente). Sin él, el SSMS Wizard falla con
> `Msg 2812 sp_certificate_add_issuer` y la ruta T-SQL manual falla con `Msg 19499 invalid
> listener URL`. Página oficial:
> [learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect)

## Datos del paquete

| Campo | Valor |
|---|---|
| KB | **KB5050533** |
| Versión engine resultante | `14.0.3490.10` |
| Fecha de publicación | 6 de marzo de 2025 |
| Tamaño | ~542 MB |
| Requisito previo | SQL Server 2017 con **CU31** (`14.0.3456.2`) o GDR posterior |
| Reinicio | No reinicia el SO, pero **reinicia `MSSQLSERVER` y `SQLSERVERAGENT`** durante el setup |

## Lo que añade

- SP **`sp_certificate_add_issuer`** (usada por el wizard SSMS en la fase "Create Microsoft PKI
  certificate").
- SP **`sp_get_endpoint_certificate`**.
- Extiende el parser de `LISTENER_URL` para aceptar la sintaxis
  `tcp://<host>:5022;Server=[<MI_NAME>]` que la MI necesita para redirigir las conexiones a la
  réplica lógica correcta.
- Mejoras varias en Distributed AGs, certificate-based auth y telemetría para Azure-related
  scenarios.

## Validación previa: ¿necesito el paquete?

Ejecuta en SQL Server:

```sql
SELECT
  SERVERPROPERTY('ProductVersion')          AS Version,
  SERVERPROPERTY('ProductLevel')            AS Level,
  SERVERPROPERTY('ProductUpdateLevel')      AS UpdateLevel,
  SERVERPROPERTY('ProductUpdateReference')  AS UpdateKB;

SELECT name FROM sys.system_objects
 WHERE name IN ('sp_certificate_add_issuer','sp_get_endpoint_certificate');
```

- Si `Version` < `14.0.3490.10` → necesitas instalar KB5050533.
- Si el `SELECT name` devuelve **0 filas** → no tienes el Connect Pack.
- Si ya devuelve ambas SPs y la versión es 14.0.3490.10 (o superior dentro de la rama 2017),
  ya está instalado y no hay que hacer nada.

## Receta usada en la demo

La VM de la demo es `vm-sql2017` en France Central. Todo se ejecutó desde fuera vía
`az vm run-command invoke`. La descarga del instalador tarda lo suficiente como para superar el
timeout de `run-command` (~3 min); por eso se usa **BITS asíncrono**.

### Paso 1: descarga vía BITS (async)

```powershell
az vm run-command invoke -g rg-sqlmilink-vm-fra -n vm-sql2017 `
  --command-id RunPowerShellScript --scripts @"
New-Item -ItemType Directory -Force -Path 'C:\MILink' | Out-Null
\$url  = 'https://catalog.s.download.windowsupdate.com/d/msdownload/update/software/updt/2025/03/sqlserver2017-kb5050533-x64_79f01499da6cfdddd94de9d35835e7408e3cd462.exe'
\$dest = 'C:\MILink\KB5050533-AzureConnect.exe'
Start-BitsTransfer -Source \$url -Destination \$dest -Asynchronous -DisplayName 'KB5050533'
Get-BitsTransfer -Name 'KB5050533' | Format-List JobState, BytesTotal, BytesTransferred
"@
```

> La URL viene del **Microsoft Update Catalog** (búsqueda por "KB5050533"). Si Microsoft la rota,
> ve a [catalog.update.microsoft.com](https://www.catalog.update.microsoft.com/Search.aspx?q=KB5050533)
> y copia la URL del paquete x64.

### Paso 2: polling hasta `Transferred`

```powershell
az vm run-command invoke -g rg-sqlmilink-vm-fra -n vm-sql2017 `
  --command-id RunPowerShellScript --scripts @"
\$job = Get-BitsTransfer -Name 'KB5050533'
'JobState: ' + \$job.JobState
'Bytes: '    + \$job.BytesTransferred + ' / ' + \$job.BytesTotal
if (\$job.JobState -eq 'Transferred') { Complete-BitsTransfer -BitsJob \$job }
"@
```

Repetir hasta que el `JobState` sea `Transferred` y se haga `Complete-BitsTransfer`. Con conexión
buena tarda ~5-10 min.

### Paso 3: instalación silenciosa

```powershell
az vm run-command invoke -g rg-sqlmilink-vm-fra -n vm-sql2017 `
  --command-id RunPowerShellScript --scripts @"
\$installer = 'C:\MILink\KB5050533-AzureConnect.exe'
\$logDir    = 'C:\MILink\install-logs'
New-Item -ItemType Directory -Force -Path \$logDir | Out-Null
Start-Process -FilePath \$installer `
  -ArgumentList '/quiet','/allinstances','/IAcceptSQLServerLicenseTerms' `
  -Wait -PassThru | Select-Object ExitCode
"@
```

El instalador tarda **~10-15 min**. Durante ese tiempo `MSSQLSERVER` y `SQLSERVERAGENT` se reinician.
Si `Start-Process` no devuelve antes del timeout de `run-command`, no pasa nada: el instalador sigue
corriendo en la VM, y se puede polear en el siguiente paso.

### Paso 4: verificación post-instalación

```powershell
az vm run-command invoke -g rg-sqlmilink-vm-fra -n vm-sql2017 `
  --command-id RunPowerShellScript --scripts @"
Get-Service MSSQLSERVER, SQLSERVERAGENT | Format-Table Name, Status
sqlcmd -E -S . -Q 'SELECT SERVERPROPERTY(''ProductVersion'') AS Version; SELECT name FROM sys.system_objects WHERE name IN (''sp_certificate_add_issuer'',''sp_get_endpoint_certificate'');'
"@
```

Esperado:
- Servicios `MSSQLSERVER` y `SQLSERVERAGENT` en `Running`.
- `Version` = `14.0.3490.10`.
- `sp_certificate_add_issuer` y `sp_get_endpoint_certificate` presentes en `sys.system_objects`.

### Logs del setup

Si algo falla, el log resumen está en la VM en:
```
C:\Program Files\Microsoft SQL Server\140\Setup Bootstrap\Log\Summary.txt
```
Logs detallados de cada paso en `C:\Program Files\Microsoft SQL Server\140\Setup Bootstrap\Log\<fecha>\`.

## Después de instalar

1. **Limpiar restos del intento fallido** (si previamente probaste el wizard o T-SQL manual y dejó
   un Distributed AG en `LinkInitError`):
   - Borrar el DAG en la MI: `DELETE .../distributedAvailabilityGroups/<name>?api-version=2023-08-01`.
   - Borrar el cert subido a la MI: `DELETE .../serverTrustCertificates/<name>?api-version=2023-08-01`.
   - Borrar el DAG en la VM: `DROP AVAILABILITY GROUP <name>;` (si quedó alguno).
   - Dejar el AG local con la BD en SYNCHRONIZED.
2. Volver a lanzar el SSMS Wizard contra la misma BD: ahora pasará "Create Microsoft PKI certificate"
   sin error y completará las 11 tareas.

## Alternativa: descarga manual desde el Update Catalog

Si no tienes BITS o el `az vm run-command` no es viable, descarga el `.exe` desde tu máquina y
súbelo a la VM (RDP + Copy-Paste, Blob Storage, Azure Files, etc.):

1. https://www.catalog.update.microsoft.com/Search.aspx?q=KB5050533
2. Click en la versión x64 → **Download** → copia la URL del `.exe`.
3. En la VM: ejecuta el `.exe` con doble click (UI) o con
   `setup.exe /quiet /allinstances /IAcceptSQLServerLicenseTerms` para silent install.

## Referencias

- [Página oficial KB5050533 (Azure Connect Pack)](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/azureconnect)
- [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/Search.aspx?q=KB5050533)
- [Latest updates for SQL Server (matriz general)](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/latest-updates-for-microsoft-sql-server)
- [MI Link prerequisites (matriz oficial)](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-preparation)
