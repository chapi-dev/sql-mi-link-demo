# Azure Connect Pack para SQL Server (KB5050533)

Componente que añade a SQL Server 2017/2019/2022 las **store procedures y
extensiones de parser** necesarias para que MI Link funcione contra Azure SQL
Managed Instance.

> Nombre oficial: *Azure extension for SQL Server*.
> KB asociado: [KB5050533](https://support.microsoft.com/topic/kb5050533).

## Qué añade

| Componente | Para qué sirve |
|---|---|
| `sys.sp_certificate_add_issuer` | Registra certificados emitidos por una CA distinta. Necesario para el cert exchange con MI. |
| `sys.sp_get_endpoint_certificate` | Devuelve el cert del endpoint del mirror local en formato exportable. |
| Extensión del parser `LISTENER_URL` | Permite la sintaxis `;Server=[<MI_NAME>]` en `LISTENER_URL` del DAG, requerida para apuntar al MI. |
| Telemetría / health | Endpoints internos que el portal de Azure usa para mostrar el estado del Link en la UI. |

Sin este pack la creación del Distributed AG **falla** con errores genéricos del
parser o con `41986: Cannot promote AG to distributed` durante el handshake con
el MI.

## Versiones mínimas de SQL Server

| Versión SQL Server | CU mínimo | Notas |
|---|---|---|
| SQL Server 2016 | – | ⚠️ MI Link **no soportado** en 2016 |
| SQL Server 2017 | **CU31+** | Azure Connect Pack es obligatorio |
| SQL Server 2019 | CU27+ | Azure Connect Pack ya incluido en CU27+ |
| SQL Server 2022 | CU13+ | Azure Connect Pack ya incluido |
| SQL Server 2025 | RTM | Incluido nativo |

Consultar [supported version matrix](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-feature-overview#supported-sql-server-versions)
para la última matriz oficial.

> **Para SQL Server 2017** este pack es **obligatorio** y se instala como un
> componente aparte después del CU.

---

## Instalación en SQL Server 2017

### Pre-requisitos

- SQL Server 2017 **CU31** o superior instalado. Verificar:
  ```sql
  SELECT @@VERSION;
  -- Debe mostrar 14.0.3500.x o superior.
  ```
- Acceso de administrador local a la VM.
- PowerShell ejecutado como administrador.
- Outbound 443 desde la VM al CDN de Microsoft (o paquete descargado offline).

### Procedimiento

1. **Descargar el instalador** desde el portal de Microsoft.

   Si la VM tiene salida a internet, usar BITS:
   ```powershell
   $url  = "https://download.microsoft.com/download/.../SqlAzureExtension.msi"
   $dest = "C:\install\SqlAzureExtension.msi"
   New-Item -Type Directory -Force -Path (Split-Path $dest) | Out-Null

   Start-BitsTransfer -Source $url -Destination $dest
   ```

   Si la VM **no** tiene salida a internet, descargar el paquete en otra máquina
   y copiarlo vía SMB/Storage account.

2. **Instalación silenciosa**:
   ```powershell
   Start-Process -FilePath "msiexec.exe" `
       -ArgumentList "/i $dest /qn /norestart /l*v C:\install\sqlext-install.log" `
       -Wait -PassThru
   ```

3. **Reiniciar el servicio de SQL Server**:
   ```powershell
   Restart-Service -Name "MSSQLSERVER" -Force
   ```

   > El instalador **no** reinicia SQL Server automáticamente. Si no se reinicia,
   > las nuevas stored procedures no se cargan y la creación del DAG falla.

### Verificación post-install

1. Confirmar que las stored procedures existen:
   ```sql
   SELECT name
   FROM sys.system_objects
   WHERE name IN ('sp_certificate_add_issuer', 'sp_get_endpoint_certificate');
   -- Deben devolver 2 filas.
   ```

2. Confirmar que el parser acepta la sintaxis `;Server=[…]`:
   ```sql
   -- Esto es una validación SOLO de parser; no creates aún:
   SELECT 'OK' WHERE 1 = 1
   -- Si falla, no es un problema. La validación real es al crear el DAG:
   ALTER AVAILABILITY GROUP [<LocalAG>]
       ADD AVAILABILITY GROUP ON
           N'<LocalAG>'   WITH (LISTENER_URL = 'TCP://<vm-fqdn>:5022', ...),
           N'<DAGName>'   WITH (LISTENER_URL = 'TCP://<mi-fqdn>:5022;Server=[<MI_NAME>]', ...);
   ```
   Si el parser está mal cargado, falla en este paso con un error de sintaxis
   en `LISTENER_URL`.

3. Verificar logs de instalación:
   ```powershell
   Get-Content C:\install\sqlext-install.log -Tail 40
   ```
   Buscar `Installation completed successfully` o `Product: ... Installation completed successfully`.

---

## Instalación offline (sin internet en la VM)

Para VMs en redes aisladas:

1. **En una máquina con internet**: descargar el .msi.
2. **Subir al storage de la suscripción** (con private endpoint si aplica):
   ```powershell
   az storage blob upload `
     --account-name <storage> `
     --container-name installers `
     --name SqlAzureExtension.msi `
     --file SqlAzureExtension.msi `
     --auth-mode login
   ```
3. **Desde la VM**, descargar con AzCopy + managed identity:
   ```powershell
   azcopy login --identity
   azcopy copy "https://<storage>.blob.core.windows.net/installers/SqlAzureExtension.msi" `
     "C:\install\SqlAzureExtension.msi"
   ```
4. Instalar con `msiexec` como en el paso 2 anterior.

---

## Troubleshooting

### El instalador devuelve `1603`

Causa habitual: el servicio de SQL Server no está corriendo en el momento de la
instalación. El instalador necesita poder consultar la instancia para registrar
los componentes correctamente.

**Fix**: arrancar `MSSQLSERVER` antes del `msiexec`:
```powershell
Start-Service -Name MSSQLSERVER
Start-Process msiexec.exe -ArgumentList "/i C:\install\SqlAzureExtension.msi /qn /norestart" -Wait
```

### Tras el install, `sp_get_endpoint_certificate` sigue sin existir

Causa: SQL Server no se reinició después del install. Las stored procedures se
cargan al startup.

**Fix**:
```powershell
Restart-Service MSSQLSERVER -Force
```

Luego volver a comprobar con `SELECT name FROM sys.system_objects WHERE name = 'sp_get_endpoint_certificate';`.

### DAG creation falla con `41986` aunque el cert exchange completó

Causa típica: el parser de `LISTENER_URL` no acepta la sintaxis `;Server=[…]`
porque la extensión del Azure Connect Pack no está cargada (instalador OK pero
SQL no reiniciado, o instalador ejecutado en una instancia distinta).

**Fix**: confirmar la instalación con la verificación de arriba, reiniciar
`MSSQLSERVER` y reintentar el DAG.

### Conflictos con varias instancias de SQL Server

Si la VM tiene múltiples instancias (default + named), el instalador del Azure
Connect Pack se aplica a la instancia por defecto. Para instancias nombradas,
consultar la documentación oficial del KB sobre parámetros adicionales.

---

## Referencias

- [KB5050533 — Azure Connect Pack for SQL Server](https://support.microsoft.com/topic/kb5050533)
- [Configure Managed Instance link — prerequisites](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-preparation)
- [Latest cumulative update for SQL Server 2017](https://learn.microsoft.com/sql/database-engine/install-windows/latest-updates-for-microsoft-sql-server)
