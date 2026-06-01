# Anexo — Replicación entre instancias tras la migración a PaaS

En topologías existentes basadas en SQL Server IaaS suele haber **replicación entre
instancias distintas** (no entre réplicas del mismo AG): una instancia publica cambios
de un conjunto de tablas y otra instancia los consume. Tras la migración a SQL Managed
Instance, esta topología **se puede preservar** porque MI soporta los mismos mecanismos
de replicación que SQL Server (con algunas limitaciones documentadas más abajo).

Este anexo describe qué mecanismos están soportados, qué cambia respecto al on-prem/IaaS
y cómo planificar el cutover cuando hay dependencias cross-instance.

---

## Matriz de mecanismos soportados en SQL MI

| Mecanismo | Publisher en MI | Distributor en MI | Subscriber en MI | Notas |
|---|---|---|---|---|
| **Transactional Replication** | ✅ | ✅ | ✅ (push y pull) | El más habitual; full soporte MI ↔ MI |
| **Snapshot Replication** | ✅ | ✅ | ✅ | Refresh periódico |
| **Merge Replication** | ❌ | ❌ | ❌ | No soportado en MI |
| **Peer-to-Peer Replication** | ❌ | ❌ | ❌ | No soportado en MI |
| **Change Data Capture (CDC)** | ✅ | n/a | ✅ | Para capturar cambios y exportar vía ETL custom |
| **Change Tracking** | ✅ | n/a | ✅ | Más ligero que CDC, sin tabla histórica |
| **Service Broker (entre MIs)** | ✅ | n/a | ✅ | Necesita certs cross-instance |
| **Linked Servers MI ↔ MI** | n/a | n/a | n/a | Queries cross-instance, no replicación masiva |

Doc oficial: [Transactional replication with Azure SQL Managed
Instance](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/replication-transactional-overview).

### Reglas importantes

- **Publisher y Distributor deben estar del mismo "lado"**: o ambos en la nube (MI / SQL DB)
  o ambos on-premises. No se permite Publisher en MI + Distributor on-prem ni viceversa.
- **MI puede ser Subscriber** de un SQL Server 2016 o superior. Para versiones anteriores
  hay que usar [republishing data](https://learn.microsoft.com/en-us/sql/relational-databases/replication/republish-data).
- **Pull subscription**: no soportada cuando el distributor está en MI y el subscriber no
  está en MI.
- **Working folder del snapshot**: en MI **tiene que ser una Azure File Share** (no un
  disco local como en SQL Server IaaS). Esto cambia el procedimiento de setup respecto al
  on-prem.

---

## Patrón típico: workload A → workload B con Transactional Replication

### AS-IS (SQL Server IaaS / on-prem)

```text
   ┌──────────────────────────┐                    ┌──────────────────────────┐
   │ SQL Server VM A          │                    │ SQL Server VM B          │
   │ ┌──────────────────────┐ │  Transactional     │ ┌──────────────────────┐ │
   │ │ BD origen            │ │  Replication       │ │ BD destino           │ │
   │ │ (Publisher)          │ │ ─────────────────► │ │ (Subscriber)         │ │
   │ │                      │ │                    │ │                      │ │
   │ │ Distributor LOCAL    │ │                    │ │                      │ │
   │ └──────────────────────┘ │                    │ └──────────────────────┘ │
   └──────────────────────────┘                    └──────────────────────────┘
```

### TO-BE (SQL MI en la misma región destino)

```text
   ┌─────────────────────────┐                     ┌─────────────────────────┐
   │ SQL MI A                │                     │ SQL MI B                │
   │ ┌─────────────────────┐ │  Transactional      │ ┌─────────────────────┐ │
   │ │ BD origen           │ │  Replication        │ │ BD destino          │ │
   │ │ (Publisher)         │ │  ────────────────►  │ │ (Subscriber)        │ │
   │ │                     │ │                     │ │                     │ │
   │ │ Distributor LOCAL   │ │                     │ │                     │ │
   │ │ + Azure File Share  │ │                     │ │                     │ │
   │ │   (snapshot folder) │ │                     │ │                     │ │
   │ └─────────────────────┘ │                     │ └─────────────────────┘ │
   └─────────────────────────┘                     └─────────────────────────┘
```

La topología es **idéntica conceptualmente**. Lo único que cambia es:

| Aspecto | IaaS / on-prem | SQL MI |
|---|---|---|
| Distributor | VM separada o local al Publisher | Local al Publisher (recomendado) |
| Working folder del snapshot | Carpeta en disco | **Azure File Share** (obligatorio) |
| Agents (LogReader, Snapshot, Distribution) | SQL Server Agent en la VM | SQL Agent del MI Publisher/Distributor |
| Autenticación entre instancias | Windows / SQL | AAD o SQL (depende del MI) |
| Latencia Pub→Sub | < 1 ms (misma red) | < 1 ms (misma VNet o peered en la misma región) |

---

## Setup paso a paso: Publisher MI + Distributor local + Subscriber MI

### 1. Crear una Azure File Share para el snapshot folder

```powershell
$rg       = "<rg-mi>"
$location = "<region>"
$saName   = "stmiwfldr$(Get-Random -Maximum 9999)"
$share    = "repl-snapshot"

az storage account create --name $saName --resource-group $rg `
  --location $location --sku Standard_LRS --kind StorageV2

az storage share create --account-name $saName --name $share
```

### 2. Configurar la credential del Publisher MI para acceder al share

```sql
USE master;

CREATE CREDENTIAL [https://<sa>.file.core.windows.net/<share>]
WITH IDENTITY = '<sa>',
     SECRET   = '<account-key-o-sas>';
```

> Mismo *caveat* sobre `allowSharedKeyAccess` y tenants restrictivos: si la policy
> bloquea las account keys, hay que usar **identidad gestionada del MI** con RBAC
> `Storage File Data SMB Share Contributor` sobre el share.

### 3. Configurar la BD como Publication

```sql
USE <DbName>;

EXEC sp_replicationdboption
   @dbname = N'<DbName>',
   @optname = N'publish',
   @value = N'true';

EXEC sp_addpublication
   @publication = N'<PubName>',
   @description = N'Replicación cross-instance',
   @sync_method = N'concurrent',
   @repl_freq = N'continuous',
   @status = N'active',
   @snapshot_in_defaultfolder = N'false',
   @alt_snapshot_folder = N'\\<sa>.file.core.windows.net\<share>\<DbName>',
   @independent_agent = N'true';

EXEC sp_addpublication_snapshot
   @publication = N'<PubName>',
   @frequency_type = 1,  -- on demand
   @publisher_security_mode = 1;
```

### 4. Añadir artículos (tablas) a la publicación

```sql
EXEC sp_addarticle
   @publication   = N'<PubName>',
   @article       = N'<TableName>',
   @source_owner  = N'dbo',
   @source_object = N'<TableName>',
   @type          = N'logbased',
   @schema_option = 0x000000000803509F,
   @ins_cmd       = N'CALL sp_MSins_dbo<TableName>',
   @del_cmd       = N'CALL sp_MSdel_dbo<TableName>',
   @upd_cmd       = N'SCALL sp_MSupd_dbo<TableName>';
```

Repetir para cada tabla a replicar.

### 5. Configurar el Subscriber MI

En el **MI Publisher**, registrar la subscription push:

```sql
EXEC sp_addsubscription
   @publication       = N'<PubName>',
   @subscriber        = N'<mi-subscriber>.<dns-zone>.database.windows.net',
   @destination_db    = N'<DbNameSubscriber>',
   @subscription_type = N'push',
   @sync_type         = N'automatic',
   @article           = N'all',
   @update_mode       = N'read only';

EXEC sp_addpushsubscription_agent
   @publication              = N'<PubName>',
   @subscriber               = N'<mi-subscriber>.<dns-zone>.database.windows.net',
   @subscriber_db            = N'<DbNameSubscriber>',
   @subscriber_security_mode = 0,
   @subscriber_login         = N'<repl-user>',
   @subscriber_password      = N'<password>';
```

### 6. Generar el snapshot inicial y verificar

```sql
-- En el Publisher, lanzar el snapshot manualmente
EXEC sp_startpublication_snapshot @publication = N'<PubName>';

-- Verificar estado
SELECT * FROM dbo.MSpublications;
SELECT * FROM dbo.MSdistribution_agents;
SELECT * FROM dbo.MSdistribution_history;
```

En el **Subscriber MI**:

```sql
USE <DbNameSubscriber>;
SELECT TOP 10 * FROM dbo.<TableName>;
-- Las filas iniciales deben aparecer tras completarse el snapshot.
```

---

## Orden recomendado para migrar topologías con replicación

Cuando hay dependencia *workload A → workload B* vía replicación, el orden importa.
Hay tres estrategias:

### Estrategia 1 — Pausar replicación + cutover en serie (RECOMENDADA)

1. **Configurar MI Link** del workload A (Publisher) y del workload B (Subscriber) en paralelo,
   ambos al MI destino correspondiente.
2. **En la ventana de cutover**:
   1. Pausar la replicación A → B en el origen (`sp_replicationdboption … 'publish', 'false'`).
   2. Esperar `LogQueue=0` y `RedoQueue=0` en ambos MI Links.
   3. Cutover de A → MI A.
   4. Cutover de B → MI B.
   5. Recrear la publicación A → B en el nuevo entorno MI (snapshot inicial limpio).
3. **Validar** que los nuevos cambios en MI A se propagan a MI B.

**Pros**: simple, predecible, no requiere mantener doble setup.
**Contras**: durante la ventana de cutover hay una pausa en la replicación A → B que el
negocio tiene que tolerar.

### Estrategia 2 — Migrar Subscriber primero, mantener Pub on-prem temporalmente

1. **Cutover de B (Subscriber)** primero a MI B.
2. **Reconfigurar la publicación** del Publisher on-prem para apuntar al nuevo MI B
   (necesita conectividad on-prem → MI B vía ExpressRoute, S2S VPN, o public endpoint).
3. **Cutover de A (Publisher)** más tarde a MI A.
4. **Reconfigurar la publicación** otra vez, ahora con Publisher MI A + Subscriber MI B.

**Pros**: la replicación nunca se interrumpe del todo.
**Contras**: doble reconfiguración, latencia cross-region durante la ventana
intermedia, complejidad operativa alta. No recomendado salvo SLA muy estricto.

### Estrategia 3 — Migrar Publisher primero, Subscriber se queda atrás

Inversa de la 2. Mismas ventajas/inconvenientes pero con la complicación añadida de
que el Publisher on-prem deja de funcionar mientras se hace el cutover de A, y entonces
B (todavía on-prem) se queda sin recibir cambios.

**No recomendado** salvo casos muy específicos.

---

## Limitaciones a tener presentes

- **Subscriptions externas** (apps, BI, ETL, herramientas de Data Warehouse) que consumen
  la publicación del SQL Server origen pueden necesitar reconfigurarse para apuntar al
  nuevo MI Publisher. Inventariarlas antes del cutover.

- **Snapshot agent + Azure File Share**: la primera vez que se ejecuta puede tardar
  notablemente más que en on-prem por la latencia al storage. Aceptable en POC, planificar
  ventana para snapshots productivos.

- **CDC en MI**: soportado pero las tablas de captura cuentan contra el storage del MI.
  Si la BD origen tiene CDC con retención larga, dimensionar storage del MI con margen.

- **Service Broker entre MIs**: requiere cert exchange explícito y rutas configuradas
  manualmente. Está documentado pero es operativamente complejo. Si la topología on-prem
  depende fuertemente de Service Broker cross-instance, planificar tiempo extra.

- **Merge Replication / P2P**: si la topología actual depende de alguno de los dos,
  **no se puede migrar tal cual a MI**. Hay que rediseñar (típicamente convertir a
  transactional con custom procedures, o usar Synapse Link, o redesign aplicacional).

---

## Inventario previo recomendado

Antes de planificar la migración de un entorno con dependencias cross-instance, completar
este inventario en el origen:

```sql
-- En cada instancia origen, ejecutar:

-- 1. ¿Es Publisher?
SELECT name, is_published, is_subscribed, is_distributor
FROM sys.databases
WHERE is_published = 1 OR is_subscribed = 1 OR is_distributor = 1;

-- 2. Publicaciones definidas
USE distribution;
SELECT publisher_id, publisher_db, publication
FROM dbo.MSpublications;

-- 3. Subscriptions
SELECT publisher_id, publisher_db, publication, subscriber_db, subscription_type
FROM dbo.MSsubscriptions;

-- 4. Agents en ejecución
SELECT name, publisher_db, publication, subscriber, subscriber_db
FROM dbo.MSdistribution_agents
WHERE subscriber > 0;

-- 5. CDC habilitado
SELECT name, is_cdc_enabled FROM sys.databases WHERE is_cdc_enabled = 1;

-- 6. Service Broker endpoints cross-instance
SELECT name, type_desc, state_desc FROM sys.endpoints WHERE type_desc = 'SERVICE_BROKER';

-- 7. Linked servers
SELECT name, product, provider, data_source FROM sys.servers WHERE server_id <> 0;
```

Con ese inventario:

1. Decidir qué dependencias se preservan en MI (1:1 con la matriz al principio del doc).
2. Identificar qué dependencias necesitan rediseño (Merge / P2P / Linked Server con
   `OPENQUERY` heavy).
3. Calcular el orden de cutover (Estrategia 1, 2 o 3 según SLA).
4. Documentar el procedimiento de recreación de cada publicación en el nuevo entorno MI.

---

## Referencias

- [Transactional replication with SQL Managed Instance](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/replication-transactional-overview)
- [Configure replication for AAG](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/replication-transactional-overview#availability-groups)
- [T-SQL differences SQL Server vs SQL MI](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/transact-sql-tsql-differences-sql-server)
- [CDC in SQL Managed Instance](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/change-data-capture-configure)
