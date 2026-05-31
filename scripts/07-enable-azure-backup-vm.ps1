<#
.SYNOPSIS
  Habilita Azure Backup (Recovery Services Vault) para la VM SQL Server
  y dispara un on-demand snapshot application-consistent.
.DESCRIPTION
  - Crea (o reutiliza) un Recovery Services Vault en la misma región que la VM
  - Aplica una policy "DefaultPolicy" 
  - Protege la VM
  - Dispara un backup on-demand (snapshot consistente vía VSS)
  - Espera a que el job complete y muestra el RecoveryPointId
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$VmName,
    [Parameter(Mandatory)] [string]$VaultName,
    [Parameter(Mandatory)] [string]$Location,
    [string]$PolicyName    = 'DefaultPolicy'
)

$ErrorActionPreference = 'Stop'

# Verifica módulo Az.RecoveryServices instalado
$mod = Get-Module -ListAvailable -Name Az.RecoveryServices | Select-Object -First 1
if (-not $mod) {
    Write-Host "Instalando módulo Az.RecoveryServices..." -ForegroundColor Yellow
    Install-Module -Name Az.RecoveryServices -Force -AllowClobber -Scope CurrentUser
}
Import-Module Az.RecoveryServices

Write-Host "[1/5] Asegurando RG y Vault..." -ForegroundColor Cyan
az group create -n $ResourceGroup -l $Location -o none

$vaultExists = az backup vault show -g $ResourceGroup -n $VaultName --query "name" -o tsv 2>$null
if (-not $vaultExists) {
    Write-Host "  Creando vault $VaultName..." -ForegroundColor Yellow
    az backup vault create -g $ResourceGroup -n $VaultName -l $Location -o none
} else {
    Write-Host "  Vault ya existe ✅" -ForegroundColor Green
}

# Intentar deshabilitar soft-delete para limpieza posterior.
# En tenants con policy "soft-delete obligatorio" este comando falla con
# BMSUserErrorDisablingSoftDeleteStateNotAllowed — es esperado.
az backup vault backup-properties set -g $ResourceGroup -n $VaultName --soft-delete-feature-state Disable -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Soft-delete no se puede deshabilitar (probable policy del tenant). Continuando." -ForegroundColor Yellow
}

Write-Host "[2/5] Habilitando protección para $VmName..." -ForegroundColor Cyan
$protected = az backup item list -g $ResourceGroup -v $VaultName --backup-management-type AzureIaasVM `
    --query "[?contains(properties.friendlyName, '$VmName')].name" -o tsv 2>$null
if (-not $protected) {
    az backup protection enable-for-vm `
        -g $ResourceGroup -v $VaultName --vm $VmName --policy-name $PolicyName -o none
    Write-Host "  Protección habilitada. Esperando propagación..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
} else {
    Write-Host "  Ya estaba protegida ✅" -ForegroundColor Green
}

Write-Host "[3/5] Disparando on-demand backup (application-consistent)..." -ForegroundColor Cyan
$expiry = (Get-Date).AddDays(30).ToString("dd-MM-yyyy")
$container = az backup container show -g $ResourceGroup -v $VaultName --backup-management-type AzureIaasVM `
    --container-name "iaasvmcontainerv2;$ResourceGroup;$VmName" --query "name" -o tsv
$item = az backup item show -g $ResourceGroup -v $VaultName --backup-management-type AzureIaasVM --workload-type VM `
    --container-name "iaasvmcontainerv2;$ResourceGroup;$VmName" --name "vm;iaasvmcontainerv2;$ResourceGroup;$VmName" --query "name" -o tsv

$jobJson = az backup protection backup-now `
    -g $ResourceGroup -v $VaultName `
    --container-name "iaasvmcontainerv2;$ResourceGroup;$VmName" `
    --item-name "vm;iaasvmcontainerv2;$ResourceGroup;$VmName" `
    --backup-management-type AzureIaasVM `
    --retain-until $expiry -o json
$jobId = ($jobJson | ConvertFrom-Json).name
Write-Host "  Job ID: $jobId" -ForegroundColor Green

Write-Host "[4/5] Esperando a que el snapshot complete..." -ForegroundColor Cyan
$start = Get-Date
do {
    Start-Sleep -Seconds 30
    $job = az backup job show -g $ResourceGroup -v $VaultName -n $jobId -o json | ConvertFrom-Json
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    Write-Host "  [${elapsed}s] Status: $($job.properties.status) - $($job.properties.operation) - subtasks: $($job.properties.extendedInfo.tasksList.Count)"
} while ($job.properties.status -in @('InProgress', 'Cancelling', 'Started'))

if ($job.properties.status -ne 'Completed') {
    Write-Warning "Job terminó con estado: $($job.properties.status)"
    $job | ConvertTo-Json -Depth 10 | Out-Host
    exit 1
}

Write-Host "[5/5] Listando recovery points..." -ForegroundColor Cyan
$points = az backup recoverypoint list -g $ResourceGroup -v $VaultName `
    --container-name "iaasvmcontainerv2;$ResourceGroup;$VmName" `
    --item-name "vm;iaasvmcontainerv2;$ResourceGroup;$VmName" `
    --backup-management-type AzureIaasVM `
    --query "[].{name:name, time:properties.recoveryPointTime, type:properties.recoveryPointType}" -o json | ConvertFrom-Json

$points | Format-Table -AutoSize

Write-Host "`n✅ VM backup completado." -ForegroundColor Green
Write-Host "Para restore usa:" -ForegroundColor Yellow
Write-Host "  az backup restore restore-disks --rp-name <recoveryPointName> ..." -ForegroundColor Yellow
