# =====================================================================
# cleanup-spainc.ps1
# Cleanup del entorno de SpainC. Borra TODO lo creado por este modulo
# en Spain Central. NO toca NorthEU.
#
# USE WITH EXTREME CARE. Esto destruye datos.
#
# Pre-requisitos:
#   - Cutover completado y estable
#   - Estrategia post-cutover A (decommission) ya ejecutada o aplicada
#   - Backups Capa 1 (cutover-backups) conservados aparte si quieres
#
# Flags:
#   -KeepStorage : conservar el Storage Account con los backups
#   -DryRun      : no borrar, solo listar
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$RgSC      = "rg-mig-spainc",
    [switch]$KeepStorage,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

az account set --subscription $SubId

Write-Host "===== CLEANUP SpainC =====" -ForegroundColor Yellow
Write-Host "RG: $RgSC" -ForegroundColor Yellow
Write-Host ""

# Listar recursos
Write-Host "Recursos en $RgSC:" -ForegroundColor Cyan
$resources = az resource list -g $RgSC --query "[].{name:name, type:type, location:location}" | ConvertFrom-Json
$resources | Format-Table -AutoSize

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN — no se borra nada." -ForegroundColor Green
    exit 0
}

# Confirmacion explicita
Write-Host ""
Write-Host "ATENCION: esta operacion BORRA todos los recursos arriba." -ForegroundColor Red
Write-Host "  - $($resources.Count) recursos"
if ($KeepStorage) {
    $sas = $resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' }
    Write-Host "  - Se PRESERVAN $($sas.Count) Storage Accounts (--KeepStorage)" -ForegroundColor Yellow
}
$confirmation = Read-Host "Para confirmar, escribe el nombre del RG ($RgSC)"
if ($confirmation -ne $RgSC) {
    Write-Host "Cancelado." -ForegroundColor Yellow
    exit 0
}

if ($KeepStorage) {
    # Borrar todo MENOS los Storage Accounts
    $sas = $resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' }
    $toDelete = $resources | Where-Object { $_.type -ne 'Microsoft.Storage/storageAccounts' }

    Write-Host ""
    Write-Host "Moving Storage Accounts a un RG temporal..." -ForegroundColor Cyan
    $tmpRg = "$RgSC-storage-keep"
    az group create -n $tmpRg -l (az group show -n $RgSC --query location -o tsv) -o none

    foreach ($sa in $sas) {
        $saId = (az resource show -g $RgSC -n $sa.name --resource-type $sa.type --query id -o tsv)
        az resource move --destination-group $tmpRg --ids $saId -o none
    }
    Write-Host "  Storage Accounts movidos a $tmpRg" -ForegroundColor Green

    # Borrar el RG original
    Write-Host ""
    Write-Host "Deleting RG $RgSC..." -ForegroundColor Cyan
    az group delete -n $RgSC --yes --no-wait
    Write-Host "  Delete iniciado en background. Verificar con: az group show -n $RgSC" -ForegroundColor Green
} else {
    # Borrar todo
    Write-Host ""
    Write-Host "Deleting RG $RgSC (con TODO incluyendo Storage)..." -ForegroundColor Cyan
    az group delete -n $RgSC --yes --no-wait
    Write-Host "  Delete iniciado en background." -ForegroundColor Green
}

# ===== Limpiar peering del NorthEU (queda apuntando a vacio) =====
Write-Host ""
Write-Host "Removing peering peer-NE-to-SC del lado NorthEU..." -ForegroundColor Cyan
$peerExists = az network vnet peering list -g rg-milink-vm --vnet-name vnet-vm `
    --query "[?name=='peer-NE-to-SC'].name" -o tsv
if ($peerExists) {
    az network vnet peering delete -g rg-milink-vm --vnet-name vnet-vm -n peer-NE-to-SC -o none
    Write-Host "  Peering removed." -ForegroundColor Green
}

# ===== Quitar regla NSG AllowMigrationFromSpainC del lado NorthEU =====
Write-Host "Removing NSG rule AllowMigrationFromSpainC..." -ForegroundColor Cyan
$ruleExists = az network nsg rule list -g rg-milink-vm --nsg-name nsg-vm `
    --query "[?name=='AllowMigrationFromSpainC'].name" -o tsv
if ($ruleExists) {
    az network nsg rule delete -g rg-milink-vm --nsg-name nsg-vm -n AllowMigrationFromSpainC -o none
    Write-Host "  Rule removed." -ForegroundColor Green
}

Write-Host ""
Write-Host "========== CLEANUP COMPLETO ==========" -ForegroundColor Green
Write-Host "RG $RgSC: deletion in progress (background)."
if ($KeepStorage) {
    Write-Host "Storage Account conservado en RG $RgSC-storage-keep"
}
Write-Host "Peering NorthEU<->SpainC: removed"
Write-Host "NSG rule en NorthEU: removed"
