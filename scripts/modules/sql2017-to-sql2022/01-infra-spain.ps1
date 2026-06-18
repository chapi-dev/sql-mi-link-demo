# =====================================================================
# 01-infra-spain.ps1
# Provisiona la infraestructura Azure en Spain Central para la migracion
# SQL Server 2017 (NorthEU) -> SQL Server 2022 (SpainC) via Distributed AG.
#
# Esto crea:
#  - RG nuevo en Spain Central
#  - VNet con CIDR no-solapante (default 10.30.0.0/16)
#  - Subnet snet-vm
#  - NSG con regla 5022 inbound desde la subred NorthEU
#  - Global VNet peering bidireccional NorthEU <-> SpainC
#  - Anyade regla en el NSG existente de NorthEU para permitir 5022 desde SpainC
#
# Pre-requisitos:
#  - az login + az account set --subscription "<sub>"
#  - VNet existente en NorthEU del modulo MI Link (vnet-vm en rg-milink-vm por default)
#  - Providers registrados: Microsoft.Network, Microsoft.Compute
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/networking.md
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,

    # NorthEU (existente)
    [string]$RgNE              = "rg-milink-vm",
    [string]$VnetNE            = "vnet-vm",
    [string]$NsgNE             = "nsg-vm",
    [string]$SubnetNECidr      = "10.10.1.0/24",

    # SpainC (nuevo)
    [string]$RgSC              = "rg-mig-spainc",
    [string]$LocSC             = "spaincentral",
    [string]$VnetSC            = "vnet-mig-spainc",
    [string]$VnetSCCidr        = "10.30.0.0/16",
    [string]$SubnetSC          = "snet-vm",
    [string]$SubnetSCCidr      = "10.30.1.0/24",
    [string]$NsgSC             = "nsg-vm-spainc",

    # RDP source (tu IP publica, para regla NSG)
    [string]$AllowRdpFromIp    = ""
)

$ErrorActionPreference = 'Stop'

Write-Host "Setting subscription..." -ForegroundColor Cyan
az account set --subscription $SubId

# --- Validacion: CIDR de SpainC no debe solapar con CIDRs existentes ---
Write-Host "Validating CIDR non-overlap..." -ForegroundColor Cyan
$existingVnets = az network vnet list --query "[].{name:name, prefixes:addressSpace.addressPrefixes}" | ConvertFrom-Json
foreach ($v in $existingVnets) {
    foreach ($p in $v.prefixes) {
        if ($p -eq $VnetSCCidr) {
            Write-Error "CIDR $VnetSCCidr already used by VNet '$($v.name)'. Choose another."
            exit 1
        }
    }
}
Write-Host "  OK: $VnetSCCidr no solapa." -ForegroundColor Green

# --- RG SpainC ---
Write-Host "Creating RG $RgSC in $LocSC..." -ForegroundColor Cyan
az group create -n $RgSC -l $LocSC -o none

# --- VNet + Subnet SpainC ---
Write-Host "Creating VNet $VnetSC ($VnetSCCidr) + subnet $SubnetSC ($SubnetSCCidr)..." -ForegroundColor Cyan
az network vnet create `
    -g $RgSC -n $VnetSC -l $LocSC `
    --address-prefixes $VnetSCCidr `
    --subnet-name $SubnetSC --subnet-prefixes $SubnetSCCidr `
    -o none

# --- NSG SpainC ---
Write-Host "Creating NSG $NsgSC..." -ForegroundColor Cyan
az network nsg create -g $RgSC -n $NsgSC -l $LocSC -o none

# RDP rule (si se especifico IP publica)
if ($AllowRdpFromIp) {
    Write-Host "Adding RDP rule from $AllowRdpFromIp..." -ForegroundColor Cyan
    az network nsg rule create `
        -g $RgSC --nsg-name $NsgSC -n AllowRDP `
        --priority 1000 `
        --source-address-prefixes $AllowRdpFromIp `
        --destination-port-ranges 3389 `
        --access Allow --protocol Tcp --direction Inbound `
        -o none
} else {
    Write-Host "  Skipping RDP rule (-AllowRdpFromIp not specified). Use Bastion or add later." -ForegroundColor Yellow
}

# DAG endpoint rule (5022 inbound desde subred NorthEU)
Write-Host "Adding rule AllowMigrationFromNorthEU (port 5022 from $SubnetNECidr)..." -ForegroundColor Cyan
az network nsg rule create `
    -g $RgSC --nsg-name $NsgSC -n AllowMigrationFromNorthEU `
    --priority 1100 `
    --source-address-prefixes $SubnetNECidr `
    --destination-port-ranges 5022 `
    --access Allow --protocol Tcp --direction Inbound `
    -o none

# Asociar NSG al subnet
Write-Host "Associating NSG to subnet $SubnetSC..." -ForegroundColor Cyan
az network vnet subnet update `
    -g $RgSC --vnet-name $VnetSC -n $SubnetSC `
    --network-security-group $NsgSC `
    -o none

# --- Peering bidireccional NorthEU <-> SpainC ---
Write-Host "Creating global VNet peering NorthEU <-> SpainC..." -ForegroundColor Cyan

$vnetNEId = az network vnet show -g $RgNE -n $VnetNE --query id -o tsv
$vnetSCId = az network vnet show -g $RgSC -n $VnetSC --query id -o tsv

# Peering NE -> SC
$existingPeerNE = az network vnet peering list -g $RgNE --vnet-name $VnetNE --query "[?name=='peer-NE-to-SC'].name" -o tsv
if (-not $existingPeerNE) {
    az network vnet peering create `
        -g $RgNE -n peer-NE-to-SC `
        --vnet-name $VnetNE `
        --remote-vnet $vnetSCId `
        --allow-vnet-access `
        --allow-forwarded-traffic `
        -o none
}

# Peering SC -> NE
$existingPeerSC = az network vnet peering list -g $RgSC --vnet-name $VnetSC --query "[?name=='peer-SC-to-NE'].name" -o tsv
if (-not $existingPeerSC) {
    az network vnet peering create `
        -g $RgSC -n peer-SC-to-NE `
        --vnet-name $VnetSC `
        --remote-vnet $vnetNEId `
        --allow-vnet-access `
        --allow-forwarded-traffic `
        -o none
}

# Verificar
Write-Host "Verifying peering state..." -ForegroundColor Cyan
$peerNEState = az network vnet peering show -g $RgNE --vnet-name $VnetNE -n peer-NE-to-SC --query peeringState -o tsv
$peerSCState = az network vnet peering show -g $RgSC --vnet-name $VnetSC -n peer-SC-to-NE --query peeringState -o tsv

if ($peerNEState -eq 'Connected' -and $peerSCState -eq 'Connected') {
    Write-Host "  OK: peering Connected en ambos sentidos." -ForegroundColor Green
} else {
    Write-Error "Peering not Connected: NE=$peerNEState SC=$peerSCState"
    exit 1
}

# --- Regla 5022 en el NSG de NorthEU para permitir trafico desde SpainC ---
Write-Host "Adding rule AllowMigrationFromSpainC to NSG $NsgNE in NorthEU..." -ForegroundColor Cyan
$existingRuleNE = az network nsg rule list -g $RgNE --nsg-name $NsgNE --query "[?name=='AllowMigrationFromSpainC'].name" -o tsv
if (-not $existingRuleNE) {
    az network nsg rule create `
        -g $RgNE --nsg-name $NsgNE -n AllowMigrationFromSpainC `
        --priority 1200 `
        --source-address-prefixes $SubnetSCCidr `
        --destination-port-ranges 5022 `
        --access Allow --protocol Tcp --direction Inbound `
        -o none
    Write-Host "  OK: regla anyadida al NSG existente." -ForegroundColor Green
} else {
    Write-Host "  Rule already exists. Skipping." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========== Infra Spain Central provisioning DONE ==========" -ForegroundColor Green
Write-Host "RG: $RgSC"
Write-Host "VNet: $VnetSC ($VnetSCCidr)"
Write-Host "Subnet: $SubnetSC ($SubnetSCCidr)"
Write-Host "NSG: $NsgSC (con AllowMigrationFromNorthEU 5022)"
Write-Host "Peering: $RgNE/$VnetNE <-> $RgSC/$VnetSC"
Write-Host ""
Write-Host "Siguiente paso: scripts/modules/sql2017-to-sql2022/02-install-sql2022.ps1"
