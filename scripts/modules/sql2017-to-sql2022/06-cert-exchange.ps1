# =====================================================================
# 06-cert-exchange.ps1
# Intercambio bidireccional de certificados entre vm-sql2017 (NorthEU)
# y vm-sql2022 (SpainC) para autenticar el endpoint Hadr_endpoint (TCP 5022)
# del Distributed AG.
#
# Pre-requisitos:
#   - vm-sql2017 ya tiene cert NorthEUCert exportado a C:\certs\NorthEUCert.cer
#     (creado por el modulo MI Link existente o por 05-prepare-sql2017.sql)
#   - vm-sql2022 ya tiene cert SpainCCert exportado a C:\certs\SpainCCert.cer
#     (creado por 05-prepare-sql2022.sql)
#
# Lo que hace:
#   1. Descarga los .cer de ambas VMs a la maquina del operador
#   2. Sube cada .cer a la VM opuesta
#   3. Genera T-SQL para crear el login + cert + GRANT CONNECT en cada lado
#   4. Ejecuta el T-SQL en cada VM via az vm run-command
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/architecture.md (§5)
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$RgNE          = "rg-milink-vm",
    [string]$VmNE          = "vm-sql2017",
    [string]$CertNE        = "NorthEUCert",
    [string]$RgSC          = "rg-mig-spainc",
    [string]$VmSC          = "vm-sql2022",
    [string]$CertSC        = "SpainCCert",
    [string]$WorkDir       = ".\.migration-secrets\certs"
)

$ErrorActionPreference = 'Stop'

az account set --subscription $SubId

New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null

# ===== Helper: download file from VM =====
function Get-FileFromVm {
    param(
        [string]$Rg, [string]$Vm, [string]$RemotePath, [string]$LocalPath
    )
    Write-Host "Downloading $RemotePath from $Vm..." -ForegroundColor Cyan
    $script = @"
`$bytes = [System.IO.File]::ReadAllBytes('$RemotePath')
[System.Convert]::ToBase64String(`$bytes)
"@
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    $script | Out-File $tmp -Encoding UTF8
    $b64 = az vm run-command invoke -g $Rg -n $Vm `
        --command-id RunPowerShellScript --scripts "@$tmp" `
        --query "value[0].message" -o tsv
    Remove-Item $tmp
    # El output tiene "Std Out:\n<base64>\n\nStd Err:\n..." - extraer base64
    $b64Clean = ($b64 -split '\r?\n' | Where-Object { $_ -match '^[A-Za-z0-9+/=]+$' -and $_.Length -gt 100 } | Select-Object -First 1)
    if (-not $b64Clean) {
        Write-Error "Could not extract base64 from VM output for $RemotePath"
        Write-Error "Raw output: $b64"
        exit 1
    }
    [System.IO.File]::WriteAllBytes($LocalPath, [Convert]::FromBase64String($b64Clean))
    Write-Host "  Saved to $LocalPath ($(Get-Item $LocalPath | Select-Object -ExpandProperty Length) bytes)" -ForegroundColor Green
}

# ===== Helper: upload file to VM =====
function Send-FileToVm {
    param(
        [string]$Rg, [string]$Vm, [string]$LocalPath, [string]$RemotePath
    )
    Write-Host "Uploading $LocalPath to $Vm`:$RemotePath..." -ForegroundColor Cyan
    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $b64 = [Convert]::ToBase64String($bytes)
    $script = @"
`$dir = Split-Path -Path '$RemotePath' -Parent
if (-not (Test-Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
[System.IO.File]::WriteAllBytes('$RemotePath', [Convert]::FromBase64String('$b64'))
Write-Host "Written `$((Get-Item '$RemotePath').Length) bytes to $RemotePath"
"@
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    $script | Out-File $tmp -Encoding UTF8
    az vm run-command invoke -g $Rg -n $Vm `
        --command-id RunPowerShellScript --scripts "@$tmp" -o none
    Remove-Item $tmp
}

# ===== Helper: run T-SQL in VM via sqlcmd =====
function Invoke-SqlInVm {
    param(
        [string]$Rg, [string]$Vm, [string]$Sql
    )
    $sqlEscaped = $Sql -replace '"', '\"'
    $script = @"
sqlcmd -S . -E -Q "$sqlEscaped"
"@
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    $script | Out-File $tmp -Encoding UTF8
    $result = az vm run-command invoke -g $Rg -n $Vm `
        --command-id RunPowerShellScript --scripts "@$tmp" `
        --query "value[0].message" -o tsv
    Remove-Item $tmp
    return $result
}

# ===== 1. Download certs =====
$certNELocal = Join-Path $WorkDir "$CertNE.cer"
$certSCLocal = Join-Path $WorkDir "$CertSC.cer"

Get-FileFromVm -Rg $RgNE -Vm $VmNE -RemotePath "C:\certs\$CertNE.cer" -LocalPath $certNELocal
Get-FileFromVm -Rg $RgSC -Vm $VmSC -RemotePath "C:\certs\$CertSC.cer" -LocalPath $certSCLocal

# ===== 2. Upload cross =====
Send-FileToVm -Rg $RgNE -Vm $VmNE -LocalPath $certSCLocal -RemotePath "C:\certs\$CertSC.cer"
Send-FileToVm -Rg $RgSC -Vm $VmSC -LocalPath $certNELocal -RemotePath "C:\certs\$CertNE.cer"

# ===== 3. Create login + user + cert + GRANT en cada lado =====
$pwdThrowaway = "Trash-Pwd-OnlyForLogin!1234"

# En NorthEU: importar cert de SpainC, crear login mapeado
$sqlNE = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'spainc_login')
    CREATE LOGIN spainc_login WITH PASSWORD = '$pwdThrowaway';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'spainc_user')
    CREATE USER spainc_user FOR LOGIN spainc_login;
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '$CertSC')
    CREATE CERTIFICATE [$CertSC] AUTHORIZATION spainc_user FROM FILE = 'C:\certs\$CertSC.cer';
GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO spainc_login;
SELECT 'NorthEU - imported $CertSC' AS status;
"@

Write-Host ""
Write-Host "===== Configurando NorthEU (importar $CertSC) =====" -ForegroundColor Yellow
$resNE = Invoke-SqlInVm -Rg $RgNE -Vm $VmNE -Sql $sqlNE
Write-Host $resNE

# En SpainC: importar cert de NorthEU, crear login mapeado
$sqlSC = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'northeu_login')
    CREATE LOGIN northeu_login WITH PASSWORD = '$pwdThrowaway';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'northeu_user')
    CREATE USER northeu_user FOR LOGIN northeu_login;
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '$CertNE')
    CREATE CERTIFICATE [$CertNE] AUTHORIZATION northeu_user FROM FILE = 'C:\certs\$CertNE.cer';
GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO northeu_login;
SELECT 'SpainC - imported $CertNE' AS status;
"@

Write-Host ""
Write-Host "===== Configurando SpainC (importar $CertNE) =====" -ForegroundColor Yellow
$resSC = Invoke-SqlInVm -Rg $RgSC -Vm $VmSC -Sql $sqlSC
Write-Host $resSC

# ===== 4. Verificacion: conexion TCP 5022 desde cada lado =====
Write-Host ""
Write-Host "===== Verificacion final =====" -ForegroundColor Yellow

$ipNE = az vm show -g $RgNE -n $VmNE -d --query privateIps -o tsv
$ipSC = az vm show -g $RgSC -n $VmSC -d --query privateIps -o tsv

$testFromNE = @"
`$r = Test-NetConnection -ComputerName $ipSC -Port 5022 -InformationLevel Quiet -WarningAction SilentlyContinue
Write-Host "NorthEU -> SpainC:5022 = `$r"
"@
$testFromSC = @"
`$r = Test-NetConnection -ComputerName $ipNE -Port 5022 -InformationLevel Quiet -WarningAction SilentlyContinue
Write-Host "SpainC -> NorthEU:5022 = `$r"
"@

$tmp1 = [System.IO.Path]::GetTempFileName() + ".ps1"
$testFromNE | Out-File $tmp1 -Encoding UTF8
$r1 = az vm run-command invoke -g $RgNE -n $VmNE --command-id RunPowerShellScript --scripts "@$tmp1" --query "value[0].message" -o tsv
Remove-Item $tmp1
Write-Host $r1

$tmp2 = [System.IO.Path]::GetTempFileName() + ".ps1"
$testFromSC | Out-File $tmp2 -Encoding UTF8
$r2 = az vm run-command invoke -g $RgSC -n $VmSC --command-id RunPowerShellScript --scripts "@$tmp2" --query "value[0].message" -o tsv
Remove-Item $tmp2
Write-Host $r2

Write-Host ""
Write-Host "========== Cert exchange DONE ==========" -ForegroundColor Green
Write-Host "Certs intercambiados:"
Write-Host "  NorthEU tiene: $CertNE (local) + $CertSC (importado)"
Write-Host "  SpainC  tiene: $CertSC (local) + $CertNE (importado)"
Write-Host ""
Write-Host "ATENCION: el directorio $WorkDir contiene los .cer publicos." -ForegroundColor Yellow
Write-Host "Estos NO son secretos en si (solo cert publico), pero tampoco commitearlos." -ForegroundColor Yellow
Write-Host ""
Write-Host "Siguiente paso: si la BD usa TDE, ejecutar 07-migrate-tde-cert.ps1"
Write-Host "                si no, saltar a 08-backup-for-seeding.sql"
