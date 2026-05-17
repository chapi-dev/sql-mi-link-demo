# =====================================================================
# install-sql2017-cu31.ps1
# Descarga e instala el CU mas reciente para SQL Server 2017 (CU31).
# MI Link requiere CU20+; instalamos el ultimo CU disponible.
# Tarda 20-30 minutos. Reinicia el servicio MSSQLSERVER al terminar.
# =====================================================================

$ErrorActionPreference = 'Stop'

# Direct link al SQLServer2017-KB5029376-x64.exe (CU31) Mayo 2024
# Si cambia, buscar 'SQL Server 2017 latest CU' en download.microsoft.com
$cuUrl  = "https://download.microsoft.com/download/6/e/7/6e72dddf-dfa4-4889-bc3d-e5d3a0fd11ce/SQLServer2017-KB5029376-x64.exe"
$cuPath = "C:\MILink\SQL2017-CU31.exe"

New-Item -ItemType Directory -Path "C:\MILink" -Force | Out-Null

if (-not (Test-Path $cuPath)) {
    Write-Host "Descargando CU31..."
    Invoke-WebRequest -Uri $cuUrl -OutFile $cuPath -UseBasicParsing
}

Write-Host "Instalando CU31 (silencioso, ~20-30 min)..."
$proc = Start-Process -FilePath $cuPath -ArgumentList "/quiet /IAcceptSQLServerLicenseTerms /Action=Patch /AllInstances" -Wait -PassThru
Write-Host "Exit code: $($proc.ExitCode)"

if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw "Instalacion CU31 fallida con exit code $($proc.ExitCode)"
}

Restart-Service -Name MSSQLSERVER -Force

Import-Module SqlServer
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME" -Query "SELECT @@VERSION AS Version, SERVERPROPERTY('ProductUpdateLevel') AS CU;"
