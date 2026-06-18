# =====================================================================
# 16-pre-cutover-vm-snapshot.ps1
# Toma un snapshot Azure Backup app-consistent de vm-sql2017 T-24h
# antes del cutover. Esto es la Capa 2 del plan de rollback.
#
# Pre-requisitos:
#   - Recovery Services Vault existe (asume el del modulo MI Link)
#   - VM vm-sql2017 esta registrada en el vault con un backup policy
#
# Si el vault no existe o la VM no esta registrada, crearlos primero:
#   ver scripts/07-enable-azure-backup-vm.ps1 del modulo MI Link
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/rollback-plan.md (§6)
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$VaultRg     = "rg-milink-vm",
    [string]$VaultName   = "rsv-milink",
    [string]$VmRg        = "rg-milink-vm",
    [string]$VmName      = "vm-sql2017",
    [int]$RetentionDays  = 30
)

$ErrorActionPreference = 'Stop'

# Usar Az PowerShell module (no Azure CLI para esto)
if (-not (Get-Module -ListAvailable -Name Az.RecoveryServices)) {
    Write-Host "Installing Az.RecoveryServices module..." -ForegroundColor Cyan
    Install-Module Az.RecoveryServices -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.RecoveryServices

Connect-AzAccount -Subscription $SubId | Out-Null

# Get vault context
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultRg -Name $VaultName -ErrorAction SilentlyContinue
if (-not $vault) {
    Write-Error "Vault $VaultName not found in $VaultRg. Crear primero (ver scripts/07-enable-azure-backup-vm.ps1 del modulo MI Link)."
    exit 1
}
Set-AzRecoveryServicesVaultContext -Vault $vault

# Verificar VM registrada
$container = Get-AzRecoveryServicesBackupContainer `
    -ContainerType AzureVM `
    -FriendlyName $VmName `
    -VaultId $vault.ID `
    -ErrorAction SilentlyContinue

if (-not $container) {
    Write-Host "VM $VmName no esta registrada en el vault. Registrando..." -ForegroundColor Cyan
    $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name "DefaultPolicy" -VaultId $vault.ID -ErrorAction SilentlyContinue
    if (-not $policy) {
        $policy = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $vault.ID | Where-Object { $_.WorkloadType -eq 'AzureVM' } | Select-Object -First 1
    }
    Enable-AzRecoveryServicesBackupProtection `
        -ResourceGroupName $VmRg `
        -Name $VmName `
        -Policy $policy `
        -VaultId $vault.ID

    Start-Sleep -Seconds 10
    $container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $VmName -VaultId $vault.ID
}

$bkpItem = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -VaultId $vault.ID

# Lanzar backup ad-hoc (app-consistent si VSS writer esta OK)
$expiryDate = (Get-Date).AddDays($RetentionDays).ToUniversalTime()
Write-Host "Lanzando backup on-demand de $VmName (retention $RetentionDays dias)..." -ForegroundColor Cyan

$backupJob = Backup-AzRecoveryServicesBackupItem `
    -Item $bkpItem `
    -ExpiryDateTimeUTC $expiryDate `
    -VaultId $vault.ID

Write-Host "Backup job: $($backupJob.JobId)" -ForegroundColor Yellow
Write-Host "Esperando a que termine (puede tardar 10-30 min)..." -ForegroundColor Cyan

# Wait for completion (con timeout de 1h)
$timeout = (Get-Date).AddHours(1)
while ((Get-Date) -lt $timeout) {
    $job = Get-AzRecoveryServicesBackupJob -Job $backupJob -VaultId $vault.ID
    if ($job.Status -in @('Completed', 'Failed', 'CompletedWithWarnings')) { break }
    Write-Host "  Estado: $($job.Status) ($([Math]::Round((Get-Date).Subtract($job.StartTime).TotalMinutes, 1)) min transcurridos)" -ForegroundColor Gray
    Start-Sleep -Seconds 60
}

$job = Get-AzRecoveryServicesBackupJob -Job $backupJob -VaultId $vault.ID
Write-Host ""
Write-Host "Backup job final status: $($job.Status)" -ForegroundColor $(if ($job.Status -eq 'Completed') { 'Green' } else { 'Red' })

if ($job.Status -eq 'Completed') {
    # Get the recovery point
    Start-Sleep -Seconds 30
    $rp = Get-AzRecoveryServicesBackupRecoveryPoint -Item $bkpItem -VaultId $vault.ID `
            -StartDate (Get-Date).AddHours(-2) -EndDate (Get-Date) | Select-Object -First 1
    Write-Host ""
    Write-Host "Recovery point creado:" -ForegroundColor Green
    Write-Host "  ID: $($rp.RecoveryPointId)"
    Write-Host "  Time: $($rp.RecoveryPointTime)"
    Write-Host "  Type: $($rp.RecoveryPointType)"
    Write-Host ""
    Write-Host "GUARDAR EL RECOVERY POINT ID arriba en el log del cutover."
    Write-Host "Para restore (Capa 2): ver scripts/modules/sql2017-to-sql2022/31-rollback-from-vm-snapshot.ps1"
}

Write-Host ""
Write-Host "========== 16-pre-cutover-vm-snapshot.ps1 COMPLETADO ==========" -ForegroundColor Green
