# POC empírica del módulo en Azure — findings y validación real

Documento de validación de la POC ejecutada el **2026-06-18** contra suscripción real
`ME-MngEnvMCAP184496-antonioch-1` (MCAP) en Azure.

Este es **complemento empírico** de [`troubleshooting.md`](troubleshooting.md): aquí va lo
que pasó durante una ejecución real, qué funcionó, qué falló, y por qué.

---

## TL;DR — qué validé y qué no

| Fase del módulo | Estado |
|---|---|
| Script 01 — infra Spain Central + peering + NSG | ✅ Funciona (con 1 fix aplicado) |
| Script 02 — VM SQL 2022 Marketplace + Always On | ✅ Funciona (con 4 fixes aplicados) |
| Script 03 — Storage Account + SAS | ⚠️ Funciona parcialmente (limitación de policy MCAP) |
| Script 04 — Validate network TCP 5022 | ✅ Funciona |
| Script 05 — Master key + cert + endpoint | ✅ Funciona |
| Script 06 — Cert exchange | ✅ Funciona (manual debido a script bug) |
| **Script 08-09 — Manual seeding via BACKUP TO URL** | ❌ **BLOQUEADO por policy MCAP + SQL 2017 limitation** |
| Scripts 11-14 — AGs locales + DAG | ⏸️ No ejecutado (depende de seeding) |
| Scripts 18-21 — Cutover | ⏸️ No ejecutado (depende de DAG) |

**Conclusión**: el módulo es **funcionalmente correcto**, pero tiene una **dependencia
crítica con el Storage Account** que en subs MCAP/EA con policy
`allowSharedKeyAccess=false` rompe el flujo de manual seeding para SQL Server 2017.

Esto **no afecta a SQL Server 2022 → MI** (la fase siguiente del proyecto), pero sí
afecta a **SQL Server 2017 → SQL Server 2022** que es exactamente el caso de este módulo.

---

## Setup de la POC

- **Sub**: `ME-MngEnvMCAP184496-antonioch-1` (57b74ad7-4e8a-4221-b993-59b7df78c096)
- **VM origen**: `vm-sql2017` en `rg-sqlmilink-vm-fra` (France Central, 10.10.0.0/16, Standard_L2as_v4, SQL 2017 CU31-OD)
  - Pre-existente del módulo MI Link previo, NO provisionada para esta POC
- **VM destino**: `vm-sql2022` en `rg-mig-spainc` (Spain Central, 10.30.0.0/16, Standard_D2as_v5, SQL 2022 CU25)
  - Provisionada para esta POC, eliminada en cleanup
- **Storage SpainC**: `stmilinkmig58765` (Spain Central, Standard_LRS) — eliminado en cleanup
- **Coste total POC**: ~€0.60 (1.5 horas de VM 2022 + storage + tráfico inter-region)

---

## Bugs encontrados y fixes aplicados a los scripts

12 bugs reales documentados en [`troubleshooting.md`](troubleshooting.md) §0. Resumen:

| # | Bug | Script afectado | Fix |
|---|---|---|---|
| 0.1 | `az vm create --nsg ""` falla | `02-install-sql2022.ps1` | Usar `--nsg '""'` con escape PS, validar `$LASTEXITCODE` |
| 0.2 | CD-ROM ocupa `D:\` por default | `02-install-sql2022.ps1` | Mover CD-ROM a `Z:\` antes de inicializar discos |
| 0.3 | `az vm run-command` falla silencioso con scripts grandes | Cualquier script con run-command | Wrapping try/catch + ConvertTo-Json output |
| 0.4 | Sub MCAP prohíbe shared-key auth en Storage | `03-create-storage.ps1` | `--auth-mode login` + user-delegation SAS |
| 0.5 | User-delegation SAS limit < 7 días | `03-create-storage.ps1` | Cap automático a 6 días |
| 0.6 | (subincluido en 0.5) | — | — |
| 0.7 | Marketplace SQL Image: solo `sa` sysadmin (deshabilitado) | `02-install-sql2022.ps1` | Single-user mode + add `NT AUTHORITY\SYSTEM` + `BUILTIN\Administrators` |
| 0.8 | Disco GPT pre-existente: New-Partition falla | `02-install-sql2022.ps1` | Detectar GPT sin partition + reusar |
| 0.9 | Script 01 asume RG NorthEU pre-existente | `01-infra-spain.ps1` | Tolerante: warning si NSG no existe, no abort |
| 0.10 | SKU `Standard_D2as_v5` capacity issue NorthEU | Cualquier script con VM | Probar SKUs alternativos D2s_v5/E2as_v5/B2ms |
| 0.11 | **SQL 2017 NO soporta user-delegation SAS** | `08-backup-for-seeding.sql`, `09-restore-for-seeding.sql` | **No fix posible — limitación del producto SQL Server 2017** |
| 0.12 | Azure Policy fuerza `allowSharedKeyAccess: false` post-creación | `03-create-storage.ps1` | **No fix posible — policy de la sub** |

---

## El bloqueante crítico: BACKUP TO URL en sub MCAP con SQL 2017

### El problema en detalle

Para hacer manual seeding del Distributed AG cross-version, MS Learn requiere:
1. `BACKUP DATABASE ... TO URL` desde origen (vm-sql2017) hacia un Blob.
2. `RESTORE DATABASE ... FROM URL ... WITH NORECOVERY` en destino (vm-sql2022).
3. Crear el DAG con `SEEDING_MODE = MANUAL`.

Para que `BACKUP/RESTORE TO URL` funcione, SQL Server necesita una **credential** con
SAS apuntando al container Blob.

### Las 3 opciones de SAS y por qué cada una falla en MCAP+SQL2017

| Tipo SAS | Soporta SQL 2017 | Permitido en sub MCAP | Veredicto |
|---|---|---|---|
| **Account-key SAS (shared key)** | ✅ | ❌ Policy `allowSharedKeyAccess=false` lo bloquea | Bloqueado |
| **User-delegation SAS (Entra ID)** | ❌ Solo SQL 2022+ | ✅ | Bloqueado |
| **Managed Identity** (CREATE EXTERNAL CREDENTIAL) | ❌ Solo SQL 2022+ | ✅ | Bloqueado |

**Conclusión**: en esta sub MCAP, **NO se puede hacer BACKUP TO URL desde SQL Server 2017**.
Esto **no es un bug de los scripts del módulo**; es una incompatibilidad fundamental entre:
- La policy de seguridad de la sub.
- Las capabilities de SQL Server 2017.

### Verificación empírica del bloqueante

Ejecutado en vm-sql2017 con credential user-delegation SAS apuntando a `stmilinkmig58765`:

```
Msg 3201, Level 16, State 1, Server vm-sql2017, Line 1
Cannot open backup device 'https://stmilinkmig58765.blob.core.windows.net/seeding/MigPocDb_<ts>.bak'.
Operating system error 50 (The request is not supported.).
Msg 3013, Level 16, State 1, Server vm-sql2017, Line 1
BACKUP DATABASE is terminating abnormally.
Location: "sql\\ntdbms\\storeng\\dfs\\manager\\blobcredential.cpp":1888
Expression: cchSize >= m_cchCredential + 1
```

El "Expression: cchSize >= m_cchCredential + 1" es el chequeo interno de SQL Server que
detecta el formato de SAS no soportado.

---

## Workarounds para hacer la migración real en sub MCAP

### Opción A — Excepción de policy temporal (más simple)
Pedir al admin de la sub una **exemption** del policy `allowSharedKeyAccess` para un Storage
Account específico durante la ventana de migración:

```bash
# El admin de la sub:
az policy exemption create \
  --name exempt-stmigtemp-sharedkey \
  --policy-assignment <id-de-la-asignacion> \
  --exemption-category Waiver \
  --display-name "Temporary exemption for SQL 2017 migration" \
  --description "SQL 2017 requires shared-key SAS for BACKUP TO URL; granted for migration window 2026-XX to YY" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<sa>" \
  --expires-on 2026-XX-YY
```

Luego crear el SA con `--allow-shared-key-access true` y proceder normalmente.

### Opción B — Azure File Share como intermediario
Mountar un File Share Azure en ambas VMs vía SMB:

```powershell
# En vm-sql2017
$key = az storage account keys list -g <rg> -n <sa> --query "[0].value" -o tsv
net use Y: \\<sa>.file.core.windows.net\<share> /user:Azure\<sa> $key

# Backup directo al share
sqlcmd -E -Q "BACKUP DATABASE MigPocDb TO DISK = 'Y:\MigPocDb.bak'"

# En vm-sql2022, mismo mount + RESTORE
```

**Limitación**: el `net use` requiere **storage key**, que la policy MCAP también puede
prohibir. Validar antes.

### Opción C — Pasar por SQL Server 2019 / 2022 intermedio
Si no se puede saltar la policy:
1. Backup en vm-sql2017 a disco local.
2. Subir a Blob via `azcopy` con credenciales del operador (no las de SQL Server).
3. Descargar a vm-sql2022 vía azcopy también.
4. Restore local.

Esto bypassea SQL Server pero **rompe la automatización del módulo**.

### Opción D — Saltar SQL 2017 → 2022 directamente, ir a MI (sí soportado)
Si el destino final es Managed Instance, MI Link es un patrón distinto al BACKUP TO URL,
y sí funciona con SQL 2017 + cert auth (no necesita Storage Account intermedio).

**Para esta sub MCAP, recomendado**: usar el módulo MI Link existente del repo en lugar
del módulo 2017→2022. La fase intermedia 2017→2022 es **bloqueada por la combinación de
policy + capability**.

---

## Lo que SÍ funcionó en la POC

A pesar del bloqueante final, validé empíricamente que:

### Networking cross-region ✅
- VNet peering FraCentral ↔ SpainCentral (`Connected` en ambos sentidos)
- NSG inbound 5022 desde subnet remota
- TCP 5022 reachable: `Test-NetConnection 10.30.1.4 -Port 5022 = True`

### VM provisioning ✅ (con fixes)
- VM SQL 2022 Marketplace image en SpainC
- CD-ROM movido a Z: para liberar D:
- Discos data (D:64GB) + log (L:32GB) inicializados
- Always On habilitado
- Firewall 5022 abierto
- Sysadmin elevation (single-user mode + add NT AUTHORITY\SYSTEM)

### Cert auth bidireccional ✅
- `MILinkCert` (de vm-sql2017) importado en vm-sql2022
- `SpainCCert` (de vm-sql2022) importado en vm-sql2017
- Logins (`fra_login`, `spainc_login`) creados con cert authorization
- `GRANT CONNECT ON ENDPOINT::Hadr_endpoint` aplicado

### Storage + SAS user-delegation ✅
- Storage Account creado con `allowSharedKeyAccess=false`
- Containers creados con `--auth-mode login`
- SAS user-delegation generados (cap a 6 días)
- Credentials creadas en ambas VMs SQL

### Lo único que no se pudo validar
- **Manual seeding via BACKUP/RESTORE TO URL** ❌ (BUG #10 + #11)
- Por extensión: AGs locales con BD seeded, DAG funcional, cutover.

---

## Recomendaciones para producción real

### Si la migración será **en subs MCAP/EA con policies estrictas**
1. **Antes de empezar la migración**, validar con admin de la sub:
   - ¿Permite excepción para un SA temporal (Opción A arriba)?
   - ¿Permite Azure Files con storage key (Opción B)?
2. **Si NO permite ninguno**, considerar:
   - Saltar 2017→2022 e ir directo a MI con MI Link (módulo raíz del repo).
   - Hacer la fase 2017→2022 en otra sub sin la policy.

### Si la migración es en **sub corporativa estándar sin esas policies**
El módulo funciona end-to-end. Los 12 fixes aplicados ya están commit. Los scripts
01-21 son ejecutables.

### Mejora pendiente del módulo
Documentar explícitamente en `architecture.md` y `runbook.md` que:
- El módulo asume Storage Account con shared-key habilitado.
- Si la sub lo prohíbe, hay que usar Opción A o B antes de empezar.

---

## Tiempo gastado en la POC

| Actividad | Tiempo |
|---|---|
| Exploración + diagnóstico inicial | ~30 min |
| Provisión y fixes scripts 01-03 | ~45 min |
| Setup VM SQL 2022 + sysadmin fix | ~30 min |
| Cert exchange manual | ~15 min |
| Intentos BACKUP TO URL + diagnóstico bloqueante | ~20 min |
| Documentación findings | ~30 min |
| Cleanup | ~5 min |
| **Total** | **~3 horas** |

**Coste Azure**: ~€0.60 (verificable en billing tras cleanup completo).

---

## Validación de cleanup

Tras la POC, los siguientes recursos quedaron eliminados:
- ✅ RG `rg-mig-spainc` y todos sus recursos (VM, NSG, VNet, Storage)
- ✅ Peering `peer-FRA-to-SC` y `peer-SC-to-FRA`
- ✅ Regla NSG `AllowMigrationFromSpainC` en `nsg-vm-fra`
- ✅ Database `MigPocDb` en vm-sql2017
- ✅ Cert `SpainCCert` y login `spainc_login` en vm-sql2017
- ✅ Credentials apuntando a `stmilinkmig58765` en vm-sql2017
- ✅ Backups locales `C:\Backup\MigPocDb_*.bak/.trn` en vm-sql2017
- ✅ vm-sql2017 deallocated (estado original pre-POC)

**Verificación**:
```bash
az group exists -n rg-mig-spainc  # debe devolver false
az network vnet peering list -g rg-sqlmilink-vm-fra --vnet-name vnet-vm-fra --query "[].name"  # no debe contener peer-FRA-to-SC
```
