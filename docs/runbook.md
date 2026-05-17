# Runbook: levantar la demo de cero

Tiempo estimado total: ~5-6 horas (la MI tarda 4-6h en aprovisionarse).

## 0. Prerrequisitos
- Azure CLI 2.60+ y GitHub CLI 2.40+ instalados.
- `az login` y `az account set --subscription "<id>"` apuntando a una sub donde tengas Owner.
- Providers registrados: `Microsoft.Sql`, `Microsoft.Network`, `Microsoft.Compute`.
- Un usuario o grupo AAD para ser administrador de la MI (si tu tenant aplica AAD-only policy).
- SSMS 19.x (o Azure Data Studio) en tu PC para el wizard de MI Link.

## 1. Provisionar la infraestructura Azure (~15 min, MI sigue al fondo)
```powershell
.\scripts\01-infra.ps1 `
  -SubId "<sub-id>" `
  -VmAdminPwd "<pwd-fuerte>" `
  -MiAadAdminUpn "tu-usuario@tu-tenant.onmicrosoft.com" `
  -MiAadAdminObjId "<aad-objectid>"
```
Esto deja la VM lista en ~10 min y la MI provisioning durante ~4-6h.

Verifica el estado:
```powershell
az sql mi show -g rg-sqlmilink-mi-esp -n mi-link-demo-fraesp --query state -o tsv
```

## 2. Conectar a la VM
- Public IP: `az vm show -g rg-sqlmilink-vm-fra -n vm-sql2017 -d --query publicIps -o tsv`
- RDP con `azureuser` / la pwd que pasaste.
- O usa `az vm run-command invoke` para ejecutar scripts sin RDP.

## 3. Habilitar Always On AG en SQL Server (~2 min)
Desde la VM (RDP) o usando `az vm run-command`:
```powershell
.\00-enable-alwayson.ps1
```
Esto activa la feature y reinicia el servicio `MSSQLSERVER`.

## 4. Instalar SQL Server 2017 CU31 (~30 min)
```powershell
.\install-sql2017-cu31.ps1
```
Requisito para MI Link (CU20+). La imagen del Marketplace trae CU17 por defecto.

## 5. Preparar SQL Server: TF, master key, cert, endpoint (~2 min)
Edita las variables si lo deseas y ejecuta en SSMS o `sqlcmd`:
```sql
:setvar MasterKeyPwd "TuPwdMaster!2024"
:r scripts\01-prepare-sql.sql
```
Verifica que existe el endpoint `Hadr_endpoint` en 5022 y que `C:\MILink\MILinkCert.cer` se exportó.

## 6. Crear la base de datos demo (~1 min)
```sql
:r scripts\02-restore-sample-db.sql
```
Quedará `DemoLink` en FULL recovery con un FULL + LOG backup.

## 7. Esperar a que la MI termine (~4-6h)
Monitorea:
```powershell
az sql mi show -g rg-sqlmilink-mi-esp -n mi-link-demo-fraesp --query state -o tsv
# Estados: Creating -> ... -> Ready
```

## 8. Configurar el MI Link
**Opción A (recomendada) - wizard de SSMS 19+:**
1. Abre SSMS, conecta al SQL Server (VM).
2. Click derecho sobre la BD `DemoLink` → **Tasks → Azure SQL Managed Instance link → New…**
3. Sigue el wizard:
   - Subir el cert de la MI a SQL Server y viceversa (el wizard lo hace).
   - Elige `mi-link-demo-fraesp` como destino.
   - Confirma puertos y conectividad.
4. Espera ~5-15 min al primer "synchronized".

**Opción B - T-SQL manual:**
1. Importa en SQL Server el cert público de la MI (descargado via `Get-AzSqlInstanceServerTrustCertificate` o portal).
2. Importa en la MI el cert público de SQL Server (`MILinkCert.cer`) con `EXEC sys.sp_set_instance_server_trust_certificate`.
3. Ejecuta `scripts\03-mi-link-setup.sql` con las variables `LocalServerName`, `MIName`, `MIDnsZone` correctas.

## 9. Validar replicación
En SQL Server (VM):
```sql
SELECT ar.replica_server_name, drs.synchronization_state_desc, drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id;
```
Inserta una fila en la VM:
```sql
USE DemoLink;
INSERT INTO dbo.DemoRows (Origin, Note) VALUES ('VM-after-link', 'Should appear on MI');
```
Conéctate a la MI desde SSMS (endpoint público o con jumpbox) y verifica que la fila está.

## 10. Cutover (opcional, demo final)
```sql
:r scripts\04-cutover.sql
```
- Tras esto, la BD en MI queda como primaria standalone.
- En SQL 2017 NO hay vuelta atrás gestionada. Para volver, hay que repetir el setup en sentido inverso (no soportado en 2017) o restaurar backup.

## 11. Limpieza
```powershell
.\scripts\cleanup.ps1
```
Borra ambos RGs y para el coste.
