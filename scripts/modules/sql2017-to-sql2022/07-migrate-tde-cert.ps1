# =====================================================================
# 07-migrate-tde-cert.ps1
# Migra el certificado de TDE desde vm-sql2017 a vm-sql2022.
# Necesario SOLO si la BD a migrar tiene TDE habilitado.
#
# Sin esto, el restore o el seeding manual fallaria con:
#   "Cannot find server certificate with thumbprint <X>"
#
# Pre-requisitos:
#   - 05-prepare-sql2022.sql ya ejecutado (master key + cert endpoint creados)
#   - SQL Server 2017 en NorthEU tiene cert TDE creado y la BD encriptada
#
# Lo que hace:
#   1. Backup del Service Master Key en NorthEU + descarga
#   2. Backup del TDE cert (con private key) en NorthEU + descarga
#   3. Restore del SMK en SpainC
#   4. Create cert en SpainC desde el .cer + .pvk
#
# ATENCION: el password se usa para encriptar el cert/pvk en transito.
#           No es el password de la BD ni del cert. Usa uno fuerte y guardalo.
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/out-of-band-objects.md (§6)
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$RgNE          = "rg-milink-vm",
    [string]$VmNE          = "vm-sql2017",
    [string]$RgSC          = "rg-mig-spainc",
    [string]$VmSC          = "vm-sql2022",
    [Parameter(Mandatory)] [string]$TdeCertName,           # ej: 'TDECert'
    [Parameter(Mandatory)] [string]$ExportPwd,             # password temporal para .pvk
    [Parameter(Mandatory)] [string]$NewMasterKeyPwd,       # password del master key del 2022
    [string]$WorkDir       = ".\.migration-secrets\tde"
)

$ErrorActionPreference = 'Stop'

az account set --subscription $SubId

New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null

# ===== Helper inline =====
function Invoke-SqlInVm {
    param([string]$Rg, [string]$Vm, [string]$Sql)
    $sqlEscaped = $Sql -replace '"', '\"'
    $script = "sqlcmd -S . -E -Q `"$sqlEscaped`""
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    $script | Out-File $tmp -Encoding UTF8
    $r = az vm run-command invoke -g $Rg -n $Vm --command-id RunPowerShellScript --scripts "@$tmp" --query "value[0].message" -o tsv
    Remove-Item $tmp
    return $r
}

function Get-FileFromVm {
    param([string]$Rg, [string]$Vm, [string]$RemotePath, [string]$LocalPath)
    $script = "`$bytes = [System.IO.File]::ReadAllBytes('$RemotePath'); [System.Convert]::ToBase64String(`$bytes)"
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    $script | Out-File $tmp -Encoding UTF8
    $b64 = az vm run-command invoke -g $Rg -n $Vm --command-id RunPowerShellScript --scripts "@$tmp" --query "value[0].message" -o tsv
    Remove-Item $tmp
    $b64Clean = ($b64 -split '\r?\n' | Where-Object { $_ -match '^[A-Za-z0-9+/=]+$' -and $_.Length -gt 100 } | Select-Object -First 1)
    [System.IO.File]::WriteAllBytes($LocalPath, [Convert]::FromBase64String($b64Clean))
}

function Send-FileToVm {
    param([string]$Rg, [string]$Vm, [string]$LocalPath, [string]$RemotePath)
    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $b64 = [Convert]::ToBase64String($bytes)
    $script = @"
`$dir = Split-Path -Path '$RemotePath' -Parent
if (-not (Test-Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
[System.IO.File]::WriteAllBytes('$RemotePath', [Convert]::FromBase64String('$b64'))
"@
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    $script | Out-File $tmp -Encoding UTF8
    az vm run-command invoke -g $Rg -n $Vm --command-id RunPowerShellScript --scripts "@$tmp" -o none
    Remove-Item $tmp
}

# ===== 1. En NorthEU: backup SMK + cert TDE =====
Write-Host "===== NorthEU: backup SMK + cert TDE =====" -ForegroundColor Yellow

$sqlNE = @"
USE master;
BACKUP SERVICE MASTER KEY TO FILE = 'C:\certs\smk.bak' ENCRYPTION BY PASSWORD = '$ExportPwd';
BACKUP CERTIFICATE [$TdeCertName] TO FILE = 'C:\certs\$TdeCertName.cer' WITH PRIVATE KEY (FILE = 'C:\certs\$TdeCertName.pvk', ENCRYPTION BY PASSWORD = '$ExportPwd');
SELECT 'NorthEU: SMK + cert TDE backed up' AS status;
"@
$resNE = Invoke-SqlInVm -Rg $RgNE -Vm $VmNE -Sql $sqlNE
Write-Host $resNE

# ===== 2. Descargar los 3 ficheros =====
Write-Host "===== Descargando SMK + cert TDE =====" -ForegroundColor Yellow
Get-FileFromVm -Rg $RgNE -Vm $VmNE -RemotePath "C:\certs\smk.bak" -LocalPath "$WorkDir\smk.bak"
Get-FileFromVm -Rg $RgNE -Vm $VmNE -RemotePath "C:\certs\$TdeCertName.cer" -LocalPath "$WorkDir\$TdeCertName.cer"
Get-FileFromVm -Rg $RgNE -Vm $VmNE -RemotePath "C:\certs\$TdeCertName.pvk" -LocalPath "$WorkDir\$TdeCertName.pvk"

# ===== 3. Subir los 3 ficheros a SpainC =====
Write-Host "===== Subiendo a SpainC =====" -ForegroundColor Yellow
Send-FileToVm -Rg $RgSC -Vm $VmSC -LocalPath "$WorkDir\smk.bak" -RemotePath "C:\certs\smk.bak"
Send-FileToVm -Rg $RgSC -Vm $VmSC -LocalPath "$WorkDir\$TdeCertName.cer" -RemotePath "C:\certs\$TdeCertName.cer"
Send-FileToVm -Rg $RgSC -Vm $VmSC -LocalPath "$WorkDir\$TdeCertName.pvk" -RemotePath "C:\certs\$TdeCertName.pvk"

# ===== 4. En SpainC: restore SMK + crear cert TDE =====
Write-Host "===== SpainC: restore SMK + crear cert TDE =====" -ForegroundColor Yellow

$sqlSC = @"
USE master;
-- Restore SMK (opcional pero recomendado)
RESTORE SERVICE MASTER KEY FROM FILE = 'C:\certs\smk.bak' DECRYPTION BY PASSWORD = '$ExportPwd' FORCE;

-- Master key (si no existe — debe existir del 05-prepare)
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$NewMasterKeyPwd';

-- Cert TDE desde los ficheros
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '$TdeCertName')
    CREATE CERTIFICATE [$TdeCertName] FROM FILE = 'C:\certs\$TdeCertName.cer'
        WITH PRIVATE KEY (FILE = 'C:\certs\$TdeCertName.pvk', DECRYPTION BY PASSWORD = '$ExportPwd');

SELECT 'SpainC: cert TDE imported' AS status;
SELECT name, thumbprint, pvt_key_encryption_type_desc FROM sys.certificates WHERE name = '$TdeCertName';
"@
$resSC = Invoke-SqlInVm -Rg $RgSC -Vm $VmSC -Sql $sqlSC
Write-Host $resSC

Write-Host ""
Write-Host "========== TDE cert migration DONE ==========" -ForegroundColor Green
Write-Host "Ahora vm-sql2022 puede abrir BDs encriptadas con $TdeCertName"
Write-Host ""
Write-Host "ATENCION: los ficheros en $WorkDir contienen claves privadas." -ForegroundColor Yellow
Write-Host "Guardar en lugar seguro y BORRAR de las VMs cuando termine la migracion:" -ForegroundColor Yellow
Write-Host "  Remove-Item C:\certs\smk.bak"
Write-Host "  Remove-Item C:\certs\$TdeCertName.pvk"
Write-Host ""
Write-Host "Siguiente paso: scripts/modules/sql2017-to-sql2022/08-backup-for-seeding.sql"
