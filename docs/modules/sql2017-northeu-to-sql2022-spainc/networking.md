# Networking: VNet peering NorthEU ↔ SpainC + endpoints + storage

Diseño de red para que el Distributed AG cross-region funcione: peering bidireccional, NSGs,
firewall, DNS y Storage Account intermedio para el manual seeding.

> 📘 Pre-lectura: [`architecture.md`](architecture.md) §4 da el resumen. Este doc es el zoom
> con T-SQL, comandos `az` y troubleshooting de red.

---

## 1. Topología completa

```
                    Internet (no usado para tráfico DAG)
                            ╳ bloqueado por NSG
                            
   ┌──────────────────────────────────────────────────────────────────────┐
   │                        Azure backbone                                │
   │                                                                      │
   │  ┌─────────────────────────────┐    ┌─────────────────────────────┐  │
   │  │  region: NorthEurope        │    │  region: SpainCentral       │  │
   │  │  rg: rg-milink-vm           │    │  rg: rg-mig-spainc          │  │
   │  │                             │    │                             │  │
   │  │  vnet-vm  10.10.0.0/16      │    │  vnet-mig-spainc  10.30.0.0/16│
   │  │   └─ snet-vm 10.10.1.0/24   │    │   └─ snet-vm 10.30.1.0/24   │  │
   │  │      └─ vm-sql2017 10.10.1.4│    │      └─ vm-sql2022 10.30.1.4│  │
   │  │                             │    │                             │  │
   │  │  nsg-vm                     │    │  nsg-vm-spainc              │  │
   │  │   - AllowRDP        :3389   │    │   - AllowRDP        :3389   │  │
   │  │   - AllowMigFromSpainC :5022│◄═══┤   - AllowMigFromNorthEU :5022│  │
   │  │   (origen 10.30.1.0/24)     │    │   (origen 10.10.1.0/24)     │  │
   │  │                             │    │                             │  │
   │  └──────────────┬──────────────┘    └──────────────┬──────────────┘  │
   │                 │                                  │                 │
   │                 │ Global VNet peering (bidir)      │                 │
   │                 │ - Allow VN access:    ✅          │                 │
   │                 │ - Allow forwarded:    ✅          │                 │
   │                 │ - Allow gw transit:   ❌          │                 │
   │                 │ - Use remote gw:      ❌          │                 │
   │                 └──────────────────────────────────┘                 │
   │                                                                      │
   │  ┌─────────────────────────────────────────────────────────────────┐ │
   │  │  Storage Account (cualquier region accesible)                   │ │
   │  │  st-milink-migration  (Standard_LRS)                            │ │
   │  │  ├─ container: cutover-backups  (full+log pre-cutover)          │ │
   │  │  ├─ container: seeding          (.bak para manual seeding)      │ │
   │  │  ├─ container: rollback         (BACPAC export Capa 4)          │ │
   │  │  └─ container: migration        (scripts, configs, SSISDB.bak)  │ │
   │  └─────────────────────────────────────────────────────────────────┘ │
   └──────────────────────────────────────────────────────────────────────┘
```

---

## 2. Direcciones IP y CIDRs

### Bloques reservados

| Recurso | Región | CIDR | Notas |
|---|---|---|---|
| vnet-vm | NorthEU | 10.10.0.0/16 | Pre-existente del módulo MI Link |
| ↳ snet-vm | NorthEU | 10.10.1.0/24 | Subred de VM SQL 2017 |
| ↳ snet-mi (si existe) | NorthEU | 10.20.0.0/24 | Subred del MI (módulo MI Link) |
| **vnet-mig-spainc** | **SpainC** | **10.30.0.0/16** | **Nuevo — no solapar con 10.10/10.20** |
| ↳ snet-vm | SpainC | 10.30.1.0/24 | VM SQL 2022 |

### Validación de no-solape

```powershell
# Listar CIDRs de todas las VNets de la sub
az network vnet list --query "[].{name:name, location:location, cidr:addressSpace.addressPrefixes}" -o table
```

> ⚠️ Si el RG `rg-mig-spainc` ya existe con otro CIDR, **NO reutilizar**. Crear `vnet-mig-spainc-v2`
> con otro bloque (ej. 10.40.0.0/16). El peering falla con CIDRs solapados.

---

## 3. Global VNet peering — configuración detallada

### Crear el peering bidireccional

```powershell
# Variables
$rgNE  = "rg-milink-vm"
$vnetNE = "vnet-vm"
$rgSC  = "rg-mig-spainc"
$vnetSC = "vnet-mig-spainc"

$vnetNEId = az network vnet show -g $rgNE -n $vnetNE --query id -o tsv
$vnetSCId = az network vnet show -g $rgSC -n $vnetSC --query id -o tsv

# Peering NorthEU -> SpainC
az network vnet peering create `
    -g $rgNE `
    -n peer-NE-to-SC `
    --vnet-name $vnetNE `
    --remote-vnet $vnetSCId `
    --allow-vnet-access `
    --allow-forwarded-traffic `
    -o none

# Peering SpainC -> NorthEU (lado opuesto)
az network vnet peering create `
    -g $rgSC `
    -n peer-SC-to-NE `
    --vnet-name $vnetSC `
    --remote-vnet $vnetNEId `
    --allow-vnet-access `
    --allow-forwarded-traffic `
    -o none

# Verificar
az network vnet peering list -g $rgNE --vnet-name $vnetNE --query "[].{name:name, state:peeringState, sync:peeringSyncLevel}" -o table
az network vnet peering list -g $rgSC --vnet-name $vnetSC --query "[].{name:name, state:peeringState, sync:peeringSyncLevel}" -o table
# Ambos deben mostrar peeringState=Connected
```

### Settings y su significado

| Setting | Valor | Por qué |
|---|---|---|
| `--allow-vnet-access` | ✅ | Permite tráfico VM-to-VM cross-region |
| `--allow-forwarded-traffic` | ✅ | Necesario si el tráfico ha pasado por NVA en el origen (futureproof) |
| `--allow-gateway-transit` | ❌ | Solo necesario para ExpressRoute/VPN scenarios |
| `--use-remote-gateways` | ❌ | Idem |

### Coste del peering inter-region

El peering global tiene **coste de tráfico** (ambos sentidos):
- ~0.035 USD/GB (egress NorthEU)
- ~0.035 USD/GB (egress SpainC)

Para una migración con BD ~100 GB + log diario ~5 GB durante 1 semana:
- ~200 GB egress total
- ~7 USD costo de peering

Insignificante. **No pre-optimizar**.

---

## 4. NSG — reglas necesarias

### NorthEU (`nsg-vm` existente del módulo MI Link)

Añadir una regla nueva (no tocar las existentes):

```powershell
az network nsg rule create `
    --resource-group rg-milink-vm `
    --nsg-name nsg-vm `
    --name AllowMigrationFromSpainC `
    --priority 1200 `
    --source-address-prefixes 10.30.1.0/24 `
    --source-port-ranges '*' `
    --destination-address-prefixes '*' `
    --destination-port-ranges 5022 `
    --access Allow `
    --protocol Tcp `
    --direction Inbound `
    -o none
```

### SpainC (`nsg-vm-spainc` nuevo)

```powershell
# Crear el NSG
az network nsg create `
    --resource-group rg-mig-spainc `
    --name nsg-vm-spainc `
    --location spaincentral `
    -o none

# Regla 1: RDP (para operativa, opcional - mejor usar Bastion)
az network nsg rule create `
    --resource-group rg-mig-spainc `
    --nsg-name nsg-vm-spainc `
    --name AllowRDP `
    --priority 1000 `
    --source-address-prefixes '<tu-ip-publica>' `
    --destination-port-ranges 3389 `
    --access Allow --protocol Tcp --direction Inbound `
    -o none

# Regla 2: Distributed AG endpoint
az network nsg rule create `
    --resource-group rg-mig-spainc `
    --nsg-name nsg-vm-spainc `
    --name AllowMigrationFromNorthEU `
    --priority 1100 `
    --source-address-prefixes 10.10.1.0/24 `
    --destination-port-ranges 5022 `
    --access Allow --protocol Tcp --direction Inbound `
    -o none

# Asociar al subnet
az network vnet subnet update `
    --resource-group rg-mig-spainc `
    --vnet-name vnet-mig-spainc `
    --name snet-vm `
    --network-security-group nsg-vm-spainc `
    -o none
```

### Verificación de reglas

```powershell
az network nsg show -g rg-milink-vm -n nsg-vm --query "securityRules[?contains(name, 'Migration')].{name:name, prio:priority, src:sourceAddressPrefix, dst:destinationPortRange, access:access}" -o table
az network nsg show -g rg-mig-spainc -n nsg-vm-spainc --query "securityRules[?contains(name, 'Migration')].{name:name, prio:priority, src:sourceAddressPrefix, dst:destinationPortRange, access:access}" -o table
```

---

## 5. Windows Firewall (en cada VM)

```powershell
# Ejecutar en vm-sql2017 (probablemente ya existe del modulo MI Link, idempotente)
New-NetFirewallRule -DisplayName "SQL AG Endpoint 5022" `
    -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow `
    -ErrorAction SilentlyContinue
```

```powershell
# Ejecutar en vm-sql2022
New-NetFirewallRule -DisplayName "SQL AG Endpoint 5022" `
    -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow
```

### Verificación end-to-end de la red (de VM a VM)

```powershell
# Desde vm-sql2017, probar conectividad a vm-sql2022
Test-NetConnection -ComputerName 10.30.1.4 -Port 5022
# Resultado esperado:
# ComputerName: 10.30.1.4
# RemoteAddress: 10.30.1.4
# RemotePort: 5022
# TcpTestSucceeded: True
```

Si **TcpTestSucceeded: False**, ir descartando capas:
1. `Test-NetConnection 10.30.1.4 -Port 3389` → si OK, problema en la regla 5022.
2. `ping 10.30.1.4` → si OK, problema TCP (firewall/NSG).
3. `Resolve-DnsName 10.30.1.4` → si falla, problema DNS.
4. Si nada llega, problema de peering.

---

## 6. DNS

### Resolución entre VMs (mínimo viable)

Para que las VMs se vean por **nombre** y no IP, dos opciones:

**Opción A — Hosts file (manual, mínimo viable)**
```powershell
# En vm-sql2017, editar C:\Windows\System32\drivers\etc\hosts
Add-Content "C:\Windows\System32\drivers\etc\hosts" `
    "`n10.30.1.4    vm-sql2022 vm-sql2022.spaincentral.cloudapp.azure.com"

# En vm-sql2022, editar C:\Windows\System32\drivers\etc\hosts
Add-Content "C:\Windows\System32\drivers\etc\hosts" `
    "`n10.10.1.4    vm-sql2017 vm-sql2017.northeurope.cloudapp.azure.com"
```

**Opción B — Azure Private DNS Zone (recomendado a largo plazo)**

```powershell
# Crear zona privada
az network private-dns zone create `
    -g rg-mig-spainc -n migration.internal `
    -o none

# Vincular a ambas VNets
az network private-dns link vnet create `
    -g rg-mig-spainc -n link-spainc `
    --zone-name migration.internal `
    --virtual-network "/subscriptions/.../vnet-mig-spainc" `
    --registration-enabled true `
    -o none

az network private-dns link vnet create `
    -g rg-milink-vm -n link-northeu `
    --zone-name migration.internal `
    --virtual-network "/subscriptions/.../vnet-vm" `
    --registration-enabled false `
    -o none

# Registros A manuales
az network private-dns record-set a add-record `
    -g rg-mig-spainc -z migration.internal -n vm-sql2017 -a 10.10.1.4 -o none
az network private-dns record-set a add-record `
    -g rg-mig-spainc -z migration.internal -n vm-sql2022 -a 10.30.1.4 -o none
```

> Para esta migración la **Opción A** (hosts file) es suficiente. La Opción B vale la pena si
> se va a mantener la topología post-cutover (Estrategia B post-cutover).

### FQDNs en los endpoints AG

Los endpoints del AG se referencian por FQDN, no IP. **Asegúrate de que el FQDN resuelve
a la IP correcta**:

```powershell
# Desde vm-sql2022:
Resolve-DnsName vm-sql2017
# Debe devolver 10.10.1.4
```

---

## 7. Storage Account para backups intermedios

### Propósito
- **Manual seeding** del DAG cross-version: backup full+log del 2017 → restore en 2022.
- **Backup pre-cutover** (Capa 1 de rollback).
- **BACPAC export** (Capa 4 de rollback).
- **SSISDB backup** si aplica.

### Provisionar

```powershell
$saName = "stmilinkmigration$(Get-Random -Maximum 9999)"
az storage account create `
    -g rg-mig-spainc -n $saName `
    -l spaincentral `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    -o none

# Containers
az storage container create --account-name $saName --name seeding --auth-mode login -o none
az storage container create --account-name $saName --name cutover-backups --auth-mode login -o none
az storage container create --account-name $saName --name rollback --auth-mode login -o none
az storage container create --account-name $saName --name migration --auth-mode login -o none
```

### Región del Storage

¿NorthEU o SpainC? Trade-off:

| Ubicación | Pros | Contras |
|---|---|---|
| **NorthEU** (cerca del origen) | Backups rápidos desde vm-sql2017 | Restore en SpainC paga egress inter-region |
| **SpainC** (cerca del destino) | Restore en vm-sql2022 rápido | Backup desde vm-sql2017 paga egress |
| Región third-party | Distancia simétrica (peor en ambos sentidos) | Sin pros reales |

**Recomendación**: **SpainC**. El restore (seeding inicial del DAG) es la operación pesada;
el backup es relativamente más rápido por compresión.

### SAS token para `BACKUP/RESTORE TO URL`

```powershell
# Generar SAS de 30 dias con permisos lectura+escritura
$expiry = (Get-Date).AddDays(30).ToString("yyyy-MM-ddTHH:mm:ssZ")
$sas = az storage container generate-sas `
    --account-name $saName `
    --name seeding `
    --permissions rwl `
    --expiry $expiry `
    --auth-mode login `
    --as-user `
    -o tsv

Write-Host "SAS token (guardar en password manager):"
Write-Host $sas
```

### Usar el SAS en SQL Server

```sql
-- En vm-sql2017 y vm-sql2022:
CREATE CREDENTIAL [https://stmilinkmigration<X>.blob.core.windows.net/seeding]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '<sas-token-sin-el-?-inicial>';
```

Luego:
```sql
BACKUP DATABASE [AppDb]
TO URL = 'https://stmilinkmigration<X>.blob.core.windows.net/seeding/AppDb_full.bak'
WITH COMPRESSION, CHECKSUM, FORMAT;
```

### Coste del Storage

| Componente | Coste mensual estimado |
|---|---|
| Standard_LRS 500 GB | ~10 €/mes |
| Egress inter-region (200 GB durante 1 sem) | ~7 € (one-time) |
| Transactions | despreciable |
| **Total durante la migración (1-4 sem)** | **~15-25 €** |

Tras el cutover y T+90d, **borrar el container `seeding`** y dejar sólo `cutover-backups`
durante el periodo de retención de rollback Capa 1.

---

## 8. Conectividad de la VM a Storage (sin private endpoint)

Por defecto, el Storage es accesible vía Internet. SQL Server VM accede al Storage usando
**TCP 443** outbound.

### Verificar
```powershell
Test-NetConnection -ComputerName stmilinkmigration<X>.blob.core.windows.net -Port 443
```

Si falla:
- Verificar que el NSG **no bloquea outbound 443** (el default de NSG permite outbound,
  pero algunas orgs lo restringen).
- Verificar Service Tag `Storage` en outbound NSG rules.

### Si se quiere private endpoint (opcional, security-hardened)

Crear un private endpoint al Storage en cada VNet:

```powershell
az storage account update -n $saName --default-action Deny -o none

# Private endpoint en NorthEU
az network private-endpoint create `
    -g rg-milink-vm -n pe-storage-NE `
    --vnet-name vnet-vm --subnet snet-vm `
    --private-connection-resource-id "/subscriptions/.../$saName" `
    --group-id blob `
    --connection-name conn-storage-NE -o none

# Private endpoint en SpainC
az network private-endpoint create `
    -g rg-mig-spainc -n pe-storage-SC `
    --vnet-name vnet-mig-spainc --subnet snet-vm `
    --private-connection-resource-id "/subscriptions/.../$saName" `
    --group-id blob `
    --connection-name conn-storage-SC -o none

# Vincular Private DNS zone privatelink.blob.core.windows.net a ambas VNets
```

> Complejidad alta para el beneficio de esta migración. **No recomendado** salvo política
> corporativa que lo exija.

---

## 9. Bandwidth, MTU y throughput

### Bandwidth esperado backbone Azure

- NorthEU ↔ SpainC: ~1-10 Gbps según VM SKU y horario.
- Bottleneck típico: **VM NIC** (suele ser el limit, no el backbone).
- Para Standard_E4ads_v5: hasta 4 Gbps por NIC.

### MTU
- Default 1500 funciona en backbone Azure.
- **No activar Jumbo Frames** (9000 MTU) — puede romper paquetes en hops intermedios.

### Optimizar throughput de seeding/backup

```sql
-- En el script de BACKUP TO URL:
BACKUP DATABASE [AppDb]
TO URL = 'https://.../seeding/AppDb_full_1.bak',
   URL = 'https://.../seeding/AppDb_full_2.bak',
   URL = 'https://.../seeding/AppDb_full_3.bak',
   URL = 'https://.../seeding/AppDb_full_4.bak'  -- striped a 4 ficheros
WITH COMPRESSION,
     CHECKSUM,
     FORMAT,
     MAXTRANSFERSIZE = 4194304,  -- 4 MB
     BUFFERCOUNT = 64,
     STATS = 10;
```

Striped backup + tunables sube throughput de ~50 MB/s a ~300 MB/s en muchos casos.

---

## 10. Latencia y estabilidad — medición post-setup

### Medición rápida con `Test-NetConnection`

```powershell
# Bucle de 100 muestras
1..100 | ForEach-Object {
    $r = Test-NetConnection -ComputerName 10.30.1.4 -Port 5022 -InformationLevel Quiet -WarningAction SilentlyContinue
    Start-Sleep -Milliseconds 100
    [PSCustomObject]@{
        Sample = $_
        Success = $r
        Timestamp = Get-Date
    }
} | Where-Object Success | Measure-Object | Select-Object Count
```

### Medición precisa con `tcping` (recomendado)

Instalar `tcping`:
```powershell
# Choco
choco install tcping
# O descargar de elifulkerson.com/projects/tcping.php
```

Medir RTT a TCP 5022:
```powershell
tcping -n 100 10.30.1.4 5022
# Output: avg, min, max latency
```

Esperado:
- avg ~25-35 ms
- max < 100 ms (sin picos sostenidos)
- jitter < 10 ms

Si supera, **considerar modo ASYNC** (ya recomendado en [`rpo-options.md`](rpo-options.md))
y planear cutover con extra buffer.

### Throughput sostenido con iperf3

```powershell
# En vm-sql2022 (server)
iperf3 -s

# En vm-sql2017 (client)
iperf3 -c 10.30.1.4 -t 60 -P 4
# Output: bandwidth promedio en 60s con 4 streams
```

Esperado: > 500 Mbps. Si menor, investigar (NIC SKU, VM size, hora del día).

---

## 11. Diagnóstico de conectividad — runbook

### Problema: "VMs no se conectan en 5022"

Pasos por orden:

1. **`Test-NetConnection` desde ambos lados**. Si solo uno funciona, el otro tiene NSG/firewall mal.
2. **`Get-NetTCPConnection -LocalPort 5022`** en la VM destino — ¿SQL está escuchando?
3. **`sqlcmd -Q "SELECT * FROM sys.tcp_endpoints"`** — ¿endpoint Hadr_endpoint existe y está STARTED?
4. **`telnet 10.30.1.4 5022`** desde NorthEU — ¿completa el TCP handshake?
5. **`netsh advfirewall firewall show rule name=all`** en la VM destino — ¿regla 5022 existe?
6. **`Get-AzNetworkSecurityGroup -ResourceGroupName rg-mig-spainc | Format-List`** — ¿NSG tiene la regla 5022?

### Problema: "Endpoints conectan pero autenticación falla"

Errores típicos: `Login failed for user '<>'`, `cert mismatch`, `endpoint mirroring not configured`.

- Verificar cert exchange completo: cert público de cada lado importado en el otro.
- Verificar GRANT CONNECT ON ENDPOINT al login mapeado al cert.
- Verificar que el cert no expiró: `SELECT name, expiry_date FROM sys.certificates`.

### Problema: "Seeding/restore desde Blob falla con 'cannot access URL'"

- Validar SAS token: `Resolve-DnsName <sa>.blob.core.windows.net`.
- Validar SAS permissions: debe incluir `r`, `w`, `l`.
- Validar credential en SQL: `SELECT * FROM sys.credentials WHERE name LIKE '%blob%'`.
- Validar que no expiró el SAS.

---

## 12. Costes mensuales totales de networking (estimado)

| Componente | Coste mensual estimado |
|---|---|
| Peering NorthEU ↔ SpainC | ~2 € (~10 GB/día) — sólo durante migración |
| Storage Account | ~10-15 € |
| Egress backup intermedio | ~5-10 € (one-time) |
| Private DNS zone (si Opción B) | ~0.50 € |
| Bastion (si se usa) | ~120 € — opcional |
| **Total infra de red durante migración** | **~20-30 €** (sin Bastion) |

Insignificante comparado con el coste de las VMs SQL.

---

## Referencias

- [Azure VNet peering — Global peering](https://learn.microsoft.com/azure/virtual-network/virtual-network-peering-overview)
- [SQL Server Always On endpoint configuration](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-server-instances-to-host-availability-group)
- [SQL Server backup to URL](https://learn.microsoft.com/sql/relational-databases/backup-restore/sql-server-backup-to-url)
- [Azure NSG — service tags](https://learn.microsoft.com/azure/virtual-network/service-tags-overview)
- [Azure Private DNS zones](https://learn.microsoft.com/azure/dns/private-dns-overview)
- [iperf3 official](https://iperf.fr/)
- [tcping](https://www.elifulkerson.com/projects/tcping.php)
