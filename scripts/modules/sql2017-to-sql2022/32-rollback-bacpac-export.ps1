# =====================================================================
# 32-rollback-bacpac-export.ps1
# CAPA 4 del rollback plan: BACPAC export de SpainC + import a VM SQL 2017.
#
# Aplica si pasaron dias/semanas desde el cutover y se decide volver al
# 2017 con los datos actuales. Por la forward-only compat, NO se puede
# usar BACKUP/RESTORE — hay que hacer export logico (BACPAC).
#
# Pre-requisitos:
#   - SqlPackage instalado (incluido en SSMS / DAC Framework)
#   - BD <AppDb> en SpainC con compatibility_level <= 140 (lo del 2017)
#     o no usa features de SQL 2022
#   - VM SQL 2017 destino disponible
#
# Tiempo estimado:
#   - BD 10 GB:  ~30 min
#   - BD 100 GB: 2-8 h
#   - BD 1 TB:   12-24 h
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/rollback-plan.md (§7)
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SourceServer,        # vm-sql2022.spaincentral...
    [Parameter(Mandatory)] [PSCredential]$SourceCred,
    [Parameter(Mandatory)] [string]$DestServer,          # vm-sql2017-restored...
    [Parameter(Mandatory)] [PSCredential]$DestCred,
    [string]$DbName              = "AppDb",
    [string]$TargetDbName        = "",                    # default: $DbName
    [string]$WorkDir             = ".\.rollback",
    [string]$SqlPackagePath      = "",                    # auto-detect si vacio
    [switch]$ReadOnlyDuringExport = $false,               # set BD readonly durante export (zero loss)
    [switch]$Verify               = $true
)

$ErrorActionPreference = 'Stop'

if (-not $TargetDbName) { $TargetDbName = $DbName }

# ===== Locate SqlPackage =====
if (-not $SqlPackagePath) {
    $candidates = @(
        "${env:ProgramFiles}\Microsoft SQL Server\160\DAC\bin\SqlPackage.exe",
        "${env:ProgramFiles}\Microsoft SQL Server\150\DAC\bin\SqlPackage.exe",
        "${env:ProgramFiles}\Microsoft SQL Server Management Studio 21\SqlPackage.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server\160\DAC\bin\SqlPackage.exe"
    )
    $SqlPackagePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $SqlPackagePath) {
        # Try dotnet tool
        if (Get-Command sqlpackage -ErrorAction SilentlyContinue) {
            $SqlPackagePath = "sqlpackage"
        } else {
            Write-Error "SqlPackage not found. Install via: dotnet tool install --global Microsoft.SqlPackage"
            exit 1
        }
    }
}
Write-Host "Using SqlPackage: $SqlPackagePath" -ForegroundColor Cyan

New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$bacpacFile = Join-Path $WorkDir "$DbName`_$timestamp.bacpac"

# ===== Si --ReadOnlyDuringExport, marcar BD READ_ONLY =====
if ($ReadOnlyDuringExport) {
    Write-Host "Setting source DB READ_ONLY for zero-loss export..." -ForegroundColor Yellow
    $sql1 = "ALTER DATABASE [$DbName] SET READ_ONLY WITH ROLLBACK IMMEDIATE;"
    Invoke-Sqlcmd -ServerInstance $SourceServer -Username $SourceCred.UserName `
        -Password $SourceCred.GetNetworkCredential().Password `
        -Query $sql1 -TrustServerCertificate
    Write-Host "  BD ahora READ_ONLY. La app no podra escribir hasta el final del export."
}

# ===== EXPORT =====
Write-Host ""
Write-Host "===== EXPORTING BACPAC =====" -ForegroundColor Yellow
Write-Host "Source: $SourceServer / $DbName"
Write-Host "Target file: $bacpacFile"
Write-Host "Empezando $(Get-Date) — puede tardar horas..."

$exportArgs = @(
    "/Action:Export",
    "/SourceServerName:$SourceServer",
    "/SourceDatabaseName:$DbName",
    "/SourceUser:$($SourceCred.UserName)",
    "/SourcePassword:$($SourceCred.GetNetworkCredential().Password)",
    "/TargetFile:$bacpacFile",
    "/OverwriteFiles:True",
    "/SourceTrustServerCertificate:True",
    "/p:VerifyExtraction=True"
)

& $SqlPackagePath $exportArgs
if ($LASTEXITCODE -ne 0) { Write-Error "Export failed with exit $LASTEXITCODE"; exit 1 }
Write-Host "  Export completado: $((Get-Item $bacpacFile).Length / 1MB) MB"

# ===== Si --ReadOnlyDuringExport, restore READ_WRITE en source =====
if ($ReadOnlyDuringExport) {
    Write-Host ""
    Write-Host "Restoring source DB to READ_WRITE..." -ForegroundColor Yellow
    $sql2 = "ALTER DATABASE [$DbName] SET READ_WRITE;"
    Invoke-Sqlcmd -ServerInstance $SourceServer -Username $SourceCred.UserName `
        -Password $SourceCred.GetNetworkCredential().Password `
        -Query $sql2 -TrustServerCertificate
}

# ===== IMPORT al destino (SQL 2017) =====
Write-Host ""
Write-Host "===== IMPORTING BACPAC TO DEST =====" -ForegroundColor Yellow
Write-Host "Dest: $DestServer / $TargetDbName"
Write-Host "Empezando $(Get-Date)..."

$importArgs = @(
    "/Action:Import",
    "/SourceFile:$bacpacFile",
    "/TargetServerName:$DestServer",
    "/TargetDatabaseName:$TargetDbName",
    "/TargetUser:$($DestCred.UserName)",
    "/TargetPassword:$($DestCred.GetNetworkCredential().Password)",
    "/TargetTrustServerCertificate:True"
)

& $SqlPackagePath $importArgs
if ($LASTEXITCODE -ne 0) { Write-Error "Import failed with exit $LASTEXITCODE"; exit 1 }
Write-Host "  Import completado."

Write-Host ""
Write-Host "========== ROLLBACK CAPA 4 COMPLETADO ==========" -ForegroundColor Green
Write-Host "BD $TargetDbName creada en $DestServer (SQL 2017)."
Write-Host ""
Write-Host "RPO: tx desde el momento del export."
Write-Host "RTO: lo que tardo este script (horas)."
Write-Host ""
Write-Host "Acciones pendientes:"
Write-Host "  1. Validar paridad de datos vs SpainC"
Write-Host "  2. Migrar logins/jobs/etc (script 10 inverso)"
Write-Host "  3. App repoint al destino 2017"
Write-Host "  4. NO subir compatibility_level a 160 si esta BD se mantiene en 2017"
