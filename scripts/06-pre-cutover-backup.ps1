<#
.SYNOPSIS
  Ejecuta el backup pre-cutover (FULL + LOG) a Azure Blob desde la VM SQL Server.
.DESCRIPTION
  - Refresca el SAS user-delegation (válido sólo 7 días)
  - Inyecta sustituciones en 05-pre-cutover-backup.sql
  - Ejecuta vía az vm run-command sobre la VM
  - Lista los blobs resultantes para confirmación
.PARAMETER ResourceGroup
  RG de la VM
.PARAMETER VmName
  Nombre de la VM
.PARAMETER StorageAccount
  Storage account de destino
.PARAMETER Container
  Container de destino
.PARAMETER SqlSaPassword
  Pwd del login 'sa' (o cualquier login con BACKUP permissions)
.NOTES
  En tenants con `allowSharedKeyAccess=false` por policy, el flujo SAS falla.
  Usar `BACKUP TO DISK` + AzCopy con managed identity como alternativa.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$VmName,
    [Parameter(Mandatory)] [string]$StorageAccount,
    [string]$Container      = 'sqlbackups',
    [Parameter(Mandatory)]  [string]$SqlSaPassword
)

$ErrorActionPreference = 'Stop'

Write-Host "[1/4] Generando user-delegation SAS..." -ForegroundColor Cyan
$exp = (Get-Date).AddDays(7).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$sas = az storage container generate-sas `
    -n $Container `
    --account-name $StorageAccount `
    --as-user --auth-mode login `
    --permissions rwdl `
    --expiry $exp `
    --https-only -o tsv
if (-not $sas) { throw "No se pudo generar SAS" }
Write-Host "  SAS expira: $exp" -ForegroundColor Green

Write-Host "[2/4] Construyendo script SQL con SAS inyectado..." -ForegroundColor Cyan
$sqlTemplate = Get-Content "$PSScriptRoot\05-pre-cutover-backup.sql" -Raw
$sql = $sqlTemplate `
    -replace '<storage_account>', $StorageAccount `
    -replace '<container>',       $Container `
    -replace '<sas_token>',       $sas
$sqlPath = "$env:TEMP\pre-cutover-backup-resolved.sql"
$sql | Out-File $sqlPath -Encoding ASCII

Write-Host "[3/4] Ejecutando backup en la VM via az vm run-command..." -ForegroundColor Cyan
$psScript = @"
`$sqlPath = 'C:\Windows\Temp\pre-cutover-backup.sql'
@'
$sql
'@ | Out-File `$sqlPath -Encoding ASCII
sqlcmd -S localhost -U sa -P '$SqlSaPassword' -i `$sqlPath
"@
$tmpPath = "$env:TEMP\run-backup.ps1"
$psScript | Out-File $tmpPath -Encoding UTF8

$result = az vm run-command invoke `
    -g $ResourceGroup -n $VmName `
    --command-id RunPowerShellScript `
    --scripts "@$tmpPath" -o json | ConvertFrom-Json
$result.value | ForEach-Object {
    Write-Host "[$($_.code)]" -ForegroundColor Yellow
    Write-Host $_.message
}

Write-Host "[4/4] Listando blobs del container..." -ForegroundColor Cyan
az storage blob list --container-name $Container --account-name $StorageAccount --auth-mode login `
    --query "[].{name:name, sizeMB:to_number(properties.contentLength), modified:properties.lastModified}" `
    -o table

Write-Host "`n✅ Backup pre-cutover completado." -ForegroundColor Green
Write-Host "Restore URL para rollback:" -ForegroundColor Yellow
Write-Host "  https://$StorageAccount.blob.core.windows.net/$Container/<filename>" -ForegroundColor Yellow
