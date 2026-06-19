# =====================================================================
# 03-create-storage.ps1
# Provisiona Storage Account intermedio para:
#   - Manual seeding del DAG cross-version (.bak + .trn)
#   - Backups pre-cutover (Capa 1 rollback)
#   - BACPAC export (Capa 4 rollback)
#   - Scripts de migracion (logins.sql, configs, SSISDB.bak)
#
# Genera un SAS token (user-delegation) y devuelve el T-SQL CREATE CREDENTIAL listo para
# ejecutar en ambas VMs SQL.
#
# Pre-requisitos:
#  - 01-infra-spain.ps1 ya ejecutado
#  - El usuario ejecutor tiene rol "Storage Blob Data Contributor" o equivalente
#
# Compatible con politicas que prohiben key-based auth (uses Azure RBAC + SAS de usuario).
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/networking.md (§7)
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$RgSC      = "rg-mig-spainc",
    [string]$LocSC     = "spaincentral",
    [string]$SaName    = "",   # Default: generate random
    [int]$SasDays      = 30,
    [string]$OutputDir = ".\.migration-secrets",
    [switch]$AllowSharedKey = $false   # set true si la policy lo permite (SQL Server BACKUP TO URL es mas robusto con shared-key SAS)
)

$ErrorActionPreference = 'Stop'

az account set --subscription $SubId

if (-not $SaName) {
    $SaName = "stmilinkmig$(Get-Random -Maximum 99999)"
}

# Validar disponibilidad del nombre
$avail = az storage account check-name --name $SaName --query nameAvailable -o tsv
if ($avail -ne 'true') {
    Write-Error "Storage account name '$SaName' not available. Try another."
    exit 1
}

Write-Host "Creating Storage Account $SaName in $LocSC..." -ForegroundColor Cyan
$sharedKeyFlag = if ($AllowSharedKey) { "true" } else { "false" }
az storage account create `
    -g $RgSC -n $SaName `
    -l $LocSC `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    --allow-shared-key-access $sharedKeyFlag `
    --access-tier Hot `
    -o none
if ($LASTEXITCODE -ne 0) { Write-Error "Storage account create failed"; exit 1 }

# Grant current user "Storage Blob Data Contributor" para que --auth-mode login funcione para containers
$saId = az storage account show -g $RgSC -n $SaName --query id -o tsv
$myObjId = az ad signed-in-user show --query id -o tsv
Write-Host "Granting 'Storage Blob Data Contributor' to current user..." -ForegroundColor Cyan
az role assignment create `
    --assignee-object-id $myObjId `
    --assignee-principal-type User `
    --role "Storage Blob Data Contributor" `
    --scope $saId `
    -o none 2>$null
# Esperar a que el rol propague (puede tardar 30-60s)
Write-Host "Esperando propagacion del role (60s)..." -ForegroundColor Yellow
Start-Sleep -Seconds 60

# Containers (con --auth-mode login)
$containers = @('seeding', 'cutover-backups', 'rollback', 'migration')
foreach ($c in $containers) {
    Write-Host "  Creating container $c..." -ForegroundColor Cyan
    az storage container create `
        --account-name $SaName `
        --name $c `
        --auth-mode login `
        -o none
    if ($LASTEXITCODE -ne 0) { Write-Warning "Container $c creation failed (continuing)" }
}

# SAS token: user-delegation SAS si no se permite shared key
$expiry = (Get-Date).AddDays($SasDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Host "Generating SAS token (valid until $expiry)..." -ForegroundColor Cyan

if ($AllowSharedKey) {
    # SAS con account key (mas robusto para SQL Server BACKUP TO URL)
    $key = az storage account keys list -g $RgSC -n $SaName --query "[0].value" -o tsv
    $sas = az storage account generate-sas `
        --account-name $SaName --account-key $key `
        --expiry $expiry `
        --permissions rwlcu `
        --resource-types sco `
        --services b `
        --https-only `
        -o tsv
} else {
    # User-delegation SAS (Entra ID)
    # SQL Server soporta user-delegation SAS desde 2022 para BACKUP/RESTORE TO URL
    # LIMITACION OFICIAL: user-delegation SAS strictly < 7 days expiry (en la practica, 6 dias es seguro)
    Write-Host "  Using user-delegation SAS (Entra ID based)..." -ForegroundColor Yellow
    if ($SasDays -gt 6) {
        Write-Warning "  User-delegation SAS limited to 6 days max (strict < 7d limit). Capping SasDays from $SasDays to 6."
        $expiry = (Get-Date).AddDays(6).ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    # Generar SAS por container (user-delegation no soporta account-level)
    $sasByContainer = @{}
    foreach ($c in $containers) {
        $sasContainer = az storage container generate-sas `
            --account-name $SaName `
            --name $c `
            --expiry $expiry `
            --permissions rwl `
            --auth-mode login `
            --as-user `
            --https-only `
            -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $sasContainer) {
            $sasByContainer[$c] = $sasContainer
            Write-Host "    SAS for $c generated"
        } else {
            Write-Warning "    SAS for $c failed - $LASTEXITCODE"
        }
    }
    $sas = $null  # No hay account-level SAS
}

# Quitar el ? inicial si lo trae
if ($sas -and $sas.StartsWith('?')) { $sas = $sas.Substring(1) }

# Generar el CREATE CREDENTIAL T-SQL listo para ejecutar
$blobUrl = "https://$SaName.blob.core.windows.net"
$tsqlPath = Join-Path -Path $OutputDir -ChildPath "create-credentials.sql"
$envPath  = Join-Path -Path $OutputDir -ChildPath "storage.env"

New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

# Si usamos shared-key SAS, una sola credential
if ($AllowSharedKey -and $sas) {
@"
-- Generado por 03-create-storage.ps1 el $(Get-Date)
-- Ejecutar en AMBAS VMs SQL Server (vm-sql2017 y vm-sql2022)
-- Pre-requisito: master DB tiene Master Key creada

USE master;
GO

$(foreach ($c in $containers) {
@"
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = '$blobUrl/$c')
    DROP CREDENTIAL [$blobUrl/$c];
CREATE CREDENTIAL [$blobUrl/$c]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '$sas';
GO

"@
})

SELECT name, credential_identity, create_date
FROM sys.credentials WHERE name LIKE '$blobUrl%';
"@ | Out-File -FilePath $tsqlPath -Encoding UTF8
} else {
    # User-delegation: una credential por container
@"
-- Generado por 03-create-storage.ps1 el $(Get-Date)
-- ATENCION: usando user-delegation SAS (sin shared key access).
-- Cada container tiene su propio SAS. SQL Server >= 2022 soporta este modo.
-- Ejecutar en AMBAS VMs SQL Server (vm-sql2017 y vm-sql2022).
-- Pre-requisito: master DB tiene Master Key creada.

USE master;
GO

$(foreach ($c in $containers) {
    $sasC = $sasByContainer[$c]
    if ($sasC -and $sasC.StartsWith('?')) { $sasC = $sasC.Substring(1) }
@"
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = '$blobUrl/$c')
    DROP CREDENTIAL [$blobUrl/$c];
CREATE CREDENTIAL [$blobUrl/$c]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '$sasC';
GO

"@
})

SELECT name, credential_identity, create_date
FROM sys.credentials WHERE name LIKE '$blobUrl%';
"@ | Out-File -FilePath $tsqlPath -Encoding UTF8
}

# Variables de entorno para los scripts siguientes
@"
# Generado por 03-create-storage.ps1 el $(Get-Date)
STORAGE_ACCOUNT=$SaName
BLOB_URL=$blobUrl
SAS_EXPIRY=$expiry
SEEDING_CONTAINER=$blobUrl/seeding
CUTOVER_BACKUPS_CONTAINER=$blobUrl/cutover-backups
ROLLBACK_CONTAINER=$blobUrl/rollback
MIGRATION_CONTAINER=$blobUrl/migration
ALLOW_SHARED_KEY=$($AllowSharedKey.IsPresent)
"@ | Out-File -FilePath $envPath -Encoding UTF8

Write-Host ""
Write-Host "========== Storage Account provisioned DONE ==========" -ForegroundColor Green
Write-Host "Storage Account: $SaName"
Write-Host "Blob URL:        $blobUrl"
Write-Host "Containers:      seeding, cutover-backups, rollback, migration"
Write-Host "Shared key auth: $($AllowSharedKey.IsPresent)"
Write-Host ""
Write-Host "Generated files:" -ForegroundColor Yellow
Write-Host "  $tsqlPath  <-- ejecutar en ambas VMs SQL"
Write-Host "  $envPath   <-- variables para scripts siguientes"
Write-Host ""
Write-Host "ATENCION: El archivo .sql contiene el SAS token. NO commitear." -ForegroundColor Yellow
Write-Host "Asegurate de que $OutputDir esta en .gitignore." -ForegroundColor Yellow
Write-Host ""
if (-not $AllowSharedKey) {
    Write-Host "NOTA: Si la sub permite shared-key, usar -AllowSharedKey para SAS account-level." -ForegroundColor Yellow
    Write-Host "      Algunas operaciones SQL pueden requerir shared-key SAS (testear)." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Siguiente paso: scripts/modules/sql2017-to-sql2022/04-validate-network.ps1"
