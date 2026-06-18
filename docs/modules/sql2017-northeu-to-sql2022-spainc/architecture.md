# Arquitectura: Distributed AG cross-region SQL 2017 (NorthEU) → SQL 2022 (SpainC)

Diseño técnico de la topología que materializa la migración descrita en este módulo.
Lee primero [`README.md`](README.md) y [`rpo-options.md`](rpo-options.md); este documento da
por entendidos los conceptos de AG local y Distributed AG.

---

## 1. Visión de alto nivel

```
             North Europe (10.10.0.0/16)                  Spain Central (10.30.0.0/16)
   ┌────────────────────────────────────────┐   ┌────────────────────────────────────────┐
   │ RG: rg-milink-vm  (existente)          │   │ RG: rg-mig-spainc (nuevo)              │
   │                                        │   │                                        │
   │  ┌──────────────────────────────────┐  │   │  ┌──────────────────────────────────┐  │
   │  │ VM: vm-sql2017                   │  │   │  │ VM: vm-sql2022                   │  │
   │  │ Windows Server 2019              │  │   │  │ Windows Server 2022              │  │
   │  │ SQL Server 2017 CU31 + KB5050533 │  │   │  │ SQL Server 2022 + último CU      │  │
   │  │                                  │  │   │  │                                  │  │
   │  │ Always On AG habilitado          │  │   │  │ Always On AG habilitado          │  │
   │  │ AG local: AG_NorthEU             │  │   │  │ AG local: AG_SpainC              │  │
   │  │ (single replica, CLUSTER=NONE)   │  │   │  │ (single replica, CLUSTER=NONE)   │  │
   │  │                                  │  │   │  │                                  │  │
   │  │ DB: <AppDb> en FULL recovery     │  │   │  │ DB: <AppDb> (seeded auto)        │  │
   │  │ Endpoint TCP 5022 (cert auth)    │  │   │  │ Endpoint TCP 5022 (cert auth)    │  │
   │  │ Master key + cert: NorthEUCert   │  │   │  │ Master key + cert: SpainCCert    │  │
   │  │ Importado: cert público SpainC   │  │   │  │ Importado: cert público NorthEU  │  │
   │  └──────────────────────────────────┘  │   │  └──────────────────────────────────┘  │
   │                                        │   │                                        │
   │  Subred: snet-vm (10.10.1.0/24)        │   │  Subred: snet-vm (10.30.1.0/24)        │
   │  NSG: AllowMigrationFromSpainC:5022    │   │  NSG: AllowMigrationFromNorthEU:5022   │
   │                                        │   │                                        │
   │  Private DNS zone: privatelink.sql...  │   │  Private DNS zone: privatelink.sql...  │
   └────────────────────────────────────────┘   └────────────────────────────────────────┘
                  ▲                                            ▲
                  │                                            │
                  └────── Global VNet peering (bidir) ─────────┘
                          + Use remote gateways: NO
                          + Allow forwarded traffic: SÍ
                          + Allow gateway transit: NO

                                  ▲
                                  │
                  ┌───────────────┴────────────────┐
                  │  Distributed Availability Group │
                  │  Nombre: DAG_Migrate            │
                  │  Modo: ASYNC (default según    │
                  │        rpo-options.md)         │
                  │  Failover: MANUAL              │
                  │  Seeding: AUTOMATIC            │
                  └────────────────────────────────┘
```

### Componentes lógicos

1. **AG_NorthEU** — AG local clusterless single-replica en la VM `vm-sql2017`.
   Una sola réplica (la primaria local). Sirve únicamente como contenedor para que
   el Distributed AG pueda enganchar la BD.

2. **AG_SpainC** — AG local clusterless single-replica en la VM `vm-sql2022`.
   Equivalente al anterior en SpainC. Es la "réplica" cross-region desde el punto de
   vista del DAG.

3. **DAG_Migrate** — Distributed AG entre `AG_NorthEU` (primary) y `AG_SpainC`
   (forwarder). Es lo que mueve el log entre regiones.

4. **Cert exchange** — Cada VM tiene su propio cert + master key; **cada lado importa
   el cert público del otro** y crea un login mapeado a él para que el endpoint pueda
   autenticar la conexión 5022.

5. **Endpoint TCP 5022** — Endpoint Always On en ambas VMs, con autenticación por
   certificado (no Windows auth: las VMs no comparten dominio).

6. **Global VNet peering** — Comunicación entre regiones por backbone Azure. No
   ExpressRoute, no S2S VPN (innecesarios para VM↔VM en Azure).

---

## 2. Por qué clusterless en ambos lados (`CLUSTER_TYPE = NONE`)

La opción canónica para Always On AG es montar Windows Server Failover Cluster (WSFC).
**No lo usamos**, por los mismos motivos que el patrón de MI Link de este repo:

| Razón | Detalle |
|---|---|
| **No hay HA local que justificar** | El AG es de **una sola réplica por región**. No hay nada que coordinar dentro de la región. |
| **WSFC cross-region añade quorum frágil** | Si se usa un único cluster cross-region, perder el peering rompe el quorum. Inaceptable. |
| **El DAG no participa en cluster** | El DAG es siempre clusterless por diseño — no se ve afectado por el WSFC local. |
| **Failover del DAG es manual y deliberado** | No necesitamos detección automática. El cutover es un evento humano planificado. |
| **Simplifica el setup en VMs Azure no joined al dominio** | Cluster sin dominio es posible (Workgroup cluster) pero añade complejidad sin valor para esta migración. |

**Conclusión**: `CLUSTER_TYPE = NONE` + `FAILOVER_MODE = MANUAL` en todos los AGs y en el DAG.

---

## 3. Versión y compatibilidad

### Forward compatibility (lo que sí funciona)

SQL Server permite que el **secundario** de un AG sea **versión igual o superior** al primario
durante un ventana de upgrade. Concretamente:

- ✅ **Primary 2017 → Secondary 2022**: replicación de log funcional. El log de 2017 se
  aplica en 2022. Es el caso de uso oficial para upgrades cross-version.
- ❌ **Primary 2022 → Secondary 2017**: **no soportado**. El secundario rechaza log
  generado por una versión superior.

### Qué significa esto para esta migración

| Momento | Quién es primary | Quién es secondary | Estado |
|---|---|---|---|
| Antes del cutover | NorthEU (2017) | SpainC (2022) | Soportado. Log fluye 2017→2022. |
| **Justo después del cutover** | SpainC (2022) | NorthEU (2017) | **NO soportado**. El DAG queda en estado roto si se intenta. |
| Post-cutover (recomendado) | SpainC (2022) | — (DAG removido) | El AG NorthEU se queda inactivo como botón de pánico, sin estar en el DAG. |

**Implicación operativa crítica**: tras el cutover **no hay failback online** vía DAG.
El rollback es por capas externas (ver [`rollback-plan.md`](rollback-plan.md)).

### Compatibility level de la BD

La BD migra con su `compatibility_level` actual (probablemente `140` si viene de SQL 2017).
**No se sube automáticamente**. Tras estabilizar en 2022:

- Mantener `compat 140` durante T+72 h post-cutover (rollback en caliente requiere que
  el .bak siga siendo restaurable en 2017 sin downgrade — no es restaurable ya, pero el
  compat level no rompe nada).
- Subir a `160` (SQL 2022) sólo cuando ya no hay opción de vuelta atrás.
- Activar **Query Store** desde el día 1 en 2022 (es default en 2022 pero merece auditarse).

---

## 4. Networking — diseño detallado

### Topología IP

| Recurso | Región | CIDR/IP | Propósito |
|---|---|---|---|
| VNet `vnet-vm` | North Europe | 10.10.0.0/16 | VNet existente (de MI Link demo) |
| Subred `snet-vm` | North Europe | 10.10.1.0/24 | VM SQL 2017 |
| VNet `vnet-mig-spainc` | Spain Central | 10.30.0.0/16 | **VNet nueva** |
| Subred `snet-vm` | Spain Central | 10.30.1.0/24 | VM SQL 2022 |

> **Importante**: el CIDR de SpainC (10.30/16) **no debe solapar** con el CIDR de MI
> (10.20/16 si reutilizas el del módulo MI Link) ni con el de NorthEU. El peering
> rechaza CIDRs solapados.

### Peering

Bidireccional NorthEU ↔ SpainC con:

| Setting | NorthEU → SpainC | SpainC → NorthEU |
|---|---|---|
| Allow virtual network access | ✅ | ✅ |
| Allow forwarded traffic | ✅ | ✅ |
| Allow gateway transit | ❌ | ❌ |
| Use remote gateways | ❌ | ❌ |

### NSG — reglas mínimas

**NorthEU (`nsg-vm`)** — añadir regla nueva:

```
Name:               AllowMigrationFromSpainC
Priority:           1200
Source:             10.30.1.0/24    (subred SpainC)
Destination:        VirtualNetwork
Protocol:           TCP
Destination port:   5022
Action:             Allow
Direction:          Inbound
```

**SpainC (`nsg-vm-spainc`)** — regla nueva en el NSG nuevo:

```
Name:               AllowMigrationFromNorthEU
Priority:           1200
Source:             10.10.1.0/24    (subred NorthEU)
Destination:        VirtualNetwork
Protocol:           TCP
Destination port:   5022
Action:             Allow
Direction:          Inbound
```

> **Nota**: ambas reglas son **Inbound**. El tráfico saliente entre VNets peered está
> permitido por default — no hacen falta reglas Outbound explícitas salvo que el cliente
> tenga NSGs restrictivos por política.

### Windows Firewall (en cada VM)

```powershell
New-NetFirewallRule -DisplayName "SQL AG Endpoint 5022" `
    -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow
```

### DNS

- **No hace falta DNS público** entre las VMs. Pueden usarse IPs directamente o nombres
  resueltos vía hosts file.
- Recomendado: registrar ambas VMs en una **Private DNS zone** (o usar la zona de Azure
  DNS auto-registrado vinculada a ambas VNets) para que los endpoints usen FQDN
  estables.
- Si la app tiene que repuntar al cutover y no quieres tocar connection string,
  considera registrar un CNAME tipo `sqlprimary.internal.empresa.com` apuntando a la
  VM activa y cambiarlo en el cutover. **Opcional**.

### MTU y latencia esperada

- MTU default 1500 funciona; **no activar jumbo frames** salvo prueba específica (puede
  romper paquetes en hops del backbone Azure).
- RTT esperado NorthEU↔SpainC: ~25-35 ms (validar con POC; ver [`rpo-options.md`](rpo-options.md)).

---

## 5. Identidad, certificados y autenticación de endpoint

### Por qué cert auth y no Windows auth

Las VMs **no comparten dominio** (no hay AD DS común entre NorthEU y SpainC en este
diseño). La autenticación Windows del endpoint requeriría AD trust cross-region, lo
cual:

- Añade dependencia operativa pesada (DC en cada región, replicación AD).
- No mejora la seguridad para un endpoint dedicado a tráfico de log.

**Cert auth** es la opción canónica para AGs cross-domain o sin dominio. Lo usa también
MI Link en este repo.

### Setup por VM

En cada VM, el script de preparación crea:

1. **Database Master Key** en `master`:
   ```sql
   CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<pwd-fuerte>';
   ```

2. **Certificate** para el endpoint (auto-firmado, 10 años):
   ```sql
   CREATE CERTIFICATE NorthEUCert
       WITH SUBJECT = 'NorthEU AG endpoint cert',
            EXPIRY_DATE = '20360101';
   ```

3. **Endpoint** TCP 5022 con auth por cert:
   ```sql
   CREATE ENDPOINT Hadr_endpoint
       STATE = STARTED
       AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
       FOR DATABASE_MIRRORING (
           AUTHENTICATION = CERTIFICATE NorthEUCert,
           ENCRYPTION = REQUIRED ALGORITHM AES,
           ROLE = ALL
       );
   ```

4. **Backup del cert público** (.cer) a disco:
   ```sql
   BACKUP CERTIFICATE NorthEUCert TO FILE = 'C:\certs\NorthEUCert.cer';
   ```

### Cert exchange

Después de crear los certs en ambos lados:

1. Copiar `NorthEUCert.cer` (SpainC ←) y `SpainCCert.cer` (NorthEU ←) entre las VMs.
   En la práctica: descargar a la máquina del operador y subir cruzado, o usar
   `Copy-Item` sobre PS Remoting si está habilitado.

2. **En cada VM**, crear un login mapeado al cert del otro lado y dar permisos al endpoint:

   ```sql
   -- En NorthEU (importa SpainC):
   CREATE LOGIN spainc_login WITH PASSWORD = '<pwd-throwaway>';
   CREATE USER spainc_user FOR LOGIN spainc_login;
   CREATE CERTIFICATE SpainCCert AUTHORIZATION spainc_user
       FROM FILE = 'C:\certs\SpainCCert.cer';
   GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO spainc_login;
   ```

   ```sql
   -- En SpainC (importa NorthEU):
   CREATE LOGIN northeu_login WITH PASSWORD = '<pwd-throwaway>';
   CREATE USER northeu_user FOR LOGIN northeu_login;
   CREATE CERTIFICATE NorthEUCert AUTHORIZATION northeu_user
       FROM FILE = 'C:\certs\NorthEUCert.cer';
   GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO northeu_login;
   ```

> **Sobre el password del login**: irrelevante en cuanto al cert exchange. La auth real es
> por cert. El password debe cumplir la policy de Windows simplemente para que el `CREATE
> LOGIN` no falle.

---

## 6. Seeding strategy: MANUAL obligatorio (cross-version)

> ⚠️ **Corrección crítica respecto al borrador anterior**: para cross-version (2017→2022)
> **AUTOMATIC seeding NO está soportado** por MS. Es obligatorio MANUAL. Ver
> [`official-microsoft-guidance.md`](official-microsoft-guidance.md) §2 con la cita oficial.

### Por qué MANUAL es obligatorio aquí

Cita literal de
[Distributed availability groups — cautions when migrating to higher versions](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups):

> "When you configure the distributed AG with a SQL Server migration target that is a higher
> version than the source, autoseeding isn't supported so the seeding mode must be set to
> `MANUAL`. If you don't disable AUTO-SEEDING, your migration will fail and you'll see error
> 946 'Cannot open database DistributionAG version xxx. Upgrade the database to the latest
> version'."

Razón técnica: el seeding automático intenta crear la BD en el secundario usando el formato
de log del primario. Cuando el secundario es versión superior, recibe páginas con formato
de la versión inferior y no consigue abrirlas durante el bootstrap.

### MANUAL seeding — workflow obligatorio

```
   NorthEU (2017)                                          SpainC (2022)
   ┌────────────────────────────┐                  ┌────────────────────────────┐
   │ 1. BACKUP DATABASE         │                  │                            │
   │    TO URL Azure Blob       │ ─── (full) ───►  │                            │
   │ 2. BACKUP LOG TO URL       │ ─── (tail) ───►  │ 3. RESTORE DATABASE        │
   │                            │                  │    FROM URL WITH NORECOVERY│
   │                            │                  │ 4. RESTORE LOG WITH        │
   │                            │                  │    NORECOVERY              │
   │                            │                  │                            │
   │ 5. CREATE AG_NorthEU       │                  │ 5. CREATE AG_SpainC        │
   │    SEEDING_MODE = MANUAL   │                  │    SEEDING_MODE = MANUAL   │
   │                            │                  │                            │
   │ 6. CREATE DAG WITH         │                  │                            │
   │    SEEDING_MODE = MANUAL   │ ───── log stream ──► │ Cualquier delta posterior │
   │                            │                  │ se aplica como log replay │
   └────────────────────────────┘                  └────────────────────────────┘
```

**Pasos detallados**:

1. **Storage Account intermedio** en cualquier región (Blob URL accesible desde ambas VMs).
2. **En NorthEU**: `BACKUP DATABASE [<AppDb>] TO URL = 'https://<sa>.blob.core.windows.net/...';`
   con credential SAS.
3. **En NorthEU**: `BACKUP LOG [<AppDb>] TO URL = '...';` (al menos uno para que el seeding
   alcance LSN actual).
4. **En SpainC**: `RESTORE DATABASE [<AppDb>] FROM URL = '...' WITH NORECOVERY;`
5. **En SpainC**: `RESTORE LOG [<AppDb>] FROM URL = '...' WITH NORECOVERY;`
6. Crear `AG_NorthEU` y `AG_SpainC` con `SEEDING_MODE = MANUAL`.
7. Crear `DAG_Migrate` con `SEEDING_MODE = MANUAL` en ambas réplicas.
8. **En SpainC**: `ALTER DATABASE [<AppDb>] SET HADR AVAILABILITY GROUP = AG_SpainC;`
   (este paso une la BD ya restaurada con NORECOVERY al AG).

A partir de aquí, el log generado en NorthEU desde el último log backup se transmite
**incrementalmente** al SpainC vía el endpoint DAG. La latencia inter-region sólo afecta a
ese delta, no al transfer inicial.

### Ventajas del MANUAL seeding (incluso si fuera opcional)

- **Throughput de seeding no limitado por RTT** — el `RESTORE FROM URL` paraleliza buffer
  reads contra Blob, mucho más rápido que enviar log records uno a uno.
- **Control sobre la ventana de seeding** — puede hacerse offline el día anterior, y luego
  sólo el delta fluye por el DAG.
- **El primario no acumula log** mientras dura el seeding — porque la BD destino ya está
  casi al día desde el restore inicial.

### Implicación para BDs grandes

| Tamaño BD | Tiempo aproximado del paso "backup + transfer + restore" |
|---|---|
| ≤ 100 GB | < 1 h end-to-end (con compresión y backup paralelo a 4 streams) |
| 100-500 GB | 1-3 h |
| 500 GB-1 TB | 3-6 h |
| > 1 TB | considerar `BACKUP ... WITH COMPRESSION, MAXTRANSFERSIZE=4194304, BUFFERCOUNT=64` y striped backup a 8 files |

Durante todo este tiempo la app sigue operativa en NorthEU. **No es downtime, es ventana de
preparación**.

### Permiso adicional requerido

Antes de crear el DAG con manual seeding, el secundario necesita permiso para crear la BD:

```sql
-- En SpainC (sobre AG_SpainC):
ALTER AVAILABILITY GROUP [AG_SpainC] GRANT CREATE ANY DATABASE;
```

---

## 7. Storage layout en la VM 2022

Recomendaciones para que el destino no sea el cuello de botella:

| Componente | Disco | Sugerencia |
|---|---|---|
| Sistema operativo | OS disk | Premium SSD P10 (default) |
| Data files (.mdf, .ndf) | Disco data | Premium SSD v2 o P40+, formateado NTFS 64K |
| Log file (.ldf) | Disco log dedicado | Premium SSD v2 con high IOPS, NTFS 64K |
| Backup local | Disco backup | Standard SSD (o blob directo via URL backup) |
| TempDB | Disco temp o ephemeral | Ephemeral si el SKU lo permite (D-series) |

**SKU mínimo recomendado** para la VM destino: `Standard_E4ads_v5` o equivalente
(4 vCPU, 32 GB RAM). Ajustar al perfil real del workload de la BD migrada.

> **No copiar 1:1 el SKU del 2017**. SQL 2022 con Intelligent Query Processing puede
> aprovechar más RAM y CPU; suele rendir igual con SKU algo menor que su predecesor.
> Validar con perf baseline post-cutover.

---

## 8. Trace flags y configuraciones de instancia

### En la VM 2017 (NorthEU)

Las que ya tiene del setup MI Link de este repo más:

- **TF 1800**: forzar 4K sector alignment para escrituras log (recomendado en cualquier
  AG cross-machine — ya debería estar).

### En la VM 2022 (SpainC)

- **TF 1800**: igual que arriba.
- **TF 9567**: opcional, comprime el flujo de log enviado a réplicas. Reduce ancho de
  banda usado entre regiones. Probarlo en POC; algunos workloads ven impacto CPU.
- **Optimize for ad-hoc workloads** (`sp_configure 'optimize for ad hoc workloads', 1`):
  default razonable en 2022.

### Memoria y MaxDOP

- `max server memory` = total VM RAM – 4 GB para SO – 2 GB para SQLOS overhead.
- `max degree of parallelism`: copiar el del 2017 actual. **No subir a 1 por default** —
  algunos workloads de reporting se mueren.
- `cost threshold for parallelism`: 50 (default 5 es demasiado bajo para hardware moderno).

---

## 9. Listener y cómo conecta la app post-cutover

### Sin listener (recomendado para este módulo)

La app cambia su connection string al **FQDN o IP directa** de la VM `vm-sql2022` durante
el cutover. Simple, sin dependencias.

**Pros**: cero infra adicional.
**Contras**: cualquier failover futuro requiere recambiar el connection string.

### Con listener AG

Si quieres listener, el AG local de SpainC puede tener un `LISTENER` definido — pero **en
clusterless single-replica el listener tiene utilidad limitada** (no hay réplica donde hacer
failover dentro del AG local).

**Recomendación**: **sin listener**. Si en el futuro promocionas a una topología HA real,
añades listener entonces.

### Connection string mínima recomendada para la app post-cutover

```
Server=vm-sql2022.spaincentral.cloudapp.azure.com;
Database=<AppDb>;
Encrypt=true;
TrustServerCertificate=false;
Connection Timeout=30;
ConnectRetryCount=3;
ConnectRetryInterval=10;
MultiSubnetFailover=true;
```

El `MultiSubnetFailover=true` es **buena práctica** aunque no haya múltiples subnets ahora:
acelera reconexión post-failover futuro y no rompe nada en cluster single-node.

---

## 10. Resumen de objetos creados (cheatsheet)

| Objeto | NorthEU (2017) | SpainC (2022) |
|---|---|---|
| AG local | `AG_NorthEU` (single replica) | `AG_SpainC` (single replica) |
| Distributed AG | `DAG_Migrate` (entre `AG_NorthEU` y `AG_SpainC`) | — (se crea desde un solo lado) |
| Master key | ✅ (existente) | ✅ nueva |
| Cert local | `NorthEUCert` (existente) | `SpainCCert` nuevo |
| Cert importado | `SpainCCert` (importado) | `NorthEUCert` (importado) |
| Login para endpoint del otro lado | `spainc_login` | `northeu_login` |
| Endpoint | `Hadr_endpoint` TCP 5022 (existente) | `Hadr_endpoint` TCP 5022 nuevo |
| NSG rule extra | `AllowMigrationFromSpainC` (5022 inbound desde 10.30.1.0/24) | `AllowMigrationFromNorthEU` (5022 inbound desde 10.10.1.0/24) |
| Windows Firewall rule | Ya existe del MI Link setup | Crear nueva: `SQL AG Endpoint 5022` |

---

## 11. Lo que NO se replica con el DAG (objetos out-of-band)

El DAG replica **el contenido de la BD**: tablas, índices, procs, datos, schema, usuarios
de BD. **No replica** nada a nivel de **instancia**:

- Logins (`master.sys.syslogins`).
- SQL Agent jobs, operators, alerts.
- Linked servers.
- Credentials.
- Database Mail profiles.
- Server-level triggers.
- Server-level certificates (los del endpoint son específicos por instancia, OK).
- Configuraciones de instancia (`sp_configure`).
- SSIS catalog (`SSISDB` es una BD aparte y suele tener su propia migración).

Todo esto se gestiona en [`out-of-band-objects.md`](out-of-band-objects.md). **No es opcional**
y suele ser la fuente #1 de "la app no funciona post-cutover".

---

## Referencias

- [Distributed AG — overview](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups)
- [Cross-cluster migration of AGs](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/cross-cluster-migration-of-always-on-availability-groups-for-os-upgrade)
- [Configure availability group endpoint with certificates](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-server-instances-to-host-availability-group)
- [Automatic seeding for AGs](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/automatically-initialize-always-on-availability-group)
- [Always On AG between SQL Server versions](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/always-on-availability-groups-sql-server)
