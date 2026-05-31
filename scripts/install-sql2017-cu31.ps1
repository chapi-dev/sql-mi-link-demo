# =====================================================================
# install-sql2017-cu31.ps1
# Aplica un CU a una instancia SQL Server 2017 existente.
# MI Link requiere CU20 o superior; recomendado CU31+ para integración
# completa con las stored procedures del Azure Connect Pack.
#
# Verificar la URL del último CU en:
#   https://learn.microsoft.com/sql/database-engine/install-windows/latest-updates-for-microsoft-sql-server
#
# Nota: si la imagen Marketplace ya viene con un CU reciente, este script
# puede saltarse.
# =====================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$CuUrl,
    [string]$CuPath = "C:\MILink\SQL2017-CU.exe"
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path "C:\MILink" -Force | Out-Null

if (-not (Test-Path $CuPath)) {
    Write-Host "Descargando CU..."
    Invoke-WebRequest -Uri $CuUrl -OutFile $CuPath -UseBasicParsing
}

Write-Host "Instalando CU (silencioso)..."
$proc = Start-Process -FilePath $CuPath -ArgumentList "/quiet /IAcceptSQLServerLicenseTerms /Action=Patch /AllInstances" -Wait -PassThru
Write-Host "Exit code: $($proc.ExitCode)"

if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw "Instalacion del CU fallida con exit code $($proc.ExitCode)"
}

Restart-Service -Name MSSQLSERVER -Force

Import-Module SqlServer
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME" -Query "SELECT @@VERSION AS Version, SERVERPROPERTY('ProductUpdateLevel') AS CU;"
