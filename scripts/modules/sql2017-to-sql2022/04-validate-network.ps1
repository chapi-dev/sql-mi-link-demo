# =====================================================================
# 04-validate-network.ps1
# Valida la conectividad de red end-to-end entre vm-sql2017 (NorthEU) y
# vm-sql2022 (SpainC) en puerto 5022 (Distributed AG endpoint).
#
# Ejecuta:
#   - 100 muestras Test-NetConnection desde NorthEU -> SpainC
#   - 100 muestras al reves
#   - Calcula RTT promedio y P95
#   - Reporta umbrales para decidir SYNC vs ASYNC commit
#
# Pre-requisitos:
#   - 01-infra-spain.ps1, 02-install-sql2022.ps1 ya ejecutados
#   - VM origen vm-sql2017 ya tiene SQL escuchando 5022 (modulo MI Link)
#
# Ver: docs/modules/sql2017-northeu-to-sql2022-spainc/rpo-options.md
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$RgNE         = "rg-milink-vm",
    [string]$VmNE         = "vm-sql2017",
    [string]$RgSC         = "rg-mig-spainc",
    [string]$VmSC         = "vm-sql2022",
    [int]$NumSamples      = 100,
    [int]$Port            = 5022
)

$ErrorActionPreference = 'Stop'

az account set --subscription $SubId

# Get private IPs
$ipNE = az vm show -g $RgNE -n $VmNE -d --query privateIps -o tsv
$ipSC = az vm show -g $RgSC -n $VmSC -d --query privateIps -o tsv

if (-not $ipNE) { Write-Error "Cannot get private IP for $VmNE"; exit 1 }
if (-not $ipSC) { Write-Error "Cannot get private IP for $VmSC"; exit 1 }

Write-Host "VM NorthEU ($VmNE): $ipNE" -ForegroundColor Cyan
Write-Host "VM SpainC  ($VmSC): $ipSC" -ForegroundColor Cyan
Write-Host ""

# Script a ejecutar dentro de cada VM (para medir desde ella misma al lado opuesto)
function Get-RemoteTcpTestScript {
    param([string]$TargetIp, [int]$Port, [int]$Samples)
    return @"
`$results = @()
1..$Samples | ForEach-Object {
    `$sw = [System.Diagnostics.Stopwatch]::StartNew()
    `$success = `$false
    try {
        `$tcp = New-Object System.Net.Sockets.TcpClient
        `$task = `$tcp.ConnectAsync('$TargetIp', $Port)
        `$task.Wait(2000) | Out-Null
        if (`$task.IsCompleted -and `$tcp.Connected) {
            `$success = `$true
        }
        `$tcp.Close()
    } catch {
        `$success = `$false
    }
    `$sw.Stop()
    `$results += [PSCustomObject]@{
        Sample = `$_
        Success = `$success
        Ms = if (`$success) { `$sw.ElapsedMilliseconds } else { -1 }
    }
    Start-Sleep -Milliseconds 100
}
`$ok = (`$results | Where-Object { `$_.Success }).Count
`$rtt = `$results | Where-Object { `$_.Success } | Select-Object -ExpandProperty Ms | Sort-Object
if (`$rtt.Count -gt 0) {
    `$avg = (`$rtt | Measure-Object -Average).Average
    `$p50 = `$rtt[[Math]::Floor(`$rtt.Count * 0.50)]
    `$p95 = `$rtt[[Math]::Floor(`$rtt.Count * 0.95)]
    `$p99 = `$rtt[[Math]::Floor(`$rtt.Count * 0.99)]
    `$max = (`$rtt | Measure-Object -Maximum).Maximum
    Write-Host ""
    Write-Host "RESULT: success=`$ok/$Samples avg=`$([Math]::Round(`$avg,2))ms p50=`$($p50)ms p95=`$($p95)ms p99=`$($p99)ms max=`$($max)ms"
} else {
    Write-Host "RESULT: success=0/$Samples — TODOS FALLARON"
}
"@
}

# Test NorthEU -> SpainC
Write-Host "===== NorthEU ($VmNE) -> SpainC ($ipSC):$Port =====" -ForegroundColor Yellow
$script1 = Get-RemoteTcpTestScript -TargetIp $ipSC -Port $Port -Samples $NumSamples
$tmp1 = [System.IO.Path]::GetTempFileName() + ".ps1"
$script1 | Out-File $tmp1 -Encoding UTF8
$res1 = az vm run-command invoke -g $RgNE -n $VmNE --command-id RunPowerShellScript --scripts "@$tmp1" --query "value[0].message" -o tsv
Remove-Item $tmp1
Write-Host $res1

# Test SpainC -> NorthEU
Write-Host ""
Write-Host "===== SpainC ($VmSC) -> NorthEU ($ipNE):$Port =====" -ForegroundColor Yellow
$script2 = Get-RemoteTcpTestScript -TargetIp $ipNE -Port $Port -Samples $NumSamples
$tmp2 = [System.IO.Path]::GetTempFileName() + ".ps1"
$script2 | Out-File $tmp2 -Encoding UTF8
$res2 = az vm run-command invoke -g $RgSC -n $VmSC --command-id RunPowerShellScript --scripts "@$tmp2" --query "value[0].message" -o tsv
Remove-Item $tmp2
Write-Host $res2

# Decision guidance
Write-Host ""
Write-Host "========== INTERPRETACION DEL RESULTADO ==========" -ForegroundColor Green
Write-Host @"
Si p99 < 10 ms y success > 99%:
  -> SYNC commit cross-region es viable (modo B en rpo-options.md)
Si p99 = 10-30 ms:
  -> SYNC commit viable solo para workloads write-light (<50 commits/s)
Si p99 > 30 ms o success < 99%:
  -> Usar ASYNC commit (modo A, recomendado por default)

Nota: el RTT medido aqui es TCP handshake completo (mayor que ping ICMP).
RTT real entre VMs es tipicamente la mitad de lo medido.

Resultado esperado NorthEU<->SpainC: ~25-35 ms RTT TCP.
"@

Write-Host ""
Write-Host "Siguiente paso: ejecutar scripts/modules/sql2017-to-sql2022/05-prepare-sql2022.sql en vm-sql2022"
