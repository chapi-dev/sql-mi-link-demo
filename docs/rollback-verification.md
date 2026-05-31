# Verificación del plan de rollback

Procedimiento para validar **empíricamente** cada una de las 4 capas del plan de
rollback antes del cutover real. Todo se ejecuta en un entorno de staging
idéntico al de producción.

> **Objetivo**: garantizar que el "botón del pánico" funciona end-to-end y que
> el equipo conoce los comandos exactos a ejecutar bajo presión.

## Pre-requisitos del drill

- Entorno staging desplegado siguiendo [`runbook.md`](runbook.md).
- MI Link `SYNCHRONIZING HEALTHY` con `log_send_queue_size` y `redo_queue_size` a 0.
- Una tabla "testigo" en la BD para medir row counts:
  ```sql
  CREATE TABLE dbo.RollbackAudit (
      AuditId       INT IDENTITY PRIMARY KEY,
      EventType     NVARCHAR(50),
      EventDescription NVARCHAR(500),
      EventTime     DATETIME2 DEFAULT SYSUTCDATETIME()
  );

  CREATE TABLE dbo.DemoRows (
      Id          INT IDENTITY PRIMARY KEY,
      Origin      NVARCHAR(50),
      Note        NVARCHAR(200),
      InsertedAt  DATETIME2 DEFAULT SYSUTCDATETIME()
  );
  ```

## Drill 1 — Capa 1 (backup nativo) end-to-end

### Setup

1. Marcar el momento del backup en la tabla de auditoría:
   ```sql
   INSERT INTO dbo.RollbackAudit (EventType, EventDescription)
   VALUES ('PRE_CUTOVER_BACKUP', 'Marker antes del backup');
   ```
2. Tomar el backup full + log con `COPY_ONLY`:
   ```sql
   BACKUP DATABASE <DbName>
       TO DISK = N'C:\sqlbackups\<DbName>_FULL.bak'
       WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 10;

   BACKUP LOG <DbName>
       TO DISK = N'C:\sqlbackups\<DbName>_LOG.trn'
       WITH COPY_ONLY, COMPRESSION, CHECKSUM;
   ```
3. Simular tráfico **posterior** al backup (= gap que el rollback debería perder):
   ```sql
   INSERT INTO dbo.DemoRows (Origin, Note)
   SELECT 'post-backup', CONCAT('row ', n)
   FROM (SELECT TOP 100 ROW_NUMBER() OVER (ORDER BY object_id) n FROM sys.objects) x;

   INSERT INTO dbo.RollbackAudit (EventType, EventDescription)
   VALUES ('POST_BACKUP_TRAFFIC', 'Inserts post-backup que se perderán al hacer rollback');
   ```

### Restore en una BD nueva (no rompe el live)

```sql
RESTORE DATABASE <DbName>_RestoreTest
    FROM DISK = N'C:\sqlbackups\<DbName>_FULL.bak'
    WITH NORECOVERY,
         MOVE N'<logical_data>' TO N'C:\sqlbackups\restore\<DbName>_RestoreTest.mdf',
         MOVE N'<logical_log>'  TO N'C:\sqlbackups\restore\<DbName>_RestoreTest_log.ldf',
         REPLACE;

RESTORE LOG <DbName>_RestoreTest
    FROM DISK = N'C:\sqlbackups\<DbName>_LOG.trn'
    WITH RECOVERY;
```

### Verificación de consistencia

```sql
-- Estado de la BD productiva (live, con todo el tráfico)
SELECT 'LIVE' AS Source, COUNT(*) AS rows_total FROM <DbName>.dbo.DemoRows
UNION ALL
-- Estado de la BD restaurada (solo hasta el backup)
SELECT 'RESTORED', COUNT(*) FROM <DbName>_RestoreTest.dbo.DemoRows;
```

**Resultado esperado**:
- `LIVE` = N filas iniciales + 100 post-backup.
- `RESTORED` = N filas iniciales (exactamente el estado del backup).
- Diferencia entre ambos = **RPO real del rollback** = transacciones posteriores
  al último LOG backup.

### Limpieza

```sql
DROP DATABASE <DbName>_RestoreTest;
```

### Mitigación del gap del LOG backup

El gap entre el último LOG backup y el cutover **se pierde** en un rollback Capa 1.
Para minimizarlo, programar un **tail-log backup** justo después de parar la app:

```sql
BACKUP LOG <DbName>
    TO DISK = N'C:\sqlbackups\<DbName>_TAIL.trn'
    WITH NO_TRUNCATE, NORECOVERY;
```

Y aplicarlo en el restore: `RESTORE LOG <DbName>_RestoreTest FROM DISK = '…TAIL.trn' WITH RECOVERY;`.

---

## Drill 2 — Capa 2 (Azure Backup VM)

### Setup

```powershell
az backup vault create -g <rg-vm> -n <vault-name> -l <region>

az backup protection enable-for-vm `
  -g <rg-vm> -v <vault-name> `
  --vm <vm-name> --policy-name DefaultPolicy

az backup protection backup-now `
  -g <rg-vm> -v <vault-name> `
  --container-name "IaasVMContainer;iaasvmcontainerv2;<rg-vm>;<vm-name>" `
  --item-name      "VM;iaasvmcontainerv2;<rg-vm>;<vm-name>" `
  --backup-management-type AzureIaasVM `
  --retain-until <dd-MM-yyyy>
```

### Monitorización del job

```powershell
$jobId = "<job-id-from-previous-command>"
az backup job show -g <rg-vm> -v <vault-name> -n $jobId `
  --query "{Status:properties.status, Tasks:properties.extendedInfo.tasksList}"
```

Fases del job:
1. `Take Snapshot` — congela los discos. **Al completar esta fase ya hay
   recovery point disponible.**
2. `Transfer data to vault` — copia a almacenamiento de larga retención.
3. `Validate Backup` — verifica integridad.

> Importante: el recovery point está **disponible para restore en cuanto la
> fase 1 termina**, mucho antes de que termine la transferencia al vault.

### Verificar tipo de consistencia

```powershell
az backup recoverypoint list `
  -g <rg-vm> -v <vault-name> `
  -c "IaasVMContainer;iaasvmcontainerv2;<rg-vm>;<vm-name>" `
  -i "VM;iaasvmcontainerv2;<rg-vm>;<vm-name>" `
  --backup-management-type AzureIaasVM -o table
```

Buscar `Consistency = AppConsistent`. Si aparece `CrashConsistent` es porque la
extensión `IaaSVMSnapshot` no está instalada o el VSS writer de SQL falló — hay
que investigar antes de confiar en este snapshot para SQL Server.

### Restore drill (sin destruir la VM original)

```powershell
az backup restore restore-disks `
  -g <rg-vm> -v <vault-name> `
  -c "IaasVMContainer;iaasvmcontainerv2;<rg-vm>;<vm-name>" `
  -i "VM;iaasvmcontainerv2;<rg-vm>;<vm-name>" `
  -r <recovery-point-id> `
  --storage-account <staging-storage-account>
```

Luego crear una VM nueva desde los discos restaurados, arrancar SQL Server y
verificar la BD.

---

## Drill 3 — Capa 3 (rollback inmediato post-cutover)

Este drill **no debe destruir** el entorno productivo en staging — se ejecuta
sobre una BD secundaria que simula el flujo.

### Procedimiento

1. En el SQL Server origen, dejar la BD en `READ_ONLY` (simulando el post-cutover):
   ```sql
   ALTER DATABASE <DbName> SET READ_ONLY WITH ROLLBACK IMMEDIATE;
   ```
2. Configurar auditing para detectar conexiones inesperadas:
   ```sql
   CREATE SERVER AUDIT [Post_Cutover_Audit]
       TO FILE (FILEPATH = N'C:\sqlbackups\audit\', MAXSIZE = 100 MB)
       WITH (ON_FAILURE = CONTINUE);
   ALTER SERVER AUDIT [Post_Cutover_Audit] WITH (STATE = ON);

   CREATE DATABASE AUDIT SPECIFICATION [DB_Connections]
       FOR SERVER AUDIT [Post_Cutover_Audit]
       ADD (DATABASE_PRINCIPAL_CHANGE_GROUP),
       ADD (SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP)
       WITH (STATE = ON);
   ```
3. Ejecutar el procedimiento de rollback:
   ```sql
   -- 1. Asegurarse de que la app está parada (stop signal verificado)
   -- 2. Volver la BD del origen a escribible
   ALTER DATABASE <DbName> SET READ_WRITE;

   -- 3. (Opcional) Bloquear MI para evitar dual-write durante el rollback
   --    En el MI:
   ALTER DATABASE <DbName> SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;
   ```
4. Cambiar el connection string de la app al SQL Server origen.
5. Smoke test contra el origen.

### Métricas a capturar en el drill

- Tiempo desde decisión de rollback hasta app operativa contra el origen.
- Errores observados durante el switch (timeouts de connection pool, transactions
  in-flight, etc.).
- Volumen de datos perdidos en el MI (queries de comparación pre/post si la app
  escribió).

---

## Drill 4 — Capa 4 (BACPAC late rollback)

### Procedimiento

1. **Freeze MI** en READ_ONLY:
   ```sql
   ALTER DATABASE <DbName> SET READ_ONLY;
   ```

2. **Export BACPAC** desde una máquina con `sqlpackage` instalado:
   ```powershell
   sqlpackage.exe `
     /a:Export `
     /tsn:"<mi-public-fqdn>,3342" `
     /tu:"<admin-upn>" `
     /tdn:<DbName> `
     /ua:true `
     /tf:"C:\rollback\<DbName>_export.bacpac"
   ```

3. **Import** en el SQL Server origen:
   ```powershell
   sqlpackage.exe `
     /a:Import `
     /sf:"C:\rollback\<DbName>_export.bacpac" `
     /tsn:<server> `
     /tu:sa /tp:"<sa-pwd>" `
     /tdn:<DbName>_recovered
   ```

4. **Switch over**:
   ```sql
   DROP DATABASE <DbName>;
   ALTER DATABASE <DbName>_recovered MODIFY NAME = <DbName>;
   ALTER DATABASE <DbName> SET READ_WRITE;
   ```

### Métricas a capturar

- Tamaño del BACPAC vs tamaño físico de la BD en MI.
- Si el export falla por features incompatibles → identificar y documentar
  cuáles (clave para evitar el uso de esas features durante la fase de validación
  post-cutover).
- Ventana de READ_ONLY en MI necesaria para garantizar consistencia transaccional.

---

## Validación de invariantes de seguridad

Aspectos que el drill debe verificar **siempre**, independientemente de qué
capa se pruebe:

### 1. `COPY_ONLY` no rompe la chain del Link

Después de un backup `COPY_ONLY`, el `differential_base_lsn` **no debe avanzar**:
```sql
SELECT name, differential_base_lsn, differential_base_time
FROM sys.master_files
WHERE database_id = DB_ID(N'<DbName>');
```

Y el AG/DAG debe seguir `SYNCHRONIZING HEALTHY`.

### 2. Compatibility level del MI no ha subido por accidente

```sql
SELECT name, compatibility_level FROM sys.databases WHERE name = N'<DbName>';
```

Si subió por un upgrade del MI engine, revisar políticas de auto-upgrade del MI
y la update policy elegida.

### 3. Soft-delete del Recovery Services Vault

```powershell
az backup vault backup-properties show -g <rg-vm> -n <vault-name> `
  --query "softDeleteFeatureState"
```

Si está `Disabled`, los recovery points se pueden borrar accidentalmente.
Algunos tenants imponen `Enabled` por policy y obligan a 14 días de retención
post-delete — tenerlo en cuenta para la limpieza del entorno.

### 4. Verificar que el restore reproduce los row counts esperados

```sql
DECLARE @live INT, @restored INT;

SELECT @live = COUNT(*) FROM <DbName>.dbo.DemoRows;
SELECT @restored = COUNT(*) FROM <DbName>_RestoreTest.dbo.DemoRows;

SELECT
    @live    AS live_rows,
    @restored AS restored_rows,
    @live - @restored AS rpo_rows_lost;
```

El valor `rpo_rows_lost` debe coincidir con el tráfico generado entre el backup
y el momento del restore.

---

## Checklist final del drill

Antes de declarar el plan de rollback listo para producción:

- [ ] Capa 1 verificada con restore en BD nueva + comparación de row counts.
- [ ] Capa 1: backup `COPY_ONLY` confirmado que no altera la chain del Link.
- [ ] Capa 2 verificada con recovery point `AppConsistent` listado en el vault.
- [ ] Capa 2: `restore-disks` probado a un staging storage account.
- [ ] Capa 3: procedimiento de switch de connection string practicado y cronometrado.
- [ ] Capa 3: auditing en SQL Server origen detecta conexiones de prueba.
- [ ] Capa 4: BACPAC del tamaño real exportado e importado correctamente.
- [ ] Capa 4: validado que no hay features incompatibles activadas en MI.
- [ ] Compatibility level del MI verificado igual al del origen.
- [ ] Soft-delete del vault configurado según política del tenant.
- [ ] Decision tree del rollback (qué capa usar cuándo) repasado por el equipo.
- [ ] Runbook publicado con comandos exactos y owners asignados.

---

## Gotchas conocidas

### `BACKUP TO URL` con user-delegation SAS puede fallar

En SQL Server 2017, `BACKUP TO URL` usando una user-delegation SAS puede devolver
`Operating system error 50 (The request is not supported.)` en algunas
configuraciones de storage account.

**Workarounds**:
- (a) Pedir exempt del policy `allowSharedKeyAccess=false` para el storage de backups.
- (b) Usar `BACKUP TO DISK` local + `AzCopy` con managed identity del SQL Server.
- (c) Storage account con private endpoint + AAD-based credential (requiere SQL 2022+).

### Soft-delete obligatorio en Recovery Services Vault

Algunos tenants imponen soft-delete habilitado vía policy. Síntoma al intentar
deshabilitarlo: `BMSUserErrorDisablingSoftDeleteStateNotAllowed`. Impacto:
retención forzada (típicamente 14 días) tras eliminar items del vault.

### Restore a BD nueva permite drill no-disruptivo

Siempre que sea posible, hacer el restore drill a una BD **nueva**
(`<DbName>_RestoreTest`) con `MOVE` + `REPLACE`. Esto permite verificar el backup
sin tocar la BD productiva.

### El gap del LOG backup es crítico

Cualquier transacción entre el último LOG backup y el momento del rollback se
pierde si no se programó un **tail-log backup** durante el corte de tráfico.
Documentar el tail-log backup como **paso obligatorio** del runbook del cutover
real.
