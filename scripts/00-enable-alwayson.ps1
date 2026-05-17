# =====================================================================
# 00-enable-alwayson.ps1
# Ejecutar en la VM de SQL Server 2017.
# Habilita Always On AG en la instancia (requisito para MI Link).
# Reinicia el servicio MSSQLSERVER al terminar.
# =====================================================================

$ErrorActionPreference = 'Stop'

Write-Host "Importando SqlServer module..."
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers
}
Import-Module SqlServer

Write-Host "Activando Always On AG en MSSQLSERVER..."
Enable-SqlAlwaysOn -ServerInstance "$env:COMPUTERNAME" -Force

Write-Host "Estado del servicio:"
Get-Service MSSQLSERVER | Format-Table -AutoSize

Write-Host "Verificando IsHadrEnabled..."
Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME" -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled, @@VERSION AS Version;"

# Crear carpeta para backups y cert export
New-Item -ItemType Directory -Path "C:\MILink" -Force | Out-Null
Write-Host "Carpeta C:\MILink lista."
