# =====================================================================
# 02-install-sql2022.ps1
# Provisiona la VM Windows + SQL Server 2022 Developer Edition en Spain Central.
# Habilita Always On AG y abre puerto 5022 en Windows Firewall.
#
# Pre-requisitos:
#  - 01-infra-spain.ps1 ya ejecutado (RG, VNet, NSG existen)
#  - Provider registrado: Microsoft.Compute
#
# Imagen Marketplace utilizada por default:
#   MicrosoftSQLServer:sql2022-ws2022:sqldev-gen2:latest
#   (Developer edition, sin coste de licencia SQL para entornos no-prod)
# Para produccion con licencia BYOL, usar:
#   --image MicrosoftSQLServer:sql2022-ws2022:enterprise:latest
#   o --image MicrosoftSQLServer:sql2022-ws2022:standard:latest
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/architecture.md
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$RgSC              = "rg-mig-spainc",
    [string]$LocSC             = "spaincentral",
    [string]$VnetSC            = "vnet-mig-spainc",
    [string]$SubnetSC          = "snet-vm",
    [string]$NsgSC             = "nsg-vm-spainc",
    [string]$VmName            = "vm-sql2022",
    [string]$VmSize            = "Standard_E4ads_v5",
    [string]$VmAdminUser       = "azureuser",
    [Parameter(Mandatory)] [string]$VmAdminPwd,
    [string]$VmImage           = "MicrosoftSQLServer:sql2022-ws2022:sqldev-gen2:latest",
    [string]$OsDiskSizeGb      = 127,
    [string]$DataDiskSizeGb    = 256,
    [string]$LogDiskSizeGb     = 128,
    [string]$DataDiskSku       = "Premium_LRS",
    [switch]$NoPublicIp        = $false   # por defecto crea IP publica para RDP
)

$ErrorActionPreference = 'Stop'

az account set --subscription $SubId

# --- VM con discos data/log dedicados ---
Write-Host "Creating VM $VmName in $LocSC..." -ForegroundColor Cyan

$pipArg = if ($NoPublicIp) { @("--public-ip-address", "''") } else { @("--public-ip-sku", "Standard") }

az vm create `
    --resource-group $RgSC `
    --name $VmName `
    --location $LocSC `
    --image $VmImage `
    --size $VmSize `
    --admin-username $VmAdminUser `
    --admin-password $VmAdminPwd `
    --vnet-name $VnetSC `
    --subnet $SubnetSC `
    --nsg '""' `
    --os-disk-size-gb $OsDiskSizeGb `
    --storage-sku StandardSSD_LRS `
    @pipArg `
    --license-type None `
    -o none

if ($LASTEXITCODE -ne 0) {
    Write-Error "az vm create failed with exit $LASTEXITCODE"
    exit 1
}

# El --nsg '""' indica "no crear NSG nuevo en la NIC" (el NSG ya esta en el subnet).
# Sintaxis especial PowerShell -> CLI: usar '""' (PowerShell strip de comillas).

Write-Host "  VM creada. Anyadiendo discos data/log..." -ForegroundColor Cyan

# --- Data disk ---
az vm disk attach `
    --resource-group $RgSC --vm-name $VmName `
    --name "$VmName-data" --new --size-gb $DataDiskSizeGb --sku $DataDiskSku `
    -o none

# --- Log disk ---
az vm disk attach `
    --resource-group $RgSC --vm-name $VmName `
    --name "$VmName-log" --new --size-gb $LogDiskSizeGb --sku $DataDiskSku `
    -o none

# --- Asociar NSG al subnet (si no estaba) ---
# Confirmar
$subnetNsg = az network vnet subnet show -g $RgSC --vnet-name $VnetSC -n $SubnetSC --query "networkSecurityGroup.id" -o tsv
if (-not $subnetNsg -or $subnetNsg -notlike "*$NsgSC") {
    Write-Host "Asociando NSG $NsgSC al subnet $SubnetSC..." -ForegroundColor Cyan
    az network vnet subnet update -g $RgSC --vnet-name $VnetSC -n $SubnetSC `
        --network-security-group $NsgSC -o none
}

# --- Configurar discos + Windows Firewall + Always On dentro de la VM ---
Write-Host "Configurando discos, Firewall y Always On dentro de la VM..." -ForegroundColor Cyan

$initScript = @'
$ErrorActionPreference = 'Stop'

# Detect raw disks (data + log)
$rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object Size

if ($rawDisks.Count -ge 1) {
    # Smallest = log (assume 128 GB) or whichever sequence
    $logDisk = $rawDisks[0]
    Initialize-Disk -Number $logDisk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $logDisk.Number -UseMaximumSize -DriveLetter L | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel "Log" -Confirm:$false -Force
    Write-Host "Log disk initialized as L:"
}
if ($rawDisks.Count -ge 2) {
    $dataDisk = $rawDisks[1]
    Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize -DriveLetter D | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel "Data" -Confirm:$false -Force
    Write-Host "Data disk initialized as D:"
}

# Folders para SQL
New-Item -Path "D:\Data" -ItemType Directory -Force | Out-Null
New-Item -Path "L:\Log" -ItemType Directory -Force | Out-Null
New-Item -Path "D:\Backup" -ItemType Directory -Force | Out-Null
New-Item -Path "C:\certs" -ItemType Directory -Force | Out-Null
New-Item -Path "C:\migration" -ItemType Directory -Force | Out-Null

# Windows Firewall: open 5022 + 1433
New-NetFirewallRule -DisplayName "SQL AG Endpoint 5022" -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "SQL Server 1433" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -ErrorAction SilentlyContinue | Out-Null
Write-Host "Firewall rules added."

# Enable Always On
Import-Module SqlServer -Force -ErrorAction SilentlyContinue
$instance = (Get-Service | Where-Object { $_.Name -like 'MSSQL$*' -or $_.Name -eq 'MSSQLSERVER' } | Select-Object -First 1).Name
if ($instance -eq 'MSSQLSERVER') {
    Enable-SqlAlwaysOn -ServerInstance "$env:COMPUTERNAME" -Force
} else {
    $instName = $instance -replace 'MSSQL\$', ''
    Enable-SqlAlwaysOn -ServerInstance "$env:COMPUTERNAME\$instName" -Force
}
Restart-Service $instance -Force
Write-Host "Always On enabled on $instance."

# Verify
$srv = "."
Start-Sleep -Seconds 10
$isHadr = Invoke-Sqlcmd -ServerInstance $srv -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS hadr" -ErrorAction SilentlyContinue
Write-Host "IsHadrEnabled = $($isHadr.hadr)"
'@

# Ejecutar dentro de la VM via run-command
$scriptFile = [System.IO.Path]::GetTempFileName() + ".ps1"
$initScript | Out-File -FilePath $scriptFile -Encoding UTF8

az vm run-command invoke `
    -g $RgSC -n $VmName `
    --command-id RunPowerShellScript `
    --scripts "@$scriptFile" `
    -o none

Remove-Item $scriptFile

Write-Host ""
Write-Host "========== VM SQL Server 2022 provisioned DONE ==========" -ForegroundColor Green
Write-Host "VM: $VmName"
Write-Host "Image: $VmImage"
Write-Host "Data disk: D:\ ($DataDiskSizeGb GB)"
Write-Host "Log disk:  L:\ ($LogDiskSizeGb GB)"
Write-Host "Always On: enabled"
Write-Host "Firewall:  5022 open"
Write-Host ""
$pip = az vm show -g $RgSC -n $VmName -d --query publicIps -o tsv
if ($pip) { Write-Host "Public IP (para RDP): $pip" -ForegroundColor Yellow }
$privIp = az vm show -g $RgSC -n $VmName -d --query privateIps -o tsv
Write-Host "Private IP: $privIp" -ForegroundColor Yellow
Write-Host ""
Write-Host "Siguiente paso: scripts/modules/sql2017-to-sql2022/03-create-storage.ps1"
