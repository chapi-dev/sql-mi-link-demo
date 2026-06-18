# Migración de objetos out-of-band

El Distributed AG **sólo replica el contenido de la base de datos**: schema, tablas,
datos, índices, procs, vistas, usuarios de BD, permisos a nivel de BD. **No replica**
nada que viva fuera del archivo `.mdf/.ldf`.

> 💥 **Sin migrar estos objetos, la app no funciona post-cutover.** Es la fuente #1 de
> incidentes en migraciones cross-instance. Tratar este documento como obligatorio.

---

## 1. Inventario completo de objetos a migrar

| Categoría | Objeto | Crítico | Cuándo migrar | Sección |
|---|---|---|---|---|
| Seguridad | Logins (SQL y Windows) | 🔴 | Pre-cutover | §3 |
| Seguridad | Server roles | 🟠 | Pre-cutover | §4 |
| Seguridad | Credentials | 🔴 si TDE / Backup to URL | Pre-cutover | §5 |
| Seguridad | Server-level certs | 🔴 si TDE / endpoints | Pre-cutover | §6 |
| Seguridad | Service Master Key (TDE) | 🔴 si TDE | Pre-cutover | §6 |
| Seguridad | Audit specifications | 🟡 | Post-cutover | §7 |
| Configuración | sp_configure settings | 🟠 | Pre-cutover | §8 |
| Configuración | Trace flags | 🟠 | Pre-cutover | §8 |
| Configuración | TempDB layout | 🟠 | Pre-instalación | §8 |
| Configuración | Resource Governor | 🟡 | Pre-cutover | §8 |
| SQL Agent | Jobs + schedules | 🔴 | Pre-cutover (disabled) | §9 |
| SQL Agent | Operators | 🟠 | Pre-cutover | §9 |
| SQL Agent | Alerts | 🟠 | Pre-cutover | §9 |
| SQL Agent | Proxies | 🟡 | Pre-cutover | §9 |
| Conectividad | Linked servers | 🔴 si usados | Pre-cutover | §10 |
| Conectividad | Database Mail profiles | 🟠 si usados | Pre-cutover | §11 |
| Replicación | Publicaciones / suscripciones | 🔴 si usadas | Especial — ver §12 |
| Avanzado | Server triggers | 🟡 | Pre-cutover | §13 |
| Avanzado | External Data Sources | 🟠 si usados | Post-cutover | §14 |
| Avanzado | PolyBase config | 🟡 | Post-cutover | §14 |
| Avanzado | CLR assemblies | 🟠 si usados | Pre-cutover | §15 |
| BI | SSIS catalog (SSISDB) | 🔴 si usado | Separado — ver §16 |

🔴 = sin esto la app no arranca | 🟠 = la app arranca pero degradada | 🟡 = nice-to-have

---

## 2. Estrategia general

### Cuándo migrar cada cosa

```
T-7d    Inventario completo (script genera todos los .sql)
T-3d    Migrar logins, configs, certs server-level → vm-sql2022 (testeable)
T-2d    Migrar jobs (DISABLED), linked servers, mail profiles
T-1d    Migrar credentials, audit specs, server triggers
T-1h    Health check: todos los objetos out-of-band en vm-sql2022
T+0     CUTOVER (DAG failover)
T+5min  ENABLE jobs en vm-sql2022 (estaban disabled)
T+5min  DISABLE jobs en vm-sql2017 (que no se duplique trabajo)
T+1h    Validar mail, jobs funcionan
T+24h   Migrar external data sources, PolyBase si aplica
```

### Por qué los jobs migran **disabled**
Si los jobs se habilitan en el destino antes del cutover, **se ejecutarían contra una BD
secundaria del AG** (que está en estado RESTORING — los jobs fallarían o, peor, se
ejecutarían contra la base local accidentalmente).

Migrar disabled → habilitar **inmediatamente después** del cutover.

---

## 3. Logins (SQL Auth y Windows Auth)

### Por qué no basta con `CREATE LOGIN`
- Los **SIDs deben preservarse** (los users dentro de la BD están mapeados al SID del
  login). Si los SIDs cambian, los users quedan huérfanos y los permisos rotos.
- Los **password hashes** deben preservarse (no quieres cambiar passwords de todos los
  usuarios y romper apps que tengan password hardcoded).

### Script oficial MS: `sp_help_revlogin`

[Microsoft KB 918992](https://learn.microsoft.com/troubleshoot/sql/database-engine/security/transfer-logins-passwords-between-instances)
documenta el procedimiento canónico.

```sql
-- Crear el procedimiento en vm-sql2017 (master DB)
-- Codigo completo en el KB 918992 — aqui solo el uso:

USE master;
GO

-- Helper que genera CREATE LOGIN ... con SID y PASSWORD HASHED
EXEC sp_help_revlogin;
GO
```

El output es un script con líneas como:
```sql
CREATE LOGIN [app_user] WITH PASSWORD = 0x0200E1AB...
    HASHED, SID = 0x4E6AFE9A...,
    DEFAULT_DATABASE = [AppDb],
    CHECK_POLICY = ON;
```

### Ejecutar el script en vm-sql2022

```powershell
# Capturar el output de sp_help_revlogin en NorthEU
sqlcmd -S vm-sql2017 -Q "EXEC sp_help_revlogin" -o "C:\migration\logins.sql"

# Ejecutar en SpainC
sqlcmd -S vm-sql2022 -i "C:\migration\logins.sql"
```

### Verificación
```sql
-- En vm-sql2022
SELECT name, sid, type_desc, is_disabled, default_database_name
FROM sys.server_principals
WHERE type IN ('S', 'U', 'G')  -- SQL, Windows User, Windows Group
  AND name NOT LIKE '##%'
ORDER BY name;

-- Comparar con vm-sql2017 — los SIDs deben coincidir.
```

### Caso especial: Windows logins
Windows logins (`type = 'U'` o `'G'`) **necesitan resolver el SID en el dominio destino**.
Si NorthEU y SpainC no comparten dominio (nuestro caso, sin AD):
- Los Windows logins **no funcionarán** en vm-sql2022.
- Hay que **migrar a SQL Auth** (cambio de contract con la app) o configurar AAD-only.
- Documentar este caso explícitamente con la app.

### Caso especial: AAD logins (si aplica)
Si la VM 2017 ya tiene logins federados via AAD (raro, pero posible si está Arc-enabled):
- Crear los mismos AAD logins en vm-sql2022 con el mismo UPN.
- AAD asegura que el ObjectID se preserva → los users no quedan huérfanos.

### Reparar usuarios huérfanos (post-cutover)

Si después del cutover encuentras users con SID que no matchea con ningún login:
```sql
USE [AppDb];
EXEC sp_change_users_login 'Report';  -- lista los huerfanos

-- Reparar uno:
EXEC sp_change_users_login 'Auto_Fix', 'app_user';
-- O explicito:
ALTER USER [app_user] WITH LOGIN = [app_user];
```

---

## 4. Server roles (custom)

```sql
-- En vm-sql2017: scriptear los roles custom
USE master;
SELECT
    'CREATE SERVER ROLE [' + name + '] AUTHORIZATION [' + 
    USER_NAME((SELECT principal_id FROM sys.server_principals WHERE name = sr.name)) + '];'
FROM sys.server_principals sr
WHERE type = 'R' AND is_fixed_role = 0;

-- Para cada role, scriptear los miembros:
SELECT
    'ALTER SERVER ROLE [' + r.name + '] ADD MEMBER [' + m.name + '];'
FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
WHERE r.type = 'R' AND r.is_fixed_role = 0;
```

Ejecutar el output en vm-sql2022.

---

## 5. Credentials

Las credentials se usan para **Backup to URL**, **Always Encrypted con AAD**, **External
data sources**, etc.

```sql
-- En vm-sql2017: listar credentials
SELECT name, credential_identity, create_date
FROM sys.credentials
WHERE name NOT LIKE '##%';

-- Scriptear cada credential (el SECRET no se puede extraer — hay que conocerlo)
SELECT
    'CREATE CREDENTIAL [' + name + '] WITH IDENTITY = ''' + credential_identity + ''', SECRET = ''<TU_SECRET_AQUI>'';'
FROM sys.credentials
WHERE name NOT LIKE '##%';
```

> 🔐 El SECRET no se puede leer en claro. Si no lo conoces, hay que **rotarlo** y actualizar
> consumidores (apps, jobs).

### Caso típico: credential para Backup to URL
```sql
CREATE CREDENTIAL [https://<sa>.blob.core.windows.net/<container>]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = 'sv=2022-...&sig=...';
```

---

## 6. Server-level certs + Service Master Key (crítico si TDE)

### Si la BD usa TDE
Las BDs con TDE están encriptadas con el **Database Encryption Key (DEK)**, que está
encriptado a su vez con un **server certificate** que vive en `master`. Si pierdes ese
cert en el destino, la BD restaurada **no abre**.

### Workflow obligatorio para TDE

```sql
-- En vm-sql2017: backup del Service Master Key
USE master;
BACKUP SERVICE MASTER KEY
TO FILE = 'C:\migration\smk.bak'
ENCRYPTION BY PASSWORD = '<pwd-fuerte-temporal>';
```

```sql
-- Backup del server cert que protege el DEK
BACKUP CERTIFICATE [TDECert]
TO FILE = 'C:\migration\TDECert.cer'
WITH PRIVATE KEY (
    FILE = 'C:\migration\TDECert.pvk',
    ENCRYPTION BY PASSWORD = '<pwd-fuerte-temporal>'
);
```

```powershell
# Copiar los 3 archivos a la VM destino:
# - smk.bak
# - TDECert.cer
# - TDECert.pvk
```

```sql
-- En vm-sql2022:
USE master;

-- 1) Restore del SMK (opcional pero recomendado para compatibilidad)
RESTORE SERVICE MASTER KEY
FROM FILE = 'C:\migration\smk.bak'
DECRYPTION BY PASSWORD = '<pwd-fuerte-temporal>';

-- 2) Crear Master Key en master (si no existe)
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<pwd-master-key>';

-- 3) Crear el server cert desde el backup
CREATE CERTIFICATE [TDECert]
FROM FILE = 'C:\migration\TDECert.cer'
WITH PRIVATE KEY (
    FILE = 'C:\migration\TDECert.pvk',
    DECRYPTION BY PASSWORD = '<pwd-fuerte-temporal>'
);
```

A partir de aquí, la BD restaurada/seeded con TDE podrá abrir su DEK.

> ⚠️ **El DAG con TDE requiere que el cert esté presente en el secondary ANTES del seeding
> manual**, si no el restore falla con error "Cannot find server certificate with thumbprint
> <X>".

### Si la BD NO usa TDE
Saltar esta sección. Solo asegúrate de tener un **Master Key en `master`** del 2022 para
los certs del endpoint (ya cubierto en [`architecture.md`](architecture.md) §5).

---

## 7. Audit specifications

```sql
-- Listar server audits
SELECT name, audit_guid, type_desc, status_desc, on_failure_desc
FROM sys.server_audits;

-- Scriptear cada audit:
-- (No hay sp helper — usar Generate Scripts en SSMS o sp_audit_create__)

-- Listar server audit specifications:
SELECT name, status_desc, audit_action_id
FROM sys.server_audit_specifications;
```

Generar scripts con SSMS (Right-click → Script Audit as → CREATE) y ejecutar en destino.

Migrar **post-cutover** porque los audits referencian rutas de archivos que pueden ser
distintas entre VMs.

---

## 8. Configuraciones de instancia

### sp_configure

```sql
-- En vm-sql2017: capturar config actual
SELECT name, value_in_use, description
FROM sys.configurations
WHERE value_in_use <> value  -- solo los que difieren del default real
ORDER BY name;
```

Para cada config relevante (no defaults) generar:
```sql
EXEC sp_configure 'max server memory (MB)', <X>;
EXEC sp_configure 'cost threshold for parallelism', <Y>;
EXEC sp_configure 'max degree of parallelism', <Z>;
-- ...
RECONFIGURE WITH OVERRIDE;
```

### Trace flags

```sql
-- En vm-sql2017: trace flags activos
DBCC TRACESTATUS(-1);
```

Migrar los relevantes al startup de SQL 2022:
```powershell
# Editar la startup parameters del servicio SQL Server en la VM destino
# Configuration Manager → SQL Server Services → SQL Server (MSSQLSERVER) →
# Properties → Startup Parameters → -T<flag>
```

O via T-SQL para los traceables runtime:
```sql
DBCC TRACEON (1800, -1);
DBCC TRACEON (9567, -1);
```

### TempDB layout (CRÍTICO pre-instalación)

```sql
-- En vm-sql2017: ver layout actual
SELECT name, physical_name, size * 8 / 1024 AS size_mb, growth
FROM sys.master_files
WHERE database_id = 2;  -- tempdb
```

Configurar el mismo **número de files** y **tamaño inicial** en vm-sql2022 durante el setup
SQL 2022, NO post-hoc (cambiar tempdb files post-install requiere restart).

> 💡 Para SQL 2022, los defaults de tempdb son razonables (8 files con autogrowth). Si el
> 2017 tenía tuning custom, replicarlo.

### Resource Governor

```sql
-- Scriptear el resource governor entero
SELECT name FROM sys.resource_governor_resource_pools;
SELECT * FROM sys.resource_governor_workload_groups;
-- Scriptear con SSMS.
```

---

## 9. SQL Server Agent (jobs, schedules, operators, alerts, proxies)

### Generar script completo (msdb)

Forma más segura: usar **PowerShell con SMO** o **SSMS Generate Scripts** sobre todos los
objetos de SQL Server Agent.

```powershell
# Con PowerShell + SMO (necesita módulo SqlServer)
Install-Module -Name SqlServer -Force -AllowClobber

# Conectar
$srv = New-Object Microsoft.SqlServer.Management.Smo.Server "vm-sql2017"

# Generar script de jobs
$scripter = New-Object Microsoft.SqlServer.Management.Smo.Scripter $srv
$scripter.Options.ScriptDrops = $false
$scripter.Options.IncludeIfNotExists = $true
$scripter.Options.ScriptSchema = $true
$scripter.Options.ScriptData = $false
$scripter.Options.NoCommandTerminator = $false
$scripter.Options.AgentJobId = $false  # genera nuevos GUIDs
$scripter.Options.AgentNotify = $true
$scripter.Options.AgentAlertJob = $true

$jobs = $srv.JobServer.Jobs
$script = $scripter.Script($jobs)

# Guardar
$script | Out-File "C:\migration\jobs.sql" -Encoding UTF8
```

### Migrar DISABLED al destino

Editar el script generado para **disable** todos los jobs antes de hacer el cutover:

```sql
-- Despues de crear cada job, hacer:
EXEC msdb.dbo.sp_update_job @job_name = N'<JobName>', @enabled = 0;
```

Ejecutar el script en vm-sql2022.

### Operators y alerts

```sql
-- En vm-sql2017: scriptear (SSMS o T-SQL directo)
SELECT 'EXEC msdb.dbo.sp_add_operator @name = N''' + name + ''', @email_address = N''' + email_address + ''';'
FROM msdb.dbo.sysoperators;
```

### Habilitar jobs post-cutover (T+5min)

```sql
-- En vm-sql2022 (post-cutover):
USE msdb;
EXEC sp_update_job @job_name = N'<JobName1>', @enabled = 1;
EXEC sp_update_job @job_name = N'<JobName2>', @enabled = 1;
-- ...
```

```sql
-- En vm-sql2017 (post-cutover) — disable todos los jobs para que no dupliquen
USE msdb;
DECLARE @cmd nvarchar(max) = N'';
SELECT @cmd = @cmd + 'EXEC sp_update_job @job_name = N''' + name + ''', @enabled = 0;' + CHAR(13)
FROM msdb.dbo.sysjobs
WHERE enabled = 1;
PRINT @cmd;
-- Revisar antes de ejecutar
EXEC sp_executesql @cmd;
```

---

## 10. Linked servers

```sql
-- En vm-sql2017: listar
SELECT name, product, provider, data_source, catalog
FROM sys.servers
WHERE is_linked = 1;

-- Scriptear cada uno
-- SSMS: Right-click linked server → Script Linked Server as → CREATE
-- O EXEC sp_addlinkedserver manual

-- Para cada uno, scriptear logins:
SELECT
    s.name AS linked_server,
    sl.local_principal_id,
    sl.uses_self_credential,
    sl.remote_name
FROM sys.linked_logins sl
JOIN sys.servers s ON s.server_id = sl.server_id;
```

### Verificación post-cutover
```sql
-- En vm-sql2022
EXEC sp_testlinkedserver '<linked_server_name>';
-- Debe devolver vacio (sin error)
```

### Caso especial: si el linked server apunta a vm-sql2017

Si el linked server original apuntaba al **propio servidor que migras**, hay que reapuntarlo
al nuevo (vm-sql2022). Auditar cuidadosamente.

---

## 11. Database Mail

```sql
-- Profiles
SELECT name, description FROM msdb.dbo.sysmail_profile;

-- Accounts
SELECT name, email_address, mailserver_name FROM msdb.dbo.sysmail_account;
```

Scriptear con SSMS (Database Mail → Right-click → Script as → CREATE) y ejecutar en destino.

Probar post-cutover:
```sql
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = '<profile>',
    @recipients = '<test@email.com>',
    @subject = 'Test post-migration',
    @body = 'Mail funciona';
```

---

## 12. Replicación (caso especial)

Si la BD origen es **publisher / subscriber / distributor** de replicación:

### Pre-cutover
- **Documentar la topología completa** (publishers, subscribers, articles).
- **Pausar agentes** de replicación durante el cutover (eviting accumulation of pending changes).

### Post-cutover
- **Reconfigurar la replicación** desde cero en el destino. La replicación NO se migra
  automáticamente.
- Considerar usar la migración para **simplificar** la topología (a menudo hay replicas
  innecesarias).

> ⚠️ Si la replicación es crítica, esta fase de migración es **mala oportunidad** para
> mantenerla. Es preferible **decommissionar la replicación** antes de la migración y
> rediseñarla nativa en el destino (Always On AG, Change Data Capture, Service Broker).

---

## 13. Server triggers

```sql
-- Listar
SELECT name, type_desc, is_disabled, definition
FROM sys.server_triggers st
JOIN sys.server_sql_modules ssm ON ssm.object_id = st.object_id;

-- Scriptear (SSMS: Server Objects → Triggers → Script as → CREATE)
```

---

## 14. External Data Sources y PolyBase

### External data sources (si usados)
Usados para consultar datos externos (Hadoop, Azure Storage, Cosmos DB, etc.).

```sql
-- En vm-sql2017
SELECT name, location, credential_id, type_desc
FROM sys.external_data_sources;
```

Scriptear con SSMS y migrar **post-cutover** (requieren credentials que ya estarán
configuradas).

### PolyBase
Si PolyBase está habilitado y usado:
- Asegurar que vm-sql2022 tiene la **misma feature instalada** (PolyBase Services).
- Reconfigurar las external tables y data sources post-cutover.

```sql
EXEC sp_configure 'polybase enabled', 1;
RECONFIGURE;
```

---

## 15. CLR Assemblies

Si la BD origen usa **CLR custom**:

```sql
-- En vm-sql2017
USE [AppDb];
SELECT name, permission_set_desc, is_visible
FROM sys.assemblies
WHERE is_user_defined = 1;

-- Verificar que la BD permite CLR
EXEC sp_configure 'clr enabled', 1;
RECONFIGURE;
```

Los assemblies de la BD se replican con el DAG (están en la BD). Pero la **configuración a
nivel de instancia** (`clr enabled`, `clr strict security`) hay que replicarla.

SQL 2022 tiene `clr strict security = 1` por default — algunos assemblies firmados
sin asymmetric key del 2017 pueden fallar al cargar. Solución:

```sql
USE master;
CREATE ASYMMETRIC KEY [<key_name>] FROM EXECUTABLE FILE = 'C:\path\<assembly>.dll';
CREATE LOGIN [<login>] FROM ASYMMETRIC KEY [<key_name>];
GRANT UNSAFE ASSEMBLY TO [<login>];
```

---

## 16. SSIS Catalog (SSISDB)

Si la instancia origen tiene SSIS catalog (`SSISDB`):

### Opción A — Backup + restore de SSISDB (recomendado)
```sql
-- En vm-sql2017
USE master;
BACKUP DATABASE [SSISDB] TO URL = 'https://<sa>.blob.core.windows.net/migration/SSISDB.bak'
WITH COMPRESSION, CHECKSUM, FORMAT;

-- Tambien backup del Master Key de SSISDB (esta protegido por una password)
USE [SSISDB];
BACKUP MASTER KEY TO FILE = 'C:\migration\SSISDB_MK.key' ENCRYPTION BY PASSWORD = '<pwd>';
```

```sql
-- En vm-sql2022
-- Crear el SSIS catalog primero (con SSMS o T-SQL)
-- Luego restore del backup
RESTORE DATABASE [SSISDB]
FROM URL = 'https://<sa>.blob.core.windows.net/migration/SSISDB.bak'
WITH RECOVERY, REPLACE;

-- Restaurar el master key
USE [SSISDB];
RESTORE MASTER KEY FROM FILE = 'C:\migration\SSISDB_MK.key'
    DECRYPTION BY PASSWORD = '<pwd>'
    ENCRYPTION BY PASSWORD = '<pwd-nueva>'
    FORCE;
```

### Opción B — Redeploy de paquetes
Más complejo. Sólo si los paquetes están versionados en source control y se quiere
"empezar limpio".

---

## 17. Checklist post-migración out-of-band

Validar **todos** estos en vm-sql2022 antes de declarar el cutover exitoso:

- [ ] `SELECT COUNT(*) FROM sys.server_principals WHERE type IN ('S','U','G')` — coincide con NorthEU
- [ ] `SELECT COUNT(*) FROM sys.credentials` — coincide
- [ ] `SELECT COUNT(*) FROM sys.certificates WHERE pvt_key_encryption_type_desc = 'ENCRYPTED_BY_MASTER_KEY'` — coincide
- [ ] `SELECT COUNT(*) FROM sys.servers WHERE is_linked = 1` — coincide
- [ ] `SELECT COUNT(*) FROM msdb.dbo.sysjobs` — coincide
- [ ] `SELECT COUNT(*) FROM msdb.dbo.sysoperators` — coincide
- [ ] `SELECT name FROM sys.configurations WHERE value_in_use <> value` — match con NorthEU
- [ ] Mail test: `sp_send_dbmail` funciona
- [ ] Linked servers test: `sp_testlinkedserver` para cada uno
- [ ] SSIS test: ejecutar un paquete simple
- [ ] CLR test: `SELECT dbo.<clr_func>(...)` funciona

---

## 18. Herramientas que aceleran esto

### dbatools (PowerShell, community pero excelente)
```powershell
Install-Module dbatools -Force
```

Cubre prácticamente todo lo de este documento con un solo cmdlet:
```powershell
# Migrar logins
Copy-DbaLogin -Source vm-sql2017 -Destination vm-sql2022

# Migrar jobs
Copy-DbaAgentJob -Source vm-sql2017 -Destination vm-sql2022 -DisableOnDestination

# Migrar linked servers
Copy-DbaLinkedServer -Source vm-sql2017 -Destination vm-sql2022

# Migrar database mail
Copy-DbaDbMail -Source vm-sql2017 -Destination vm-sql2022

# Migrar credentials (necesita conocer SECRET)
Copy-DbaCredential -Source vm-sql2017 -Destination vm-sql2022 -CredentialIdentity '<identity>'

# Migrar configs sp_configure
Copy-DbaSpConfigure -Source vm-sql2017 -Destination vm-sql2022

# Migrar Resource Governor
Copy-DbaResourceGovernor -Source vm-sql2017 -Destination vm-sql2022
```

> 💡 **dbatools** es la herramienta de facto para migraciones SQL Server. Mantenida por la
> comunidad y testada en producción por miles de DBAs. **Recomendado** sobre scriptear todo
> a mano.

### SSMS Migration Component (alternativa GUI)
Para logins en particular, el wizard de SSMS los migra automáticamente. Ver
[`decision-rationale.md`](decision-rationale.md) §SSMS Migration Component.

---

## 19. Cambios específicos cross-version 2017 → 2022 que afectan migración

| Feature/comportamiento | 2017 | 2022 | Impacto |
|---|---|---|---|
| `clr strict security` | Off por default | **On** | Assemblies sin asymmetric key pueden fallar |
| `tempdb` autogrowth | Manual config | Mejor default | Validar config |
| Query Store | Opt-in | **On por default en nuevas BDs** | Las BDs migradas mantienen su config |
| `tempdb` files default | 1 | **8** | Mejor para concurrency |
| Backup encryption | OK | OK | Sin cambio |
| TLS 1.0/1.1 endpoint | Soportado | Por default off | Validar drivers de cliente |
| Diagnostic Connection | Soportado | Soportado | Sin cambio |
| Always Encrypted | Soportado | Mejorado | Sin cambio |
| Always Encrypted con secure enclaves | No | Sí | Nueva feature, opcional |
| Ledger tables | No | Sí | Nueva feature, opcional |

> Para más cambios breaking: [Issues when upgrading to SQL Server 2022](https://learn.microsoft.com/troubleshoot/sql/database-engine/install/windows/issues-upgrading-sql-server-2022).

---

## Referencias

- [Transfer logins and passwords between instances (KB 918992)](https://learn.microsoft.com/troubleshoot/sql/database-engine/security/transfer-logins-passwords-between-instances)
- [Manage Metadata When Making a Database Available on Another Server](https://learn.microsoft.com/sql/relational-databases/databases/manage-metadata-when-making-a-database-available-on-another-server)
- [Migration guide: SQL Server to SQL Server on Azure VMs — Migrate objects outside user databases](https://learn.microsoft.com/data-migration/sql-server/virtual-machines/guide#migrate-objects-outside-user-databases)
- [dbatools — Copy commands](https://dbatools.io/commands/)
- [Move SQL Server logins and SIDs](https://learn.microsoft.com/sql/relational-databases/security/choose-an-encryption-algorithm)
- [TDE database migration](https://learn.microsoft.com/sql/relational-databases/security/encryption/move-a-tde-protected-database-to-another-sql-server)
- [SSIS Catalog Backup and Restore](https://learn.microsoft.com/sql/integration-services/catalog/backup-restore-and-move-the-ssis-catalog)
- [Issues when upgrading to SQL Server 2022](https://learn.microsoft.com/troubleshoot/sql/database-engine/install/windows/issues-upgrading-sql-server-2022)
