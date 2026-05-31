# Arquitectura

Diseño de red, identidad y certificados para un Managed Instance Link entre
SQL Server (IaaS o on-prem) y Azure SQL Managed Instance.

## Vista lógica

```
┌────────────────────────────────────┐                    ┌────────────────────────────────────┐
│  Region A                          │                    │  Region B                          │
│  VNet A (10.X.0.0/16)              │   Global peering   │  VNet B (10.Y.0.0/16)              │
│                                    │   ◄──────────────► │                                    │
│  ┌──────────────────────────────┐  │   port 5022/TCP    │  ┌──────────────────────────────┐  │
│  │  Subnet snet-vm              │  │                    │  │  Subnet ManagedInstance      │  │
│  │  ┌────────────────────────┐  │  │                    │  │  (delegated, /27 mín.)       │  │
│  │  │  Windows Server VM     │  │  │                    │  │  ┌────────────────────────┐  │  │
│  │  │  SQL Server 2017+      │  │  │                    │  │  │  Azure SQL MI          │  │  │
│  │  │  Distributed AG primary│◄─┼──┼────────────────────┼──┼──┤  Distributed AG       │  │  │
│  │  │  Endpoint TCP 5022     │  │  │                    │  │  │  forwarder            │  │  │
│  │  └────────────────────────┘  │  │                    │  │  │  Endpoint TCP 5022    │  │  │
│  └──────────────────────────────┘  │                    │  │  └────────────────────────┘  │  │
│                                    │                    │  └──────────────────────────────┘  │
└────────────────────────────────────┘                    └────────────────────────────────────┘
```

### Componentes lógicos del Link

| Capa | En SQL Server | En MI |
|---|---|---|
| Availability Group local | `AG_<DbName>` con el primary local | (no aplica — MI es opaque) |
| Database Mirroring endpoint | `Hadr_endpoint` TCP 5022 | Endpoint interno gestionado por la plataforma |
| Distributed AG | `DAG_<DbName>` que une AG local y MI | Forwarder hacia la BD interna del MI |
| Cert local | Self-signed o CA-signed, asociado al endpoint | Cert opaco generado por MI |
| Cert remoto registrado como issuer | Cert del MI registrado vía `sp_certificate_add_issuer` | Cert del SQL Server registrado vía REST API |
| Modo de commit | `ASYNCHRONOUS_COMMIT` (forzoso cross-region) | igual |

---

## Diseño de red

### Topología recomendada

- **Una VNet por región**, peered con global VNet peering.
- **Subnet dedicado** al MI, delegado a `Microsoft.Sql/managedInstances`,
  con un mínimo de `/27` y sin otros recursos.
- **Subnet aparte** para la VM del SQL Server, idealmente `/24` con espacio
  para jumpboxes adicionales.

### NSG

Reglas mínimas necesarias:

| Dirección | Source | Destination | Port | Protocol | Justificación |
|---|---|---|---|---|---|
| Inbound (NSG MI subnet) | VNet del SQL Server | MI subnet | 5022 | TCP | DAG sync MI → SQL Server forwarder |
| Inbound (NSG VM subnet) | MI subnet | VM | 5022 | TCP | DAG sync SQL Server → MI forwarder |
| Inbound (NSG VM subnet) | Bastion subnet (o IP admin) | VM | 3389 | TCP | RDP para administración |
| Inbound (NSG VM subnet) | Bastion subnet | VM | 1433 | TCP | SQL Server tools (SSMS) |

> ⚠️ **El MI viene con un NSG gestionado por la plataforma** con reglas mínimas.
> No se puede modificar libremente. Las reglas del subnet solo aplican a tráfico
> *al subnet del MI*, no entre nodos internos del MI.

### Windows Firewall (en la VM)

Las reglas de NSG son a nivel de red de Azure pero **no abren puertos en la VM
en sí**. Hay que crear regla en Windows Firewall:

```powershell
New-NetFirewallRule -DisplayName "MI Link inbound 5022" `
  -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow

New-NetFirewallRule -DisplayName "MI Link outbound 5022" `
  -Direction Outbound -Protocol TCP -RemotePort 5022 -Action Allow
```

### DNS

El MI tiene un FQDN del tipo:

```
<mi-name>.<dns-zone>.database.windows.net
```

Donde `<dns-zone>` es un identificador único de la VNet del MI (ej. `1a2b3c4d5e6f`).
Este FQDN resuelve a:

- **IP privada del MI** desde dentro de la VNet (o desde VNets peered).
- **IP pública del MI** desde fuera, solo si el endpoint público está habilitado
  (puerto 3342, no 1433).

> Para que el SQL Server resuelva al MI por la IP privada, ambas VNets deben
> compartir DNS o el SQL Server debe poder resolver el FQDN del MI a través de
> Azure Private DNS / DNS condicional.

---

## Diseño de identidad

### Authentication en MI

**Recomendación**: Microsoft Entra-only auth. Para tenants con políticas de
seguridad estrictas, suele ser **obligatoria**.

Configuración:

1. **AAD Admin**: asignar un AAD group o usuario como admin del MI:
   ```bash
   az sql mi ad-admin create -g <rg-mi> --server <mi-name> `
     --display-name "<group-or-user-display>" `
     --object-id <aad-object-id>
   ```
2. **Bloquear SQL Authentication** (si el policy del tenant no lo hace ya):
   ```bash
   az sql mi update -g <rg-mi> -n <mi-name> --identity-type SystemAssigned `
     --set "properties.administrators.azureADOnlyAuthentication=true"
   ```
3. **Crear usuarios y roles** desde el AAD Admin:
   ```sql
   -- En MI, conectado como AAD Admin
   CREATE USER [app@tenant.onmicrosoft.com] FROM EXTERNAL PROVIDER;
   CREATE USER [SqlAdmins] FROM EXTERNAL PROVIDER;  -- AAD group
   ALTER SERVER ROLE sysadmin ADD MEMBER [SqlAdmins];
   ```

### Authentication en SQL Server origen

Para el cert exchange y el endpoint mirroring se usa **autenticación por
certificado**, no AAD. Esto es la única opción soportada para
`AUTHENTICATION = CERTIFICATE` en el endpoint mirror.

Para acceso a SSMS desde la VM, se puede usar:
- SQL Authentication local (cuenta `sa` o login dedicado).
- Windows Authentication si el SQL Server está domain-joined.

---

## Diseño de certificados

El Link entre SQL Server y MI se autentica mediante intercambio de
**certificados X.509 self-signed** asociados al Database Mirroring endpoint.

### Flujo de cert exchange (manual o vía wizard)

```
1. SQL Server crea cert local → asocia al endpoint mirror
       │
       ▼
2. SQL Server exporta cert público (PEM)
       │
       ▼
3. Operador (o wizard SSMS) registra el cert público en MI
   vía REST PUT /certificates
       │
       ▼
4. MI devuelve su cert público
       │
       ▼
5. Operador registra el cert del MI en SQL Server con
   sys.sp_certificate_add_issuer
       │
       ▼
6. Endpoint mirroring puede hacer handshake bidireccional con TLS
```

### Validity de los certs

- Self-signed por defecto, validity = 1 año.
- **Recomendación**: crear los certs con `EXPIRY_DATE = '2035-01-01'` (10 años)
  para evitar tener que rotar durante la vida útil del Link.
- Para entornos productivos críticos, considerar certs **CA-signed** desde una
  internal CA empresarial.

### Rotación de certs

Procedimiento (sin downtime del Link):

1. Crear nuevo cert en SQL Server (sin asociar al endpoint todavía).
2. Asociar el nuevo cert al endpoint mediante `ALTER ENDPOINT … ALTER AUTHENTICATION = CERTIFICATE [NewCert]`.
3. Re-exportar y re-registrar en MI vía REST API.
4. Drop del cert antiguo.

> En la práctica, la rotación es rara — los certs de mirroring no se renuevan
> automáticamente, hay que recordar hacerlo antes del expiry.

---

## Diseño del Distributed AG

### Componentes

| Pieza | Lado | Contenido |
|---|---|---|
| AG local | SQL Server | `AG_<DbName>` con el primary local del SQL Server |
| AG remoto (en MI) | MI | AG opaco que la plataforma del MI construye internamente |
| DAG | Ambos | `DAG_<DbName>` que enlaza ambos AGs |
| Endpoint mirror | Ambos | TCP 5022, encryption REQUIRED, auth CERTIFICATE |

### Listener URL

La sintaxis es **distinta** según el lado:

- En el SQL Server:
  ```
  TCP://<vm-fqdn-or-ip>:5022
  ```

- En el MI:
  ```
  TCP://<mi-fqdn>:5022;Server=[<MI_NAME>]
  ```

El sufijo `;Server=[…]` es **obligatorio** para apuntar al MI y solo lo parsea
correctamente SQL Server si tiene cargado el Azure Connect Pack
(ver [`azure-connect-pack.md`](azure-connect-pack.md)).

### Modo de commit

- Cross-region: **`ASYNCHRONOUS_COMMIT`** (forzoso).
- Cross-AZ (mismo region): puede ser `ASYNCHRONOUS_COMMIT` o (con SQL 2022+)
  `SYNCHRONOUS_COMMIT` en escenarios específicos.

Estado normal:
- `synchronization_state_desc = 'SYNCHRONIZING'` (no `'SYNCHRONIZED'`).
- `synchronization_health_desc = 'HEALTHY'`.
- `log_send_queue_size` y `redo_queue_size` cercanos a 0 en estable.

### Failover modes

Cross-region MI Link solo soporta **failover manual**:

- Planned failover (downtime mínimo coordinado).
- Forced failover (con data loss potencial, solo para DR real).

No hay failover automático cross-region.

---

## Diseño del rollback (capas externas al Link)

Detallado en [`migration-rollback-plan.md`](migration-rollback-plan.md).

Resumen visual de qué cubre cada capa:

```
                  ┌────────────┬────────────┬────────────┬────────────┐
                  │  Capa 1    │  Capa 2    │  Capa 3    │  Capa 4    │
                  │  .bak      │  Azure     │  Primary   │  BACPAC    │
                  │  COPY_ONLY │  Backup VM │  intacto   │  late      │
┌─────────────────┼────────────┼────────────┼────────────┼────────────┤
│ Solo BD         │     ✅     │     ⚠️      │     ✅     │     ✅     │
│ VM entera       │            │     ✅     │     ✅     │            │
│ Rollback rápido │     ⚠️      │     ✅     │     ✅     │            │
│ Rollback tardío │     ✅     │            │            │     ✅     │
│ Cero pérdida    │            │            │     ✅(*)  │            │
└─────────────────┴────────────┴────────────┴────────────┴────────────┘
(*) Cero pérdida si la app no escribió en MI tras el cutover.
```

---

## Observabilidad

### Métricas clave

| Métrica | Origen | Indicador de |
|---|---|---|
| `log_send_queue_size` | `sys.dm_hadr_database_replica_states` | Backlog de log no enviado al MI |
| `redo_queue_size` | id. | Backlog de log no aplicado en el MI |
| `last_commit_time` | id. | Lag de commit entre primary y MI |
| `synchronization_health_desc` | id. | Salud del Link (`HEALTHY` / `NOT_HEALTHY`) |
| `Storage Used` (MI) | Métrica del portal | Espacio consumido por la BD replicada |
| `CPU usage` (MI) | Métrica del portal | Carga durante seeding |

### Alertas recomendadas

Configurar **Azure Monitor alerts** sobre métricas del MI:

- `Storage Used > 80%` → riesgo de quedarse sin espacio durante seeding.
- `IO Bytes / Network Bytes` con desviaciones bruscas → posible problema del Link.
- Failed connections sobre el endpoint público (si está habilitado) → posible
  reconnaissance.

Y sobre el AG en SQL Server:

```sql
-- Query para usarse en una scheduled task / alert
SELECT
    DB_NAME(database_id) AS db_name,
    synchronization_state_desc,
    synchronization_health_desc,
    log_send_queue_size,
    redo_queue_size
FROM sys.dm_hadr_database_replica_states
WHERE synchronization_health_desc != 'HEALTHY'
   OR log_send_queue_size > 100000
   OR redo_queue_size > 100000;
```

---

## Referencias

- [Managed Instance link — feature overview](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-feature-overview)
- [Managed Instance link — prepare environment](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-preparation)
- [Distributed availability groups](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/distributed-availability-groups)
- [Azure SQL MI connectivity architecture](https://learn.microsoft.com/azure/azure-sql/managed-instance/connectivity-architecture-overview)
- [Managed Instance link best practices](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-best-practices)
