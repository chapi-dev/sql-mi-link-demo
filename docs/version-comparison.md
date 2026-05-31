# Comparación de versiones SQL Server para MI Link

Decisión técnica: **¿migrar con la versión actual del cliente o hacer upgrade previo?**
La respuesta depende de qué garantías de failback y simplicidad operativa se necesiten.

## Matriz de capacidades

| Capacidad | SQL 2016 | SQL 2017 | SQL 2019 | SQL 2022 | SQL 2025 |
|---|---|---|---|---|---|
| Replicación SQL → MI (one-way) | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Failback online via Link** | ❌ | ❌ | ❌ | ✅ (¹) | ✅ (²) |
| **Reverse migration** (MI → SQL) | ❌ | ❌ | ❌ | ✅ (¹) | ✅ (²) |
| Wizard SSMS funcional out-of-the-box | ⚠️ | ⚠️ (³) | ✅ | ✅ | ✅ |
| Paquetes extra requeridos | Sí | **KB5050533** (Azure Connect Pack) | Ninguno (CU15+) | Ninguno (RTM+) | Ninguno |
| Update policy MI necesaria | n/a | n/a | n/a | *SQL Server 2022* | *SQL Server 2025* |
| Compat level por defecto | 130 | 140 | 150 | 160 | 170 |
| Soporte mainstream (referencia, sin fechas) | Terminado | Próximo a EOL | Activo | Activo | Activo (más largo) |

(¹) Requiere que el MI esté configurado con la **update policy "SQL Server 2022"**.
La policy por defecto (*Always-up-to-date*) **no** soporta failback al primary.

(²) Requiere update policy "SQL Server 2025" en el MI. Mismas reglas que (¹).

(³) En SQL 2017 el wizard falla con `Msg 2812 sp_certificate_add_issuer` y la ruta
T-SQL manual falla con `Msg 19499 invalid listener URL` **a menos que** se instale el
**Azure Connect Pack (KB5050533)**. Ver [`azure-connect-pack.md`](azure-connect-pack.md).

## Las 3 opciones de proyecto

### Opción A — Migrar con la versión actual (sin upgrade)

```
SQL Server actual ──MI Link one-way──► Azure SQL MI
                       (CUTOVER)
                       
Rollback = 4 capas externas al Link (ver migration-rollback-plan.md)
```

**Cuándo elegirla:**
- Cliente no puede/no quiere asumir un upgrade in-place.
- Ventana de testing y cambio acotada a un único proyecto.
- Acepta el coste operativo de mantener un plan de rollback multi-capa.

**Implicaciones técnicas:**
- Una vez en MI, la BD queda en formato MI nativo. No hay vuelta atrás vía Link.
- Rollback depende de backups externos (Capas 1 y 2), no del Link.
- El compat level **debe mantenerse en el de origen** (140 si es 2017) hasta confirmar
  el punto de no retorno, para que el rollback bacpac sea viable.
- Limita el uso de features modernas (ADR, ledger, GENERATE_SERIES, UTF-8 collations…).

### Opción B — Upgrade in-place a SQL 2022/2025, luego migrar

```
SQL Server 2017 ──upgrade in-place──► SQL Server 2022/2025 ──MI Link bidireccional──► MI
                                                                                       │
                       Rollback = el propio Link ◄────────────────────────────────────┘
```

**Cuándo elegirla:**
- Hay margen para dos cambios secuenciales con sus respectivas ventanas y testings.
- El cliente quiere quedar en una versión soportada de larga duración.
- Se prefiere un mecanismo de failback "oficial" sobre defense in depth externa.

**Implicaciones técnicas:**
- El upgrade es **otro proyecto**: testing funcional + performance + plan de rollback propio.
- Cambio del Cardinality Estimator (puede regresar planes de ejecución).
- Features deprecadas en versiones nuevas pueden bloquear el upgrade
  (revisar Database Migration Assistant / Data Migration Assessment).
- El MI destino se debe crear/configurar con la **update policy correspondiente**
  (*SQL Server 2022* o *SQL Server 2025*) — no la default.

### Opción C — Migrar con la versión actual, MI con update policy futureproof

```
SQL Server actual ──MI Link one-way──► Azure SQL MI (update policy SQL Server 2025)
                       (CUTOVER)
                       
Rollback inicial = 4 capas externas (mismo que Opción A)

Tras estabilizar y, en futuro, montar un SQL Server 2025 secundario:
    SQL MI ◄──Link bidireccional──► SQL Server 2025  (failback nativo)
```

**Cuándo elegirla:**
- No se quiere mezclar upgrade + migración cross-region en la misma ventana.
- Se quiere dejar el destino preparado para escenarios futuros (DR, reverse).
- El MI destino se puede crear desde cero con la update policy alineada con la
  versión futura objetivo del cliente.

**Implicaciones técnicas:**
- La migración inicial se comporta exactamente igual que la Opción A.
- El **MI debe crearse desde el inicio** con la update policy "SQL Server 2025"
  (cambiar la policy *después* tiene restricciones temporales según la docs oficial).
- A medio plazo, cualquier SQL Server 2025 que monte el cliente puede usar el MI
  como secundario con Link bidireccional **sin reconfigurar el MI**.

## Recomendación general

Opción **C** es la más equilibrada en escenarios donde:
- No hay tiempo/recursos para hacer upgrade + migración en proyectos separados.
- Se quiere preservar la posibilidad de failback futuro sin recrear el MI.
- Se acepta que el rollback inicial sigue siendo externo al Link (Capas 1-4).

Opción **B** es preferible si:
- Hay un compromiso claro de modernización a 2022/2025 a corto plazo.
- El equipo prefiere mecanismos "oficiales" sobre defense in depth manual.

Opción **A** se justifica solo cuando el upgrade es estratégicamente inviable
(certificaciones, soporte de terceros, contratos…) y el rollback multi-capa
externo se considera suficiente.

## Cómo configurar el MI con la update policy correcta

```powershell
# Crear MI con update policy SQL Server 2025 (futureproof)
az sql mi create -g <rg> -n <mi-name> -l <region> --subnet <subnet-id> `
  --tier GeneralPurpose --family Gen5 --capacity 4 --storage 32GB `
  --license LicenseIncluded `
  --service-principal-type SystemAssigned `
  --update-policy "SQL Server 2025"
```

```powershell
# Verificar la policy actual de un MI existente
az sql mi show -g <rg> -n <mi-name> --query "{name:name, updatePolicy:updatePolicy}"
```

⚠️ **Restricciones de cambio de policy**: cambiar de *SQL Server 2025* a
*Always-up-to-date* está temporalmente deshabilitado en la fecha de redacción de
esta guía. Consultar siempre la
[docs oficial](https://learn.microsoft.com/azure/azure-sql/managed-instance/update-policy)
antes de decidir.

## Features bloqueantes para rollback a versiones anteriores

Si en el MI se activan features que **no existen** en la versión origen, el rollback
vía BACPAC (Capa 4) fallará. Lista mínima a evitar mientras la migración no esté
"sellada":

| Feature | Introducida en | Bloquea rollback a |
|---|---|---|
| Accelerated Database Recovery (ADR) | 2019 (compat 150) | 2017 e inferiores |
| Edge constraints | 2019 | 2017 e inferiores |
| UTF-8 collations | 2019 | 2017 e inferiores |
| Always Encrypted con secure enclaves | 2019+ | 2017 e inferiores |
| Ledger tables | 2022 | 2019 e inferiores |
| GENERATE_SERIES, DATE_BUCKET | 2022 | 2019 e inferiores |
| External JSON nativo (`JSON_OBJECT`, `JSON_ARRAY`) | 2022 | 2019 e inferiores |

Validar post-cutover **antes del punto de no retorno**:

```sql
-- En MI, detectar uso de features incompatibles
SELECT * FROM sys.dm_exec_query_optimizer_info WHERE counter LIKE '%2019%';
SELECT name, compatibility_level FROM sys.databases WHERE name = N'<db>';
```

## Referencias oficiales

- [Update policy in Azure SQL Managed Instance](https://learn.microsoft.com/azure/azure-sql/managed-instance/update-policy)
- [Disaster recovery with the Managed Instance link](https://learn.microsoft.com/azure/azure-sql/managed-instance/managed-instance-link-disaster-recovery)
- [Database compatibility level — ALTER DATABASE](https://learn.microsoft.com/sql/t-sql/statements/alter-database-transact-sql-compatibility-level)
- [Data Migration Assistant — pre-upgrade assessment](https://learn.microsoft.com/sql/dma/dma-overview)
