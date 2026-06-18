# =====================================================================
# 03-create-storage.ps1
# Provisiona Storage Account intermedio para:
#   - Manual seeding del DAG cross-version (.bak + .trn)
#   - Backups pre-cutover (Capa 1 rollback)
#   - BACPAC export (Capa 4 rollback)
#   - Scripts de migracion (logins.sql, configs, SSISDB.bak)
#
# Genera un SAS token y devuelve el T-SQL CREATE CREDENTIAL listo para
# ejecutar en ambas VMs SQL.
#
# Pre-requisitos:
#  - 01-infra-spain.ps1 ya ejecutado
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/networking.md (§7)
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$RgSC      = "rg-mig-spainc",
    [string]$LocSC     = "spaincentral",
    [string]$SaName    = "",   # Default: generate random
    [int]$SasDays      = 30,
    [string]$OutputDir = ".\.migration-secrets"
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
az storage account create `
    -g $RgSC -n $SaName `
    -l $LocSC `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    --access-tier Hot `
    -o none

# Get key for blob admin
$key = az storage account keys list -g $RgSC -n $SaName --query "[0].value" -o tsv

# Containers
$containers = @('seeding', 'cutover-backups', 'rollback', 'migration')
foreach ($c in $containers) {
    Write-Host "  Creating container $c..." -ForegroundColor Cyan
    az storage container create --account-name $SaName --account-key $key --name $c -o none
}

# SAS token (valido $SasDays dias, permisos read+write+list)
$expiry = (Get-Date).AddDays($SasDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Host "Generating SAS token (valid until $expiry)..." -ForegroundColor Cyan

# SAS account-level con permisos para todos los containers (rwldcup = read, write, list, delete, create, update, process)
# Para BACKUP/RESTORE TO URL basta con rwlc (read, write, list, create)
$sas = az storage account generate-sas `
    --account-name $SaName --account-key $key `
    --expiry $expiry `
    --permissions rwlcu `
    --resource-types sco `
    --services b `
    --https-only `
    -o tsv

# Quitar el ? inicial si lo trae
if ($sas.StartsWith('?')) { $sas = $sas.Substring(1) }

# Generar el CREATE CREDENTIAL T-SQL listo para ejecutar
$blobUrl = "https://$SaName.blob.core.windows.net"
$tsqlPath = Join-Path -Path $OutputDir -ChildPath "create-credentials.sql"
$envPath  = Join-Path -Path $OutputDir -ChildPath "storage.env"

New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

@"
-- Generado por 03-create-storage.ps1 el $(Get-Date)
-- Ejecutar en AMBAS VMs SQL Server (vm-sql2017 y vm-sql2022)
-- Pre-requisito: master DB tiene Master Key creada
--   CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<fuerte>';

USE master;
GO

-- Credential para container 'seeding' (manual seeding del DAG)
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = '$blobUrl/seeding')
    DROP CREDENTIAL [$blobUrl/seeding];
CREATE CREDENTIAL [$blobUrl/seeding]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '$sas';
GO

-- Credential para container 'cutover-backups' (Capa 1 rollback)
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = '$blobUrl/cutover-backups')
    DROP CREDENTIAL [$blobUrl/cutover-backups];
CREATE CREDENTIAL [$blobUrl/cutover-backups]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '$sas';
GO

-- Credential para container 'rollback' (BACPAC Capa 4)
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = '$blobUrl/rollback')
    DROP CREDENTIAL [$blobUrl/rollback];
CREATE CREDENTIAL [$blobUrl/rollback]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '$sas';
GO

-- Credential para container 'migration' (logins, configs, SSISDB)
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = '$blobUrl/migration')
    DROP CREDENTIAL [$blobUrl/migration];
CREATE CREDENTIAL [$blobUrl/migration]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '$sas';
GO

-- Verificar
SELECT name, credential_identity, create_date
FROM sys.credentials WHERE name LIKE '$blobUrl%';
"@ | Out-File -FilePath $tsqlPath -Encoding UTF8

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
"@ | Out-File -FilePath $envPath -Encoding UTF8

Write-Host ""
Write-Host "========== Storage Account provisioned DONE ==========" -ForegroundColor Green
Write-Host "Storage Account: $SaName"
Write-Host "Blob URL:        $blobUrl"
Write-Host "Containers:      seeding, cutover-backups, rollback, migration"
Write-Host ""
Write-Host "Generated files:" -ForegroundColor Yellow
Write-Host "  $tsqlPath  <-- ejecutar en ambas VMs SQL"
Write-Host "  $envPath   <-- variables para scripts siguientes"
Write-Host ""
Write-Host "ATENCION: El archivo .sql contiene el SAS token. NO commitear." -ForegroundColor Yellow
Write-Host "Asegurate de que $OutputDir esta en .gitignore." -ForegroundColor Yellow
Write-Host ""
Write-Host "Siguiente paso: scripts/modules/sql2017-to-sql2022/04-validate-network.ps1"
