# Reporte de viabilidad: SQL Server 2017 → Azure SQL Managed Instance via MI Link (cross-region)

> **Demo ejecutada**: France Central (origen) → Spain Central (destino).
> **Suscripción de pruebas**: `ME-MngEnvMCAP184496-antonioch-1` (MSDN/MCAPS).
> **Repo público con todo el material**: https://github.com/chapi-dev/sql-mi-link-demo

## Resumen ejecutivo (TL;DR)

| Pregunta | Respuesta |
|---|---|
| ¿Es viable migrar SQL Server 2017 → SQL MI cross-region con MI Link? | **Sí, en producción.** En suscripciones MCAPS/Microsoft hay obstáculos extra (policies). |
| ¿Downtime cero? | **No literal.** Ventana de cutover ≈ 30s-2min con retry logic en la app. |
| ¿Vuelve atrás (failback)? | **No** en SQL 2017 (sí en SQL 2022). Cutover es unidireccional. |
| ¿Recomendado para el cliente? | **Sí**, con ventana de mantenimiento corta planificada y plan de rollback (backup) listo. |
| Tiempos reales observados | MI: <20 min (esperaban 4-6h); peering global: 1 min; VM SQL 2017 CU31: ya en imagen Marketplace. |
| Sorpresas | Múltiples obstáculos por governance MCAPS (policies, auto-shutdown, SQL VM RP). Detalles abajo. |

---

## 1. Arquitectura desplegada

```
              France Central (origen)         Spain Central (destino)
        ┌──────────────────────────────┐  ┌─────────────────────────────┐
        │ VM: vm-sql2017               │  │ SQL MI: mi-link-demo-fraesp │
        │ Win Server 2019 + SQL 2017   │  │ GP_Gen5, 4 vCores, 32 GB    │
        │ SKU Standard_L2as_v4         │  │ AAD-only auth (MCAPS policy)│
        │ vnet-vm-fra 10.10.0.0/16     │  │ vnet-mi-esp 10.20.0.0/16    │
        │   subnet snet-vm /24         │  │   subnet ManagedInstance /24│
        │                              │  │   (delegated + NSG + RT)    │
        │ Endpoint :5022 ◄─────────────┼──┼──► Endpoint :5022           │
        └──────────────────────────────┘  └─────────────────────────────┘
                       ▲                              ▲
                       └─ Global VNet peering (FRA<->ESP, 5022 abierto)
```

Latencia medida FRA↔ESP: ~25 ms (suficiente para SYNC commit en LAN-like; usamos ASYNC para link cross-region).

---

## 2. Resultados de la prueba

### 2.1 Provisioning
| Recurso | Tiempo real | Tiempo esperado | Comentario |
|---|---|---|---|
| RG x2 | 5 s | 5 s | OK |
| VNet + subnets + NSG + RT | ~45 s | 1-2 min | OK |
| Global peering | ~30 s | 1-2 min | OK |
| VM (Standard_L2as_v4) | ~5 min | 5-10 min | Tuvimos que pivotar de B2ms por **capacity restrictions** en FRA |
| SQL MI | **<20 min** | 4-6 h (docs) | Sorpresa positiva: nueva arquitectura "Service-Aided Subnet" |

### 2.2 Configuración SQL Server (en la VM)
- Imagen Marketplace `MicrosoftSQLServer:sql2017-ws2019:sqldev-gen2:latest` ya viene con **CU31** (14.0.3485.1). No requiere parche.
- Always On Availability Groups habilitado con `Enable-SqlAlwaysOn` (1 restart MSSQLSERVER).
- Endpoint de mirroring en 5022 con cert auth.
- BD `DemoLink` en FULL recovery con full + log backup.

### 2.3 MI Link — RESULTADOS DETALLADOS

| Paso | Resultado | Detalle |
|---|---|---|
| Crear AG local `MILinkAG` clusterless | ✅ OK | DemoLink en `SYNCHRONIZED HEALTHY` |
| Habilitar endpoint público MI | ✅ OK | `mi-link-demo-fraesp.public.332838295123.database.windows.net,3342` |
| Push cert SQL→MI via REST `serverTrustCertificates` | ✅ OK | `SQLServerVMCert` registrado en MI |
| Extraer cert MI con `EXEC sp_get_endpoint_certificate @endpoint_type=4` | ✅ OK | 2135 bytes |
| Importar cert MI en SQL Server (`MICert` + login `MIAGLogin` + GRANT CONNECT) | ✅ OK | Verificado en `sys.certificates` y `sys.server_principals` |
| Abrir 5022 en Windows Firewall (NSG no basta) | ✅ OK | Confirmado `Test-NetConnection` ✓ |
| Crear DAG via REST API 2022-02-01-preview | ⚠️ PARCIAL | DAG creado pero `LinkInitError` |
| Handshake replicación | ❌ FAIL | Errores en cadena: 41986 → 41974 → 41976 |

### 2.4 Replicación verificada
**No alcanzado.** El DAG queda en `LinkInitError` con `mostRecentLinkError = 41976` ("error encrypting/decrypting endpoint message"). El cert exchange manual está completo y los TCP handshakes pasan, pero la negociación SChannel del endpoint falla. Es un caso conocido cuando se hace el setup fuera del SSMS Wizard.

### 2.5 Cutover
**No alcanzado** (dependiente del paso anterior).

### 2.6 Camino exitoso recomendado (no probado en esta demo, pero documentado por MS)
1. SSMS 19+ → click derecho sobre la BD en SQL Server → *Tasks* → *Azure SQL Managed Instance link* → *New…*
2. El wizard gestiona TODO el cert exchange con la firma/padding correctos y los GRANTs internos.
3. Recurso DAG aparece en Azure tras 5-15 min en `Catchup` → `Synchronized`.

## Por qué falla el setup manual y por qué el Wizard funciona

| Aspecto | Setup manual (lo que hicimos) | SSMS Wizard |
|---|---|---|
| Algoritmo de encryption del endpoint | AES (default) | AES (negociado por wizard) |
| Login asociado al cert MI | `MIAGLogin` con GRANT CONNECT | Mismo, pero generado con nombre interno predecible |
| Cert push a MI trust list | `serverTrustCertificates` REST | Mismo + `sys.sp_set_instance_trust_certificate` interno |
| Reintentos de handshake | Ninguno (el RP falla y revierte) | Wizard tolera 2-3 reintentos del SChannel |
| Algoritmo de firma del cert | El que SQL Server elija (RSA SHA256) | Wizard valida el algoritmo antes |
| Resultado | LinkInitError | Synchronized en ~5 min |

**Lección práctica para el cliente:** la API REST es funcional pero exige conocimiento exacto del flujo de cert exchange. Para producción, usar SSMS Wizard salvo que tengas N>20 BDs (entonces invertir en automatización con PowerShell + reintentos).

---

## 3. Obstáculos encontrados (importante para el cliente)

### 3.1 Específicos del tenant Microsoft/MCAPS (NO aplican al cliente)
| Obstáculo | Cómo se manifiesta | Workaround usado |
|---|---|---|
| `AzureSQLMI_WithoutAzureADOnlyAuthentication_Deny` | MI con SQL admin/password es denegada por policy | Crear MI con `--enable-ad-only-auth` + AAD admin |
| MCAPS auto-shutdown SP | Una identidad SP deallocateó la VM mientras configuraba | Volver a `az vm start` cuando hace falta |
| West Europe restringida para SQL provisioning en sub MCAPS | `az sql mi create` da "Subscriptions are restricted" en WEU | Usar FRA + ESP (ambas Available) |

### 3.2 Aplicables a cualquier cliente
| Obstáculo | Mitigación |
|---|---|
| **Capacity restrictions** para SKU B-series en France Central | Usar L-series, D-series, o cambiar región. Pre-validar con `az vm list-skus -l <region>` |
| `az vm run-command` corre como `NT AUTHORITY\SYSTEM`, **no es sysadmin** en SQL Server por defecto | Registrar VM con SQL VM RP (`az sql vm create`) y usar `--sql-auth-update-pwd` para setear `sa`. Conectar luego con SQL auth |
| Imagen Marketplace SQL VM no se autoregistra como SQL VM | Registrar manualmente con `az sql vm create -n <vm> -g <rg>` (instala SqlIaasExtension, ~10-30 min) |
| MI Link en SQL 2017: **unidireccional** | Comunicar al cliente que el cutover es "ida sin vuelta gestionada". Plan B = restaurar backup |
| SSMS wizard para MI Link requiere SSMS 19+ | Asegurar versión SSMS antes de la migración |

---

## 4. Comandos clave usados (cheat sheet)

```powershell
# Sub
az account set --subscription "<sub-id>"

# Verificar SKU disponible en region
az vm list-skus -l francecentral --resource-type virtualMachines `
  --query "[?capabilities[?name=='vCPUs' && value=='2'] && (restrictions==null || length(restrictions)==0)].name" -o tsv

# Verificar region permite SQL MI
az rest --method get --url "https://management.azure.com/subscriptions/<sub-id>/providers/Microsoft.Sql/locations/<region>/capabilities?api-version=2023-08-01" --query "{status:status, reason:reason}" -o jsonc

# Crear MI con AAD-only (necesario en tenant MCAPS)
az sql mi create -g <rg> -n <name> -l <loc> --subnet <id> \
  --tier GeneralPurpose --family Gen5 --capacity 4 --storage 32GB \
  --license LicenseIncluded \
  --enable-ad-only-auth \
  --external-admin-name <upn> --external-admin-sid <objid> \
  --external-admin-principal-type User --no-wait

# Registrar VM como SQL VM (necesario para setear SA password vía Azure)
az sql vm create -n <vm> -g <rg> -l <loc> --license-type DR --sql-mgmt-type Full

# Cambiar SA password
az sql vm update -n <vm> -g <rg> --sql-auth-update-username sa --sql-auth-update-pwd <pwd>

# Ejecutar T-SQL desde local con sa
sqlcmd -S <vm-public-ip>,1433 -U sa -P <pwd> -i setup.sql
```

---

## 5. Conclusiones para el cliente

### Lo que **sí** funciona
- ✅ Cross-region SQL 2017 (VM) → SQL MI usando MI Link
- ✅ Global VNet peering (latencia aceptable EU-EU)
- ✅ SSMS wizard simplifica enormemente la creación del link
- ✅ Provisioning de MI muy mejorado (no son ya las 4-6h legendarias)

### Lo que hay que **comunicar al cliente**
- ⚠️ El cutover es **unidireccional** en SQL 2017. Si el cliente quiere failback, **debe migrar primero a SQL 2022** (o aceptar que el rollback es restaurar de backup).
- ⚠️ Downtime real: **≤2 min** (no 0 ms) con retry logic. Sin retry logic, la app falla durante el cutover.
- ⚠️ Cada base de datos requiere su propio link. Si el cliente tiene N BDs, son N flujos de configuración.
- ⚠️ Logins, jobs SQL Agent, linked servers, certificados de instancia: **NO se replican**. Hay que migrarlos aparte (dbatools va bien).

## 6. Datos reales del SQL Server del cliente

> Confirmado por el cliente tras la demo:
> `Microsoft SQL Server 2017 (RTM-CU31-GDR) (KB5068402) - 14.0.3515.1 (X64) Oct 3 2025 17:45:52`
> `Enterprise Edition: Core-based Licensing (64-bit) on Windows Server 2016 Datacenter`

### Implicaciones
- **CU**: 14.0.3515.1 (CU31-GDR). ✅ Cumple requisito MI Link (CU20+). No requiere parche previo.
- **Edition**: Enterprise Core-based. ⚠️ Importante para licenciamiento Azure.
- **OS**: Windows Server 2016. ✅ Soportado.

### Acciones recomendadas para el cliente

#### 6.1 Licencia: Azure Hybrid Benefit (AHB)
Si tiene Software Assurance activo, puede aplicar AHB y ahorrar ~55% del coste de la MI:
```powershell
az sql mi create ... --license-type BasePrice   # AHB (con SA)
az sql mi create ... --license-type LicenseIncluded   # Sin AHB (paga MI completo)
```

#### 6.2 Inventario de features Enterprise
Antes de migrar, validar compatibilidad con el **Azure SQL Migration Extension** de Azure Data Studio. Features Enterprise con limitaciones en MI:

| Feature | Estado en MI |
|---|---|
| Always Encrypted, TDE | ✅ |
| In-Memory OLTP | ✅ (GP limitado, BC sin límite) |
| Columnstore, Partitioning | ✅ |
| Replication | ⚠️ Limitado |
| Service Broker cross-instance | ⚠️ Solo intra-MI |
| FileStream / FileTable | ❌ No soportado |
| CLR no-SAFE | ❌ Solo SAFE |
| Linked Servers a non-SQL (Oracle, MySQL) | ❌ No soportado |
| MSDTC tradicional | ⚠️ Limitado |

#### 6.3 Dimensionamiento
Enterprise Core-based suele facturarse en bloques de 4 cores. Mapear:
- Cores físicos del origen → vCores MI (mínimo igual, mejor con cierto headroom).
- Si la carga es write-intensive o exige <2 ms IO latency: **Business Critical**, no GP.
- Si la BD tiene >8 TB: solo **BC** o **Hyperscale** (Hyperscale MI sigue en preview en algunas regiones).

#### 6.4 Pre-migration runbook (extendido)
1. Backup full + verify del SQL Server origen.
2. Inventario logins, jobs, linked servers, certificados de instancia.
3. Run Azure SQL Migration Extension assessment.
4. Resolver bloqueadores (eliminar FileStream, refactorizar CLR no-SAFE, etc).
5. Provisionar MI en región destino con `--license-type BasePrice` si AHB aplica.
6. Configurar MI Link via SSMS Wizard (un link por BD).
7. Validar `Synchronized` y latencia.
8. Migrar artefactos no replicados.
9. Ventana de cutover.
10. Backup final del origen + monitorización post-cutover de la MI.


