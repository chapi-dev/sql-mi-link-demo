# =====================================================================
# 01-infra.ps1
# Provisiona toda la infraestructura Azure para la demo MI Link:
#  - 2 RGs (FRA para VM, ESP para MI)
#  - 2 VNets con peering global bidireccional
#  - Subred MI delegada con NSG y route table
#  - VM Windows Server 2019 + SQL Server 2017 Developer
#  - Azure SQL Managed Instance (GP Gen5, AAD-only auth)
#
# Antes de ejecutar:
#  - az login y az account set --subscription "<tu-sub>"
#  - Tener providers registrados: Microsoft.Sql, Microsoft.Compute, Microsoft.Network
# =====================================================================

param(
    [string]$SubId        = "<YOUR-SUBSCRIPTION-ID>",
    [string]$RgVm         = "rg-sqlmilink-vm-fra",
    [string]$RgMi         = "rg-sqlmilink-mi-esp",
    [string]$LocVm        = "francecentral",
    [string]$LocMi        = "spaincentral",
    [string]$VnetVm       = "vnet-vm-fra",
    [string]$VnetMi       = "vnet-mi-esp",
    [string]$VmName       = "vm-sql2017",
    [string]$VmSize       = "Standard_L2as_v4",
    [string]$VmAdminUser  = "azureuser",
    [string]$VmAdminPwd   = $(throw "Pasa -VmAdminPwd"),
    [string]$MiName       = "mi-link-demo-fraesp",
    [string]$MiAadAdminUpn= $(throw "Pasa -MiAadAdminUpn"),
    [string]$MiAadAdminObjId = $(throw "Pasa -MiAadAdminObjId")
)

az account set --subscription $SubId

# --- Resource groups ---
az group create -n $RgVm -l $LocVm -o none
az group create -n $RgMi -l $LocMi -o none

# --- VNet VM (10.10.0.0/16) ---
az network vnet create -g $RgVm -n $VnetVm -l $LocVm `
    --address-prefixes 10.10.0.0/16 `
    --subnet-name snet-vm --subnet-prefixes 10.10.1.0/24 -o none

az network nsg create -g $RgVm -n nsg-vm-fra -l $LocVm -o none
az network nsg rule create -g $RgVm --nsg-name nsg-vm-fra -n AllowRDP `
    --priority 1000 --protocol Tcp --destination-port-ranges 3389 --access Allow --direction Inbound -o none
az network nsg rule create -g $RgVm --nsg-name nsg-vm-fra -n AllowMirroringFromMI `
    --priority 1100 --protocol Tcp --destination-port-ranges 5022 `
    --source-address-prefixes 10.20.0.0/24 --access Allow --direction Inbound -o none
az network vnet subnet update -g $RgVm --vnet-name $VnetVm -n snet-vm --network-security-group nsg-vm-fra -o none

# --- VNet MI (10.20.0.0/16) ---
az network vnet create -g $RgMi -n $VnetMi -l $LocMi --address-prefixes 10.20.0.0/16 -o none
az network route-table create -g $RgMi -n rt-mi-esp -l $LocMi --disable-bgp-route-propagation false -o none

az network nsg create -g $RgMi -n nsg-mi-esp -l $LocMi -o none
# Inbound MI obligatorias
az network nsg rule create -g $RgMi --nsg-name nsg-mi-esp -n allow_tds_inbound `
    --priority 1000 --protocol Tcp --destination-port-ranges 1433 `
    --source-address-prefixes VirtualNetwork --access Allow --direction Inbound -o none
az network nsg rule create -g $RgMi --nsg-name nsg-mi-esp -n allow_redirect_inbound `
    --priority 1100 --protocol Tcp --destination-port-ranges 11000-11999 `
    --source-address-prefixes VirtualNetwork --access Allow --direction Inbound -o none
# Inbound 5022 desde VNet de VM peered
az network nsg rule create -g $RgMi --nsg-name nsg-mi-esp -n allow_mirroring_inbound `
    --priority 1200 --protocol Tcp --destination-port-ranges 5022 `
    --source-address-prefixes 10.10.0.0/16 --access Allow --direction Inbound -o none
az network nsg rule create -g $RgMi --nsg-name nsg-mi-esp -n deny_all_inbound `
    --priority 4096 --protocol '*' --destination-port-ranges '*' `
    --source-address-prefixes '*' --access Deny --direction Inbound -o none
# Outbound
az network nsg rule create -g $RgMi --nsg-name nsg-mi-esp -n allow_management_outbound `
    --priority 1000 --protocol Tcp --destination-port-ranges 80 443 12000 `
    --destination-address-prefixes AzureCloud --access Allow --direction Outbound -o none
az network nsg rule create -g $RgMi --nsg-name nsg-mi-esp -n allow_misubnet_outbound `
    --priority 1100 --protocol '*' --destination-port-ranges '*' `
    --destination-address-prefixes 10.20.0.0/24 --access Allow --direction Outbound -o none
az network nsg rule create -g $RgMi --nsg-name nsg-mi-esp -n allow_mirroring_outbound `
    --priority 1200 --protocol Tcp --destination-port-ranges 5022 `
    --destination-address-prefixes 10.10.0.0/16 --access Allow --direction Outbound -o none
az network nsg rule create -g $RgMi --nsg-name nsg-mi-esp -n deny_all_outbound `
    --priority 4096 --protocol '*' --destination-port-ranges '*' `
    --destination-address-prefixes '*' --access Deny --direction Outbound -o none

# Subred MI delegada
az network vnet subnet create -g $RgMi --vnet-name $VnetMi -n ManagedInstance `
    --address-prefixes 10.20.0.0/24 `
    --delegations Microsoft.Sql/managedInstances `
    --network-security-group nsg-mi-esp `
    --route-table rt-mi-esp -o none

# --- Global VNet peering ---
$idVm = az network vnet show -g $RgVm -n $VnetVm --query id -o tsv
$idMi = az network vnet show -g $RgMi -n $VnetMi --query id -o tsv
az network vnet peering create -g $RgVm --vnet-name $VnetVm -n fra-to-esp --remote-vnet $idMi --allow-vnet-access -o none
az network vnet peering create -g $RgMi --vnet-name $VnetMi -n esp-to-fra --remote-vnet $idVm --allow-vnet-access -o none

# --- VM SQL Server 2017 ---
az vm create -g $RgVm -n $VmName -l $LocVm `
    --image MicrosoftSQLServer:sql2017-ws2019:sqldev-gen2:latest `
    --size $VmSize `
    --admin-username $VmAdminUser --admin-password $VmAdminPwd `
    --vnet-name $VnetVm --subnet snet-vm `
    --public-ip-sku Standard --public-ip-address-allocation Static `
    --os-disk-size-gb 128 --storage-sku StandardSSD_LRS `
    --nsg-rule RDP -o none

# --- Azure SQL Managed Instance (AAD-only auth) ---
# Nota: el tenant MCAPS exige AAD-only auth via policy.
$miSubnetId = az network vnet subnet show -g $RgMi --vnet-name $VnetMi -n ManagedInstance --query id -o tsv
az sql mi create -g $RgMi -n $MiName -l $LocMi `
    --subnet $miSubnetId `
    --tier GeneralPurpose --family Gen5 --capacity 4 --storage 32GB `
    --license LicenseIncluded `
    --enable-ad-only-auth `
    --external-admin-name $MiAadAdminUpn `
    --external-admin-sid $MiAadAdminObjId `
    --external-admin-principal-type User `
    --no-wait

Write-Host "Infra desplegada. MI tarda 4-6h en estar 'Ready'."
Write-Host "Comprobar estado: az sql mi show -g $RgMi -n $MiName --query state -o tsv"
