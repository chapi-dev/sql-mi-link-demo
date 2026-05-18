$ErrorActionPreference = 'Continue'
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQLServer\Parameters"

function Get-SqlArgCount {
    $a = Get-ItemProperty -Path $regPath
    return ($a.PSObject.Properties | Where-Object { $_.Name -like 'SQLArg*' }).Count
}

Write-Output "=== Step 1: Stop SQL service ==="
Stop-Service MSSQLSERVER -Force
Start-Sleep -Seconds 5
Get-Service MSSQLSERVER | Format-Table Name, Status -AutoSize

Write-Output "=== Step 2: Add SQLArg for single-user mode (-m, sin filtro) ==="
$nextIdx = Get-SqlArgCount
$argName = "SQLArg$nextIdx"
Set-ItemProperty -Path $regPath -Name $argName -Value '-m' -Type String
Write-Output "Added $argName = -m"

Write-Output "=== Step 3: Start SQL in single-user mode ==="
Start-Service MSSQLSERVER
Start-Sleep -Seconds 20
Get-Service MSSQLSERVER | Format-Table Name, Status -AutoSize

Write-Output "=== Step 4: Verify -m flag is active in errorlog ==="
$logPath = "C:\Program Files\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQL\Log\ERRORLOG"
$last = Get-Content $logPath -Tail 30 | Where-Object { $_ -match 'single|admin|register|listen' }
$last | ForEach-Object { Write-Output "LOG: $_" }

Write-Output "=== Step 5: Connect as SYSTEM and try to elevate ==="
$sqlcmd = "ALTER LOGIN sa ENABLE; ALTER LOGIN sa WITH PASSWORD = N'Sa!StrongPwd2026Demo'; ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM]; PRINT 'OK'"
$res = & sqlcmd -S . -E -b -Q $sqlcmd 2>&1
Write-Output "Exit code: $LASTEXITCODE"
$res | ForEach-Object { Write-Output "SQLCMD: $_" }

Write-Output "=== Step 6: Remove -m from registry ==="
Remove-ItemProperty -Path $regPath -Name $argName -ErrorAction SilentlyContinue
Write-Output "Removed $argName"

Write-Output "=== Step 7: Restart SQL normally ==="
Restart-Service MSSQLSERVER -Force
Start-Sleep -Seconds 15
Get-Service MSSQLSERVER | Format-Table Name, Status -AutoSize

Write-Output "=== Step 8: Verify SYSTEM is now sysadmin ==="
& sqlcmd -S . -E -Q "SELECT SUSER_NAME() AS Login, IS_SRVROLEMEMBER('sysadmin') AS IsSysAdmin"
& sqlcmd -S . -E -Q "SELECT name, is_disabled FROM sys.server_principals WHERE name IN ('sa','NT AUTHORITY\SYSTEM')"
