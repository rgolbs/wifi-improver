<#
.SYNOPSIS
    Sequential Windows Wi-Fi & home network diagnostic benchmark.
.DESCRIPTION
    Runs four strictly sequential phases (never overlapping idle latency with load):
      1. Active link stats, Wi-Fi PHY info, and nearby RF channel congestion scan.
      2. Idle traffic check, 30-packet gateway & 1.1.1.1 pings, IPv6 check, 5-hop traceroute.
      3. Direct UDP DNS latency & reliability comparison (Router vs 1.1.1.1 vs 8.8.8.8).
      4. Loaded throughput & bufferbloat via scripts/netbench.mjs (requires Node.js 18+).
.EXAMPLE
    .\scripts\benchmark.ps1
    .\scripts\benchmark.ps1 -PingCount 30 -OutJson results\local-before.json
    .\scripts\benchmark.ps1 -SkipLoad
#>
[CmdletBinding()]
param(
    [int]$PingCount = 30,
    [int]$PingIntervalMs = 250,
    [switch]$SkipLoad,
    [string]$OutJson
)

$ErrorActionPreference = "Continue"

function Get-Percentile([double[]]$Sorted, [double]$P) {
    if ($Sorted.Count -eq 0) { return 0 }
    $idx = [math]::Floor(($Sorted.Count - 1) * $P)
    return [math]::Round($Sorted[$idx], 2)
}

function Invoke-PingStats([string]$Target, [int]$Count, [int]$IntervalMs) {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $rtts = New-Object System.Collections.Generic.List[double]
    $lost = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $reply = $ping.Send($Target, 2000)
            $sw.Stop()
            if ($reply.Status -eq "Success") {
                $rtts.Add($sw.Elapsed.TotalMilliseconds)
            } else {
                $lost++
            }
        } catch {
            $sw.Stop()
            $lost++
        }
        if ($i -lt ($Count - 1)) {
            Start-Sleep -Milliseconds $IntervalMs
        }
    }
    $ping.Dispose()

    if ($rtts.Count -eq 0) {
        return [ordered]@{
            target = $Target; sent = $Count; recv = 0; lossPct = 100.0
            minMs = $null; medMs = $null; avgMs = $null; p95Ms = $null; maxMs = $null; jitterMs = $null
        }
    }

    $sorted = [double[]]($rtts | Sort-Object)
    $diffs = for ($j = 1; $j -lt $rtts.Count; $j++) { [math]::Abs($rtts[$j] - $rtts[$j - 1]) }
    $jitter = if ($diffs) { [math]::Round(($diffs | Measure-Object -Average).Average, 2) } else { 0 }
    return [ordered]@{
        target   = $Target
        sent     = $Count
        recv     = $rtts.Count
        lossPct  = [math]::Round(($lost / $Count) * 100, 1)
        minMs    = [math]::Round($sorted[0], 2)
        medMs    = Get-Percentile $sorted 0.50
        avgMs    = [math]::Round(($rtts | Measure-Object -Average).Average, 2)
        p95Ms    = Get-Percentile $sorted 0.95
        maxMs    = [math]::Round($sorted[$sorted.Count - 1], 2)
        jitterMs = $jitter
    }
}

function New-DnsQueryPacket([string]$Domain) {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $txId = Get-Random -Minimum 1000 -Maximum 65000
    $bw.Write([byte](($txId -shr 8) -band 0xFF))
    $bw.Write([byte]($txId -band 0xFF))
    $bw.Write([byte]0x01); $bw.Write([byte]0x00)
    $bw.Write([byte]0x00); $bw.Write([byte]0x01)
    $bw.Write([byte]0x00); $bw.Write([byte]0x00)
    $bw.Write([byte]0x00); $bw.Write([byte]0x00)
    $bw.Write([byte]0x00); $bw.Write([byte]0x00)
    foreach ($label in $Domain.Split(".")) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($label)
        $bw.Write([byte]$bytes.Length)
        $bw.Write($bytes)
    }
    $bw.Write([byte]0x00)
    $bw.Write([byte]0x00); $bw.Write([byte]0x01)
    $bw.Write([byte]0x00); $bw.Write([byte]0x01)
    return $ms.ToArray()
}

function Invoke-UdpDnsQuery([string]$Server, [string]$Domain, [int]$TimeoutMs = 2500) {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = $TimeoutMs
    $pkt = New-DnsQueryPacket $Domain
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Server), 53)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$udp.Send($pkt, $pkt.Length, $ep)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        [void]$udp.Receive([ref]$remote)
        $sw.Stop()
        return [ordered]@{ ok = $true; ms = $sw.Elapsed.TotalMilliseconds }
    } catch {
        $sw.Stop()
        return [ordered]@{ ok = $false; ms = $sw.Elapsed.TotalMilliseconds }
    } finally {
        $udp.Close()
    }
}

Write-Host "`n=== Step 1: Active Link & Wi-Fi RF Scan ===" -ForegroundColor Cyan

$defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
if (-not $defaultRoute) {
    throw "No active IPv4 default route found."
}

$ifaceAlias = $defaultRoute.InterfaceAlias
$gateway = $defaultRoute.NextHop
$adapter = Get-NetAdapter -Name $ifaceAlias
$stats = Get-NetAdapterStatistics -Name $ifaceAlias
$tcpSetting = Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue
$dnsServers = (Get-DnsClientServerAddress -InterfaceAlias $ifaceAlias -AddressFamily IPv4).ServerAddresses

Write-Host ("Adapter : {0} ({1}) | Link: {2} | Errors: Rx={3} Tx={4} | Discards: Rx={5} Tx={6}" -f `
    $adapter.Name, $adapter.InterfaceDescription, $adapter.LinkSpeed, `
    $stats.ReceivedPacketErrors, $stats.OutboundPacketErrors, `
    $stats.ReceivedDiscardedPackets, $stats.OutboundDiscardedPackets)
Write-Host ("Gateway : {0} | Current DNS: {1} | TCP: {2}, ECN={3}" -f `
    $gateway, ($dnsServers -join ", "), $tcpSetting.CongestionProvider, $tcpSetting.EcnCapability)

$wifiSummary = $null
$rfChannels = @()
$wlanOut = netsh wlan show interfaces 2>&1 | Out-String
if ($wlanOut -match "State\s*:\s*connected") {
    $fields = @{}
    foreach ($line in ($wlanOut -split "`r?`n")) {
        if ($line -match "^\s*([^:]+?)\s*:\s*(.+)$") {
            $fields[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    $wifiSummary = [ordered]@{
        radioType   = $fields["Radio type"]
        band        = $fields["Band"]
        channel     = $fields["Channel"]
        signal      = $fields["Signal"]
        rxRateMbps  = $fields["Receive rate (Mbps)"]
        txRateMbps  = $fields["Transmit rate (Mbps)"]
    }
    Write-Host ("Wi-Fi   : {0} | Band: {1} | Ch: {2} | Signal: {3} | Rx/Tx: {4}/{5} Mbps" -f `
        $wifiSummary.radioType, $wifiSummary.band, $wifiSummary.channel, `
        $wifiSummary.signal, $wifiSummary.rxRateMbps, $wifiSummary.txRateMbps)

    $scanOut = netsh wlan show networks mode=bssid 2>&1 | Out-String
    $curCh = $null; $curSig = $null
    $bssidList = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($scanOut -split "`r?`n")) {
        if ($line -match "^\s*Signal\s*:\s*(\d+)%") { $curSig = [int]$Matches[1] }
        elseif ($line -match "^\s*Channel\s*:\s*(\d+)") {
            $curCh = [int]$Matches[1]
            $bssidList.Add([PSCustomObject]@{ Channel = $curCh; SignalPct = $curSig })
            $curCh = $null; $curSig = $null
        }
    }
    if ($bssidList.Count -gt 0) {
        Write-Host "`nNearby Wi-Fi Channels (competing BSSIDs):"
        $rfChannels = $bssidList | Group-Object Channel | Sort-Object { [int]$_.Name } | ForEach-Object {
            $maxSig = ($_.Group | Measure-Object SignalPct -Maximum).Maximum
            [PSCustomObject]@{
                Band          = if ([int]$_.Name -le 14) { "2.4 GHz" } else { "5/6 GHz" }
                Channel       = [int]$_.Name
                CompetingAPs  = $_.Count
                StrongestPct  = "$maxSig%"
            }
        }
        $rfChannels | Format-Table -AutoSize
    }
} else {
    Write-Host "Wi-Fi   : No active Windows Wi-Fi connection (wired Ethernet or WLAN service stopped)."
}

Write-Host "`n=== Step 2: Idle Traffic, Latency & 5-Hop Traceroute ===" -ForegroundColor Cyan
$s1 = Get-NetAdapterStatistics -Name $ifaceAlias
Start-Sleep -Seconds 2
$s2 = Get-NetAdapterStatistics -Name $ifaceAlias
$idleDownMbps = [math]::Round((($s2.ReceivedBytes - $s1.ReceivedBytes) * 8) / (2 * 1e6), 3)
$idleUpMbps = [math]::Round((($s2.SentBytes - $s1.SentBytes) * 8) / (2 * 1e6), 3)
Write-Host ("Idle traffic (2s): Down={0} Mbps, Up={1} Mbps" -f $idleDownMbps, $idleUpMbps)

$gwPing = Invoke-PingStats $gateway $PingCount $PingIntervalMs
Write-Host ("Gateway ({0}) : Loss={1}% | Min={2}ms Med={3}ms Avg={4}ms P95={5}ms Max={6}ms Jitter={7}ms" -f `
    $gwPing.target, $gwPing.lossPct, $gwPing.minMs, $gwPing.medMs, $gwPing.avgMs, $gwPing.p95Ms, $gwPing.maxMs, $gwPing.jitterMs)

$cfPing = Invoke-PingStats "1.1.1.1" $PingCount $PingIntervalMs
Write-Host ("1.1.1.1 ({0,-12}) : Loss={1}% | Min={2}ms Med={3}ms Avg={4}ms P95={5}ms Max={6}ms Jitter={7}ms" -f `
    "Cloudflare", $cfPing.lossPct, $cfPing.minMs, $cfPing.medMs, $cfPing.avgMs, $cfPing.p95Ms, $cfPing.maxMs, $cfPing.jitterMs)

$v6Ping = Invoke-PingStats "2606:4700:4700::1111" 4 200
$ipv6Active = ($v6Ping.recv -gt 0)
Write-Host ("IPv6 (Cloudflare): {0}" -f $(if ($ipv6Active) { "Active (Med=$($v6Ping.medMs)ms)" } else { "Not active" }))

Write-Host "`n5-Hop Traceroute to 1.1.1.1:"
$traceLines = tracert -d -h 5 -w 1000 1.1.1.1
$traceLines | Where-Object { $_ -match "^\s*\d+" } | ForEach-Object { Write-Host "  $_" }

Write-Host "`n=== Step 3: DNS Latency & Reliability ===" -ForegroundColor Cyan
$domains = @("cloudflare.com","google.com","microsoft.com","github.com","amazon.com","wikipedia.org","apple.com","kernel.org","debian.org","python.org")
$dnsTargets = @(
    [ordered]@{ label = "Router"; ip = $gateway },
    [ordered]@{ label = "Cloudflare"; ip = "1.1.1.1" },
    [ordered]@{ label = "Google"; ip = "8.8.8.8" }
)

$dnsResults = @()
foreach ($t in $dnsTargets) {
    $times = New-Object System.Collections.Generic.List[double]
    $fails = 0
    foreach ($d in $domains) {
        $rand = [guid]::NewGuid().ToString("N").Substring(0, 8)
        $res = Invoke-UdpDnsQuery $t.ip "bench-$rand.$d" 2500
        if ($res.ok) { $times.Add($res.ms) } else { $fails++ }
        Start-Sleep -Milliseconds 60
    }
    $sorted = [double[]]($times | Sort-Object)
    $row = [ordered]@{
        resolver = "$($t.label) ($($t.ip))"
        ok       = "$($times.Count)/$($domains.Count)"
        fails    = $fails
        medMs    = Get-Percentile $sorted 0.50
        avgMs    = if ($times.Count) { [math]::Round(($times | Measure-Object -Average).Average, 2) } else { $null }
        maxMs    = if ($sorted.Count) { [math]::Round($sorted[$sorted.Count - 1], 2) } else { $null }
    }
    $dnsResults += $row
    Write-Host ("{0,-24} | Ok={1} | Med={2}ms Avg={3}ms Max={4}ms" -f $row.resolver, $row.ok, $row.medMs, $row.avgMs, $row.maxMs)
}

$loadResult = $null
if (-not $SkipLoad) {
    Write-Host "`n=== Step 4: Throughput & Bufferbloat Under Load ===" -ForegroundColor Cyan
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    $netbenchPath = Join-Path $PSScriptRoot "netbench.mjs"
    if ($nodeCmd -and (Test-Path $netbenchPath)) {
        $rawJson = & node $netbenchPath --json
        if ($LASTEXITCODE -eq 0 -and $rawJson) {
            $loadResult = $rawJson | ConvertFrom-Json
            Write-Host ("Downlink : {0} Mbps | ICMP {1} -> {2} ms (+{3} ms, Grade {4})" -f `
                $loadResult.downlinkMbps, $loadResult.idleIcmpMs.med, $loadResult.downLoadedIcmpMs.med, `
                $loadResult.bufferbloatDeltaMs.downIcmp, $loadResult.bufferbloatGrade.download)
            Write-Host ("Uplink   : {0} Mbps | ICMP {1} -> {2} ms (+{3} ms, Grade {4})" -f `
                $loadResult.uplinkMbps, $loadResult.idleIcmpMs.med, $loadResult.upLoadedIcmpMs.med, `
                $loadResult.bufferbloatDeltaMs.upIcmp, $loadResult.bufferbloatGrade.upload)
            Write-Host ("HTTP RPM : Idle={0} | Download={1} | Upload={2}" -f `
                $loadResult.responsivenessRpm.idle, $loadResult.responsivenessRpm.downloadLoaded, $loadResult.responsivenessRpm.uploadLoaded)
        } else {
            Write-Warning "netbench.mjs failed to complete."
        }
    } else {
        Write-Warning "Node.js 18+ not found or scripts/netbench.mjs missing; skipping Step 4."
    }
}

Write-Host "`n=== Markdown Summary Table ===" -ForegroundColor Green
Write-Host "| Metric | Measured Value |"
Write-Host "|---|---|"
Write-Host ("| Link | {0} ({1}), Errors Rx/Tx: {2}/{3} |" -f $adapter.LinkSpeed, $adapter.Name, $stats.ReceivedPacketErrors, $stats.OutboundPacketErrors)
if ($wifiSummary) {
    Write-Host ("| Wi-Fi | {0}, {1}, Ch {2}, Signal {3}, {4}/{5} Mbps |" -f $wifiSummary.radioType, $wifiSummary.band, $wifiSummary.channel, $wifiSummary.signal, $wifiSummary.rxRateMbps, $wifiSummary.txRateMbps)
}
Write-Host ("| Gateway Ping ({0} pkts) | {1}% loss, med {2} ms, avg {3} ms, max {4} ms, jitter {5} ms |" -f $PingCount, $gwPing.lossPct, $gwPing.medMs, $gwPing.avgMs, $gwPing.maxMs, $gwPing.jitterMs)
Write-Host ("| 1.1.1.1 Ping ({0} pkts) | {1}% loss, med {2} ms, avg {3} ms, max {4} ms, jitter {5} ms |" -f $PingCount, $cfPing.lossPct, $cfPing.medMs, $cfPing.avgMs, $cfPing.maxMs, $cfPing.jitterMs)
Write-Host ("| Configured DNS | {0} |" -f ($dnsServers -join ", "))
foreach ($r in $dnsResults) {
    Write-Host ("| DNS {0} | {1} ok, med {2} ms, max {3} ms |" -f $r.resolver, $r.ok, $r.medMs, $r.maxMs)
}
if ($loadResult) {
    Write-Host ("| Downlink / Loaded ICMP | {0} Mbps / {1} ms (+{2} ms, Grade {3}) |" -f $loadResult.downlinkMbps, $loadResult.downLoadedIcmpMs.med, $loadResult.bufferbloatDeltaMs.downIcmp, $loadResult.bufferbloatGrade.download)
    Write-Host ("| Uplink / Loaded ICMP | {0} Mbps / {1} ms (+{2} ms, Grade {3}) |" -f $loadResult.uplinkMbps, $loadResult.upLoadedIcmpMs.med, $loadResult.bufferbloatDeltaMs.upIcmp, $loadResult.bufferbloatGrade.upload)
}

if ($OutJson) {
    $report = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        adapter      = [ordered]@{
            name = $adapter.Name; linkSpeed = $adapter.LinkSpeed
            rxErrors = $stats.ReceivedPacketErrors; txErrors = $stats.OutboundPacketErrors
            ecn = "$($tcpSetting.EcnCapability)"; congestion = "$($tcpSetting.CongestionProvider)"
        }
        wifi         = $wifiSummary
        rfChannels   = $rfChannels
        idleTraffic  = [ordered]@{ downMbps = $idleDownMbps; upMbps = $idleUpMbps }
        gatewayPing  = $gwPing
        internetPing = $cfPing
        ipv6Active   = $ipv6Active
        dns          = $dnsResults
        load         = $loadResult
    }
    $dir = Split-Path -Parent $OutJson
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $OutJson -Encoding utf8
    Write-Host "`nSaved JSON report to $OutJson"
}
