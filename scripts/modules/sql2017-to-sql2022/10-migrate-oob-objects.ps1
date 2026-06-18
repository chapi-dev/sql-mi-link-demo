# =====================================================================
# 10-migrate-oob-objects.ps1
# Migra los objetos out-of-band (lo que NO replica el DAG) de
# vm-sql2017 -> vm-sql2022:
#   - Logins (con SIDs y password hashes preservados)
#   - SQL Agent jobs (en estado DISABLED en destino)
#   - SQL Agent operators y alerts
#   - Linked servers
#   - Database Mail profiles
#   - sp_configure settings
#   - Resource Governor
#
# Usa dbatools (PowerShell community) que es el estandar de facto para
# migraciones SQL Server. Si no esta instalado, lo instala.
#
# Pre-requisitos:
#   - vm-sql2022 ya provisionada (script 02)
#   - vm-sql2017 accesible desde la maquina del operador
#   - Cuentas de sysadmin en ambas instancias (Windows auth o SQL auth)
#
# Lo que NO migra este script (porque requieren intervencion manual o
# son sensibles a versiones):
#   - Server-level certs (manejados por scripts 05, 07)
#   - Master keys (manejado por 05, 07)
#   - Audit specifications (manejar manualmente post-cutover)
#   - SSIS catalog (SSISDB) - script aparte
#   - CLR assemblies (heredados con la BD)
#   - Server triggers (revisar manualmente)
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/out-of-band-objects.md
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SourceServer,        # ej: 'vm-sql2017.northeurope.cloudapp.azure.com'
    [Parameter(Mandatory)] [string]$DestServer,          # ej: 'vm-sql2022.spaincentral.cloudapp.azure.com'
    [Parameter(Mandatory)] [PSCredential]$SourceCred,    # cuenta sysadmin en source
    [Parameter(Mandatory)] [PSCredential]$DestCred,      # cuenta sysadmin en dest
    [switch]$SkipLogins,
    [switch]$SkipJobs,
    [switch]$SkipLinkedServers,
    [switch]$SkipDbMail,
    [switch]$SkipSpConfigure,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ===== Instalar dbatools si no esta =====
if (-not (Get-Module -ListAvailable -Name dbatools)) {
    Write-Host "Installing dbatools module..." -ForegroundColor Cyan
    Install-Module dbatools -Scope CurrentUser -Force -AllowClobber
}
Import-Module dbatools -Force

# Connection objects
$sourceParams = @{ SqlInstance = $SourceServer; SqlCredential = $SourceCred; TrustServerCertificate = $true }
$destParams   = @{ SqlInstance = $DestServer;   SqlCredential = $DestCred;   TrustServerCertificate = $true }

# Validar conexion a ambos
Write-Host "Validating connections..." -ForegroundColor Cyan
$srcVersion = Connect-DbaInstance @sourceParams | Select-Object -ExpandProperty Version
$dstVersion = Connect-DbaInstance @destParams | Select-Object -ExpandProperty Version
Write-Host "  Source ($SourceServer): $srcVersion" -ForegroundColor Green
Write-Host "  Dest   ($DestServer):   $dstVersion" -ForegroundColor Green

if ($DryRun) {
    Write-Host "DRY RUN mode - no se ejecutara nada, solo se contara." -ForegroundColor Yellow
}

# ===== Logins =====
if (-not $SkipLogins) {
    Write-Host ""
    Write-Host "===== LOGINS =====" -ForegroundColor Yellow
    $sourceLogins = Get-DbaLogin @sourceParams | Where-Object { $_.Name -notlike '##%' -and $_.IsSystemObject -eq $false }
    Write-Host "Source tiene $($sourceLogins.Count) logins no-system."

    if (-not $DryRun) {
        Copy-DbaLogin -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred `
            -ExcludeLogin sa | Format-Table -Property SourceServer, DestinationServer, Name, Status, Notes -AutoSize
    }
}

# ===== SQL Agent Jobs =====
if (-not $SkipJobs) {
    Write-Host ""
    Write-Host "===== SQL AGENT JOBS =====" -ForegroundColor Yellow
    $sourceJobs = Get-DbaAgentJob @sourceParams | Where-Object { $_.Name -notlike 'syspolicy_%' }
    Write-Host "Source tiene $($sourceJobs.Count) jobs."

    if (-not $DryRun) {
        Copy-DbaAgentJob -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred `
            -DisableOnDestination | Format-Table -Property SourceServer, DestinationServer, Name, Status -AutoSize

        Write-Host ""
        Write-Host "Operators..." -ForegroundColor Cyan
        Copy-DbaAgentOperator -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred |
            Format-Table -Property Name, Status -AutoSize

        Write-Host ""
        Write-Host "Alerts..." -ForegroundColor Cyan
        Copy-DbaAgentAlert -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred |
            Format-Table -Property Name, Status -AutoSize
    }
}

# ===== Linked Servers =====
if (-not $SkipLinkedServers) {
    Write-Host ""
    Write-Host "===== LINKED SERVERS =====" -ForegroundColor Yellow
    $sourceLS = Get-DbaLinkedServer @sourceParams
    Write-Host "Source tiene $($sourceLS.Count) linked servers."

    if (-not $DryRun -and $sourceLS.Count -gt 0) {
        Write-Host "ATENCION: linked servers pueden requerir reentrada de credentials." -ForegroundColor Yellow
        Copy-DbaLinkedServer -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred |
            Format-Table -Property Name, Status, Notes -AutoSize
    }
}

# ===== Database Mail =====
if (-not $SkipDbMail) {
    Write-Host ""
    Write-Host "===== DATABASE MAIL =====" -ForegroundColor Yellow
    $sourceMail = Get-DbaDbMailProfile @sourceParams
    Write-Host "Source tiene $($sourceMail.Count) mail profiles."

    if (-not $DryRun -and $sourceMail.Count -gt 0) {
        Copy-DbaDbMail -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred |
            Format-Table -Property Type, Name, Status -AutoSize
    }
}

# ===== sp_configure settings =====
if (-not $SkipSpConfigure) {
    Write-Host ""
    Write-Host "===== sp_configure SETTINGS =====" -ForegroundColor Yellow
    if (-not $DryRun) {
        # Comparar primero
        $diff = Compare-DbaSpConfigure -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred
        $diff | Format-Table -Property ConfigName, SourceConfigValue, DestinationConfigValue -AutoSize

        Write-Host ""
        Write-Host "Aplicando settings que difieren..." -ForegroundColor Cyan
        Copy-DbaSpConfigure -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred |
            Format-Table -Property ConfigName, Status -AutoSize
    }
}

# ===== Resource Governor =====
Write-Host ""
Write-Host "===== RESOURCE GOVERNOR =====" -ForegroundColor Yellow
$rg = Get-DbaResourceGovernor @sourceParams
if ($rg.Enabled) {
    Write-Host "Resource Governor habilitado en source. Copiando..." -ForegroundColor Cyan
    if (-not $DryRun) {
        Copy-DbaResourceGovernor -Source $SourceServer -Destination $DestServer `
            -SourceSqlCredential $SourceCred -DestinationSqlCredential $DestCred |
            Format-Table -Property Type, Name, Status -AutoSize
    }
} else {
    Write-Host "Resource Governor no habilitado en source. Saltando."
}

# ===== Resumen final =====
Write-Host ""
Write-Host "========== 10-migrate-oob-objects.ps1 COMPLETADO ==========" -ForegroundColor Green
Write-Host ""
Write-Host "VALIDACION SIGUIENTE (ejecutar manualmente en vm-sql2022):" -ForegroundColor Yellow
Write-Host "  -- Logins (debe coincidir con source):"
Write-Host "     SELECT COUNT(*) FROM sys.server_principals WHERE type IN ('S','U','G');"
Write-Host "  -- Jobs (deben estar disabled):"
Write-Host "     SELECT COUNT(*), SUM(CASE WHEN enabled=1 THEN 1 ELSE 0 END) FROM msdb.dbo.sysjobs;"
Write-Host "  -- Linked servers:"
Write-Host "     SELECT COUNT(*) FROM sys.servers WHERE is_linked = 1;"
Write-Host ""
Write-Host "PENDIENTE MANUAL (no automatizado):"
Write-Host "  - Credentials (si usan): pasar SECRET y CREATE CREDENTIAL manual"
Write-Host "  - Audit specifications"
Write-Host "  - Server triggers (revisar y scriptear)"
Write-Host "  - SSIS catalog (SSISDB backup+restore aparte)"
Write-Host ""
Write-Host "Siguiente paso: scripts 11-12 para crear AGs locales."
