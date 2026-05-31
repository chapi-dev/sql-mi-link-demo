# Setup manual del Link (fallback al wizard SSMS)

Procedimiento paso a paso para configurar el Managed Instance Link **sin** el
wizard de SSMS. Útil cuando:

- El wizard no está disponible (versión de SSMS antigua).
- Se quiere automatizar el setup vía PowerShell / T-SQL.
- Hay que diagnosticar fallos del wizard recreando los pasos manualmente.

> El [wizard SSMS](ssms-wizard-guide.md) sigue siendo el camino oficial recomendado.
> Esta guía documenta lo que el wizard hace por debajo.

## Tabla de contenidos

1. [Pre-requisitos](#pre-requisitos)
2. [Setup en SQL Server origen](#setup-en-sql-server-origen)
3. [Setup en MI destino](#setup-en-mi-destino)
4. [Cert exchange bidireccional](#cert-exchange-bidireccional)
5. [Creación del Distributed AG](#creación-del-distributed-ag)
6. [Verificación end-to-end](#verificación-end-to-end)
7. [Detalles que el wizard hace automáticamente](#detalles-que-el-wizard-hace-automáticamente)

---

## Pre-requisitos

Listado en [`runbook.md`](runbook.md) y [`azure-connect-pack.md`](azure-connect-pack.md).
Resumen:

- SQL Server con CU soportado (2017 CU31+, 2019 CU27+, 2022 CU13+).
- Azure Connect Pack instalado (obligatorio en 2017).
- BD en `RECOVERY FULL` con al menos un FULL backup.
- AG feature habilitada (`Enable-SqlAlwaysOn`).
- Master key creada en `master`.
- TCP 5022 alcanzable entre SQL Server y MI (NSG + Windows Firewall).
- MI desplegado y `Ready`.

---

## Setup en SQL Server origen

### Paso 1 — Master key y trace flags

```sql
USE master;
GO

-- Trace flags requeridos por MI Link
DBCC TRACEON (1800, -1);
DBCC TRACEON (9567, -1);
GO

-- Master key (solo si no existe)
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong-pwd>';
GO
```

> Hacer los trace flags persistentes vía startup parameters (`-T1800 -T9567`)
> para que sobrevivan al restart del servicio.

### Paso 2 — Certificado y endpoint de mirroring

```sql
-- Cert local (10 años validity)
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'MILinkCert')
    CREATE CERTIFICATE MILinkCert
        WITH SUBJECT = 'MI Link mirroring endpoint cert',
        EXPIRY_DATE = '2035-12-31';
GO

-- Exportar cert público para registrar luego en MI
BACKUP CERTIFICATE MILinkCert
    TO FILE = 'C:\MILink\MILinkCert.cer';
GO

-- Endpoint TCP 5022 con auth por cert
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = 'Hadr_endpoint')
    CREATE ENDPOINT [Hadr_endpoint]
        STATE = STARTED
        AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
        FOR DATABASE_MIRRORING (
            AUTHENTICATION = CERTIFICATE MILinkCert,
            ENCRYPTION = REQUIRED ALGORITHM AES,
            ROLE = ALL
        );
GO
```

### Paso 3 — AG local clusterless

```sql
-- AG single-replica clusterless (necesario para MI Link)
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = 'MILinkAG')
    CREATE AVAILABILITY GROUP [MILinkAG]
        WITH (CLUSTER_TYPE = NONE)
        FOR DATABASE [<DbName>]
        REPLICA ON
            N'<SqlServerName>' WITH (
                ENDPOINT_URL = N'TCP://<sqlserver-fqdn-or-ip>:5022',
                AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
                FAILOVER_MODE = MANUAL,
                SEEDING_MODE = AUTOMATIC,
                SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL),
                PRIMARY_ROLE   (ALLOW_CONNECTIONS = ALL)
            );
GO
```

> En el AG local del lado SQL Server, `AVAILABILITY_MODE = SYNCHRONOUS_COMMIT`
> aunque el DAG hacia el MI será `ASYNCHRONOUS_COMMIT` (cross-region).
> El SYNCHRONOUS aplica a la replica local, no a la replicación con el MI.

---

## Setup en MI destino

El MI se gestiona vía REST API o portal — **no** se pueden ejecutar la mayoría
de DDL de AG directamente en T-SQL en MI.

### Paso 4 — Verificar que el MI está listo

```bash
az sql mi show -g <rg-mi> -n <mi-name> --query state -o tsv
# Debe devolver: Ready
```

### Paso 5 — Confirmar AAD admin

Necesario para autenticar desde SSMS y para que las stored procedures
del MI puedan ejecutarse:

```bash
az sql mi ad-admin show -g <rg-mi> --server <mi-name> -o table
```

### Paso 6 — Obtener el cert público del MI

```sql
-- Conectado al MI como AAD admin
EXEC sys.sp_get_endpoint_certificate @endpoint_type = 4;
-- Copiar el PEM completo del resultado
```

Guardar el PEM resultante: se usará en el paso siguiente.

---

## Cert exchange bidireccional

El cert exchange tiene **dos direcciones obligatorias**. Si solo se hace una,
el TLS handshake falla con error 41976.

### Dirección 1: registrar el cert del SQL Server en el MI

Vía REST API contra el MI:

```powershell
$sub  = "<sub-id>"
$rg   = "<rg-mi>"
$mi   = "<mi-name>"
$pem  = Get-Content -Path 'C:\MILink\MILinkCert.cer' -Encoding Byte
$b64  = [Convert]::ToBase64String($pem)

$body = @{
    properties = @{
        publicBlob = $b64
    }
} | ConvertTo-Json

az rest -m PUT `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Sql/managedInstances/$mi/serverTrustCertificates/<cert-friendly-name>?api-version=2022-08-01-preview" `
  --body $body --headers "Content-Type=application/json"
```

### Dirección 2: registrar el cert del MI en el SQL Server

```sql
-- En SQL Server, conectado como sysadmin
EXEC sys.sp_certificate_add_issuer
    @public_certificate = N'-----BEGIN CERTIFICATE-----
<contenido PEM del cert del MI>
-----END CERTIFICATE-----';
```

Verificar:
```sql
SELECT name, subject, issuer_name
FROM sys.certificates
WHERE issuer_name LIKE '%<mi-fqdn-fragment>%';
-- Debe devolver al menos una fila con el cert del MI.
```

> ⚠️ La stored procedure `sp_certificate_add_issuer` viene con el Azure Connect
> Pack. Si no existe, instalar el pack y reiniciar SQL Server
> (ver [`azure-connect-pack.md`](azure-connect-pack.md)).

---

## Creación del Distributed AG

### Paso 7 — DAG en SQL Server

```sql
USE master;
GO

CREATE AVAILABILITY GROUP [MILinkDAG]
    WITH (DISTRIBUTED)
    AVAILABILITY GROUP ON
        N'MILinkAG' WITH (
            LISTENER_URL      = N'TCP://<sqlserver-fqdn>:5022',
            AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
            FAILOVER_MODE     = MANUAL,
            SEEDING_MODE      = AUTOMATIC
        ),
        N'<mi-name>' WITH (
            LISTENER_URL      = N'TCP://<mi-fqdn>:5022;Server=[<mi-name>]',
            AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
            FAILOVER_MODE     = MANUAL,
            SEEDING_MODE      = AUTOMATIC
        );
GO
```

> 🚨 **La sintaxis `;Server=[<mi-name>]` requiere el Azure Connect Pack en
> SQL Server 2017**. Si el parser no la entiende, falla con `Msg 19499`.

### Paso 8 — Unir MI al DAG (REST API)

```powershell
$sub  = "<sub-id>"
$rg   = "<rg-mi>"
$mi   = "<mi-name>"
$ag   = "MILinkDAG"

$body = @{
    properties = @{
        targetDatabase = "<DbName>"
        sourceEndpoint = "TCP://<sqlserver-fqdn>:5022"
        primaryAvailabilityGroupName  = "MILinkAG"
        secondaryAvailabilityGroupName = "$mi"
    }
} | ConvertTo-Json -Depth 5

az rest -m PUT `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Sql/managedInstances/$mi/distributedAvailabilityGroups/${ag}?api-version=2022-08-01-preview" `
  --body $body --headers "Content-Type=application/json"
```

El MI responde con un long-running operation. Monitor con:
```bash
az sql mi link show -g <rg-mi> --instance-name <mi-name> --name <ag> -o table
```

### Versiones de API REST

Confirmar la API version vigente en la documentación oficial:
[Managed Instance link operations](https://learn.microsoft.com/rest/api/sql/distributed-availability-groups).
Las versiones cambian; usar la última GA estable. Si una preview no se comporta
como se espera, probar la GA siguiente.

---

## Verificación end-to-end

### En SQL Server

```sql
-- AG local SYNCHRONIZED HEALTHY
SELECT
    ag.name,
    ar.replica_server_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar  ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag    ON drs.group_id = ag.group_id
WHERE ag.name = 'MILinkAG';
-- Esperado: SYNCHRONIZED, HEALTHY

-- DAG SYNCHRONIZING HEALTHY (cross-region siempre es SYNCHRONIZING, no SYNCHRONIZED)
SELECT
    ag.name,
    ar.replica_server_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar  ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag    ON drs.group_id = ag.group_id
WHERE ag.name = 'MILinkDAG';
-- Esperado: SYNCHRONIZING, HEALTHY
```

### En MI

```sql
-- BD aparece como ONLINE (read-only durante el Link activo)
SELECT name, state_desc FROM sys.databases WHERE name = N'<DbName>';
```

### Smoke test funcional

En SQL Server:
```sql
USE <DbName>;
INSERT INTO dbo.DemoRows (Origin, Note) VALUES ('SQL Server', 'Test row');
```

En MI (read-only):
```sql
USE <DbName>;
SELECT TOP 5 * FROM dbo.DemoRows ORDER BY Id DESC;
-- La fila insertada en SQL Server debe aparecer aquí
```

---

## Detalles que el wizard hace automáticamente

Si se usa el wizard SSMS, estos pasos se hacen por debajo. Si se hace manual,
hay que recordarlos:

| Paso | Wizard | Manual |
|---|---|---|
| Validar versión/CU | ✅ con error claro si falta | Toca `SELECT @@VERSION` y comparar contra matriz |
| Validar Azure Connect Pack | ✅ aborta si falta | `SELECT name FROM sys.system_objects WHERE name = 'sp_get_endpoint_certificate'` |
| Crear master key con pwd random | ✅ | Hacerla manualmente; documentar la pwd en KV/HSM |
| Crear cert + endpoint | ✅ | T-SQL del paso 2 |
| Cert exchange | ✅ vía REST automático | Dos llamadas: REST PUT al MI + sp_certificate_add_issuer en SQL Server |
| Crear AG local single-replica | ✅ | T-SQL del paso 3 |
| Tomar FULL backup si falta | ✅ con prompt | `BACKUP DATABASE … TO DISK = …` |
| Crear DAG con LISTENER_URL correcta | ✅ | T-SQL del paso 7 |
| Hacer join del MI al DAG vía REST | ✅ | REST PUT del paso 8 |
| Iniciar initial seeding | ✅ automático | Automatic seeding ya está configurado en el AG/DAG |
| Esperar a `SYNCHRONIZING HEALTHY` | ✅ con barra de progreso | Polling manual sobre DMVs |

---

## Cuándo el manual funciona mejor que el wizard

- **CI/CD pipelines**: el setup manual se puede automatizar 100% sin
  intervención humana.
- **Múltiples DBs en lote**: scriptable en loop, mientras el wizard requiere
  una pasada por DB.
- **Diagnóstico de fallos del wizard**: ejecutar los pasos uno a uno permite
  identificar exactamente dónde se atasca.
- **Versiones SSMS antiguas o entornos sin GUI**.

## Cuándo el wizard funciona mejor

- **Primera vez** configurando un Link — el wizard valida pre-requisitos.
- **Producción con personal no especialista** — menos margen de error.
- **Demos** — más rápido y visualmente más claro.

---

## Errores frecuentes en setup manual

Detalle completo en [`troubleshooting.md`](troubleshooting.md).

- `19499`: parser `LISTENER_URL` no acepta `;Server=[…]` → falta Azure Connect Pack
  o SQL Server no se reinició tras el install.
- `41976`: cert del MI no registrado en SQL Server (o viceversa) → rehacer
  cert exchange bidireccional.
- `41986`: handshake del DAG falla aunque endpoints alcanzables → revisar
  permisos del cert login en el endpoint mirroring.
- `Msg 35253`: AG local no puede ser DISTRIBUTED → verificar `CLUSTER_TYPE = NONE`.

---

## Referencias

- [Configure link manually with T-SQL](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-configure)
- [Managed Instance distributedAvailabilityGroups REST API](https://learn.microsoft.com/rest/api/sql/distributed-availability-groups)
- [Distributed AG syntax (CREATE AVAILABILITY GROUP)](https://learn.microsoft.com/sql/t-sql/statements/create-availability-group-transact-sql)
