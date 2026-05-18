$ErrorActionPreference = 'Continue'
Write-Output "=== Listen ports ==="
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in @(1433,5022) } | Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table -AutoSize

Write-Output "=== Firewall rules for 5022 ==="
Get-NetFirewallRule -Action Allow -Direction Inbound -Enabled True | ForEach-Object {
  $portFilter = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
  if ($portFilter -and ($portFilter.LocalPort -contains "5022" -or $portFilter.LocalPort -contains "Any")) {
    Write-Output "RULE: $($_.DisplayName) - Ports: $($portFilter.LocalPort) - Protocol: $($portFilter.Protocol)"
  }
}

Write-Output "`n=== Verify endpoint accessible from localhost ==="
$test = Test-NetConnection -ComputerName 10.10.1.4 -Port 5022 -InformationLevel Detailed
$test | Format-List ComputerName, RemoteAddress, RemotePort, TcpTestSucceeded

Write-Output "`n=== Add explicit firewall rule for 5022 ==="
New-NetFirewallRule -DisplayName "SQL AG Mirror 5022" -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow -ErrorAction SilentlyContinue | Out-Null
Get-NetFirewallRule -DisplayName "SQL AG Mirror 5022" | Format-List DisplayName, Enabled, Direction, Action
