# =====================================================================
# 31-rollback-from-vm-snapshot.ps1
# CAPA 2 del rollback plan: restore desde Azure Backup VM snapshot.
#
# Aplica si la VM vm-sql2017 ya no existe o esta danyada, o necesitas
# recuperar tambien SO + SQL configs (no solo la BD).
#
# Pre-requisitos:
#   - Snapshot tomado en T-24h por script 16-pre-cutover-vm-snapshot.ps1
#   - Recovery Services Vault accesible
#
# Restaura la VM como NUEVA (sufijo -restored) — NO sobre la original.
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/rollback-plan.md (§6)
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$VaultRg               = "rg-milink-vm",
    [string]$VaultName             = "rsv-milink",
    [string]$VmName                = "vm-sql2017",
    [string]$RestoreRg             = "rg-milink-vm-restored",
    [string]$RestoreStorageRg      = "rg-milink-vm-restored",
    [string]$RestoreStorageAccount = "stmilinkrestore$(Get-Random -Maximum 9999)"
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Az.RecoveryServices)) {
    Install-Module Az.RecoveryServices -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.RecoveryServices

Connect-AzAccount -Subscription $SubId | Out-Null

# Vault context
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultRg -Name $VaultName
Set-AzRecoveryServicesVaultContext -Vault $vault

# RG y SA para restore
Write-Host "Creating restore RG/SA..." -ForegroundColor Cyan
New-AzResourceGroup -Name $RestoreRg -Location $vault.Location -Force | Out-Null
$sa = New-AzStorageAccount `
    -ResourceGroupName $RestoreStorageRg `
    -Name $RestoreStorageAccount `
    -Location $vault.Location `
    -SkuName Standard_LRS `
    -Kind StorageV2

# Get backup item
$container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $VmName -VaultId $vault.ID
$bkpItem = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -VaultId $vault.ID

# Listar recovery points disponibles
Write-Host "Recovery points disponibles:" -ForegroundColor Cyan
$rps = Get-AzRecoveryServicesBackupRecoveryPoint `
    -Item $bkpItem `
    -StartDate (Get-Date).AddDays(-7) `
    -EndDate (Get-Date) `
    -VaultId $vault.ID
$rps | Format-Table -Property RecoveryPointId, RecoveryPointTime, RecoveryPointType -AutoSize

# Seleccionar el mas reciente
$rp = $rps | Select-Object -First 1
Write-Host ""
Write-Host "Restoring from recovery point: $($rp.RecoveryPointTime)" -ForegroundColor Cyan

# Restore
$restoreJob = Restore-AzRecoveryServicesBackupItem `
    -RecoveryPoint $rp `
    -StorageAccountName $RestoreStorageAccount `
    -StorageAccountResourceGroupName $RestoreStorageRg `
    -TargetResourceGroupName $RestoreRg `
    -VaultId $vault.ID

Write-Host "Restore job: $($restoreJob.JobId)" -ForegroundColor Yellow
Write-Host "Esperando a que termine (puede tardar 30-120 min)..." -ForegroundColor Cyan

$timeout = (Get-Date).AddHours(3)
while ((Get-Date) -lt $timeout) {
    $job = Get-AzRecoveryServicesBackupJob -Job $restoreJob -VaultId $vault.ID
    if ($job.Status -in @('Completed', 'Failed', 'CompletedWithWarnings')) { break }
    Write-Host "  Estado: $($job.Status) ($([Math]::Round((Get-Date).Subtract($job.StartTime).TotalMinutes, 1)) min)" -ForegroundColor Gray
    Start-Sleep -Seconds 60
}

$job = Get-AzRecoveryServicesBackupJob -Job $restoreJob -VaultId $vault.ID
Write-Host ""
Write-Host "Restore status final: $($job.Status)"

if ($job.Status -eq 'Completed') {
    Write-Host ""
    Write-Host "========== RESTORE OK ==========" -ForegroundColor Green
    Write-Host "Discos restaurados en SA $RestoreStorageAccount."
    Write-Host ""
    Write-Host "Pasos manuales pendientes:"
    Write-Host "  1. Crear VM nueva en RG $RestoreRg desde los VHDs restaurados."
    Write-Host "  2. Conectar a la VM y sacar BD legacy del AG (estaba en RESTORING):"
    Write-Host "     ALTER AVAILABILITY GROUP [AG_NorthEU] REMOVE DATABASE [AppDb];"
    Write-Host "     RESTORE DATABASE [AppDb] WITH RECOVERY;"
    Write-Host "     ALTER DATABASE [AppDb] SET MULTI_USER;"
    Write-Host "  3. Crear DNS record o nueva IP/FQDN para que la app pueda conectarse."
    Write-Host "  4. App repoint a la VM restaurada."
    Write-Host ""
    Write-Host "PERDIDA: tx desde el snapshot (T-24h) hasta el rollback."
    Write-Host "RTO: ~60-120 min (mas pasos manuales arriba)."
} else {
    Write-Host "Restore FAILED. Investigar manualmente." -ForegroundColor Red
    Write-Host $job.ErrorDetails
}
