<#
.SYNOPSIS
  eduroam-boost for Windows (experimental): get off slow 2.4 GHz access points.

.DESCRIPTION
  status      current band / signal / first-hop latency, with a diagnosis (default)
  prefer-5g   set the Wi-Fi driver's "Preferred Band" to 5 GHz (persistent; asks for admin)
              add -Undo to restore the driver default
  boost       reconnect Wi-Fi (up to -Tries times) until it is on 5/6 GHz and fast
  watch       sample every -Interval seconds; notify (or -Auto reconnect) when it degrades
  report      how often boosting helped and how long it lasted (-Hours 24)

  Works on Windows PowerShell 5.1 and PowerShell 7. Uses only built-in tools (netsh, NetAdapter).
#>
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [switch]$Auto,
    [switch]$Force,
    [switch]$Undo,
    [int]$Tries = 3,
    [int]$Interval = 30,
    [double]$Hours = 24
)

$Script:Version = '0.1.0'
$Script:DataDir = if ($env:EDUROAM_BOOST_HOME) { $env:EDUROAM_BOOST_HOME } else { Join-Path $env:LOCALAPPDATA 'eduroam-boost' }
$Script:BadGwMs = 100
$Script:BadLoss = 10
$Script:BadStreak = 3
$Script:Cooldown = 300

function T([string]$zh, [string]$en) {
    $lang = if ($env:EDUROAM_BOOST_LANG) { $env:EDUROAM_BOOST_LANG } else { (Get-UICulture).Name }
    if ($lang -like 'zh*') { $zh } else { $en }
}

# ------------------------------------------------------------------ parsing (unit tested)

function Split-NetshLines([string]$Text) {
    # netsh prints "    Key      : Value". Keys are localized, so callers match values where possible.
    $pairs = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s+(.+?)\s+:\s?(.*)$')
        if ($m.Success) { $pairs += [pscustomobject]@{ Key = $m.Groups[1].Value.Trim(); Value = $m.Groups[2].Value.Trim() } }
    }
    $pairs
}

function Get-BandFromValue([string]$v) {
    if ($v -match '^\s*6(\.\d+)?\s*GHz') { return '6GHz' }
    if ($v -match '^\s*5(\.\d+)?\s*GHz') { return '5GHz' }
    if ($v -match '^\s*2\.4\s*GHz') { return '2.4GHz' }
    return $null
}

function Get-BandFromChannel([int]$ch) {
    if ($ch -ge 1 -and $ch -le 14) { return '2.4GHz' }
    if ($ch -ge 32) { return '5GHz' }   # 6 GHz channels overlap numerically; netsh "Band" wins when present
    return '?'
}

function ConvertFrom-NetshInterfaces([string]$Text) {
    <# Returns the first connected interface as an object, or $null. #>
    $blocks = @(); $cur = $null
    foreach ($p in (Split-NetshLines $Text)) {
        if ($p.Key -match '^(Name|名称|名稱|Nom|Nombre)$') { $cur = @{ Name = $p.Value }; $blocks += $cur; continue }
        if ($null -eq $cur) { continue }
        $k = $p.Key; $v = $p.Value
        if ($k -match '^(SSID)$') { $cur.SSID = $v }
        elseif ((Get-BandFromValue $v)) { $cur.Band = Get-BandFromValue $v }
        elseif ($k -match 'Channel|信道|頻道|Canal|Kanal' -and $v -match '^\d+$') { $cur.Channel = [int]$v }
        elseif ($k -match '^Rssi$' -and $v -match '^-?\d+$') { $cur.Rssi = [int]$v }
        elseif ($v -match '^(\d+)\s*%$') { $cur.Quality = [int]$Matches[1] }
        elseif ($k -match 'Mbps') {
            if (-not $cur.ContainsKey('Rate') -and $v -match '^[\d.]+$') { $cur.Rate = [double]$v }
        }
        elseif ($k -match '^(Profile|配置文件|設定檔|Profil|Perfil)$') { $cur.Profile = $v }
        elseif ($v -match '^802\.11') { $cur.Radio = $v }
        elseif ($k -match '^(State|状态|狀態|État|Estado|Status)$') { $cur.Connected = ($v -match '^(connected|已连接|已連線|connecté|conectado|verbunden)$') }
        elseif ($v -match 'Enterprise|企业|企業|Entreprise|Empresa|Unternehmen') { $cur.Enterprise = $true }
    }
    foreach ($b in $blocks) {
        if ($b.Connected) {
            if (-not $b.Band -and $b.Channel) { $b.Band = Get-BandFromChannel $b.Channel }
            if (-not $b.ContainsKey('Rssi') -and $b.ContainsKey('Quality')) { $b.Rssi = [int]($b.Quality / 2 - 100) }
            if (-not $b.ContainsKey('Enterprise')) { $b.Enterprise = $false }
            return [pscustomobject]$b
        }
    }
    return $null
}

function ConvertFrom-NetshNetworks([string]$Text) {
    <# Parses `netsh wlan show networks mode=bssid` into BSS objects (Ssid, Band, Channel, Quality, Enterprise). #>
    $list = @(); $ssid = $null; $ent = $false; $bss = $null
    foreach ($p in (Split-NetshLines $Text)) {
        if ($p.Key -match '^SSID\s+\d+') { $ssid = $p.Value; $ent = $false; $bss = $null; continue }
        if ($p.Key -match '^BSSID\s+\d+') { $bss = @{ Ssid = $ssid; Enterprise = $ent; Band = $null; Channel = 0; Quality = 0 }; $list += $bss; continue }
        if ($p.Value -match 'Enterprise|企业|企業|Entreprise|Empresa|Unternehmen') { $ent = $true; if ($bss) { $bss.Enterprise = $true } }
        if ($null -eq $bss) { continue }
        if ((Get-BandFromValue $p.Value)) { $bss.Band = Get-BandFromValue $p.Value }
        elseif ($p.Value -match '^(\d+)\s*%$') { $bss.Quality = [int]$Matches[1] }
        elseif ($p.Key -match 'Channel|信道|頻道|Canal|Kanal' -and $p.Value -match '^\d+$') { $bss.Channel = [int]$p.Value }
    }
    foreach ($b in $list) { if (-not $b.Band -and $b.Channel) { $b.Band = Get-BandFromChannel $b.Channel } }
    $list | ForEach-Object { [pscustomobject]$_ }
}

function Get-FastNearby($Link, $Networks) {
    <# 5/6 GHz BSSes of the same SSID (or, if SSIDs are hidden, the same security type). #>
    @($Networks | Where-Object {
            ($_.Band -eq '5GHz' -or $_.Band -eq '6GHz') -and
            ((($Link.SSID) -and ($_.Ssid -eq $Link.SSID)) -or ((-not $Link.SSID) -and ($_.Enterprise -eq $Link.Enterprise)))
        })
}

function Get-Reasons($Sample) {
    $r = @()
    if (-not $Sample.Link) { return @(T '没连上 Wi-Fi' 'not connected to Wi-Fi') }
    if ($Sample.Link.Band -eq '2.4GHz' -and $Sample.FastNearby -gt 0) { $r += (T '连在 2.4GHz，但附近有同名 5/6GHz 热点' 'on 2.4 GHz although the same network is available on 5/6 GHz') }
    if ($null -ne $Sample.GwMs -and $Sample.GwMs -gt $Script:BadGwMs) { $r += (T ("到路由器平均 {0:N0}ms" -f $Sample.GwMs) ("first hop averages {0:N0} ms" -f $Sample.GwMs)) }
    if ($Sample.GwLoss -gt $Script:BadLoss) { $r += (T ("到路由器丢包 {0:N0}%" -f $Sample.GwLoss) ("{0:N0}% first-hop loss" -f $Sample.GwLoss)) }
    $r
}

function Get-Score($Sample) {
    if (-not $Sample.Link -or $null -eq $Sample.GwMs) { return 1e9 }
    $pen = 0; if ($Sample.Link.Band -eq '2.4GHz') { $pen = 50 }
    $Sample.GwMs + $Sample.GwLoss * 20 + $pen
}

# ------------------------------------------------------------------ system access

function Get-WifiAdapterName {
    try {
        $a = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.NdisPhysicalMedium -eq 9 } | Select-Object -First 1
        if ($a) { return $a.Name }
    } catch { }
    $l = ConvertFrom-NetshInterfaces (netsh wlan show interfaces | Out-String)
    if ($l) { return $l.Name }
    'Wi-Fi'
}

function Get-Gateway {
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if ($r) { $r.NextHop } else { $null }
}

function Measure-Ping([string]$HostName, [int]$Count = 10) {
    if (-not $HostName) { return @{ Avg = $null; Loss = 100.0 } }
    $p = New-Object System.Net.NetworkInformation.Ping
    $times = @()
    for ($i = 0; $i -lt $Count; $i++) {
        try { $reply = $p.Send($HostName, 1000); if ($reply.Status -eq 'Success') { $times += $reply.RoundtripTime } } catch { }
        Start-Sleep -Milliseconds 200
    }
    $loss = 100.0 * ($Count - $times.Count) / $Count
    $avg = $null; if ($times.Count) { $avg = [math]::Round(($times | Measure-Object -Average).Average, 1) }
    @{ Avg = $avg; Loss = $loss }
}

function Measure-Sample([int]$Count = 10) {
    $link = ConvertFrom-NetshInterfaces (netsh wlan show interfaces | Out-String)
    $fast = 0
    if ($link) {
        $nets = ConvertFrom-NetshNetworks (netsh wlan show networks mode=bssid | Out-String)
        $fast = (Get-FastNearby $link $nets).Count
    }
    $ping = Measure-Ping (Get-Gateway) $Count
    [pscustomobject]@{ ts = (Get-Date).ToString('s'); Link = $link; FastNearby = $fast; GwMs = $ping.Avg; GwLoss = $ping.Loss }
}

function Format-Sample($s) {
    if (-not $s.Link) { return (T '未连接' 'disconnected') }
    $gw = if ($null -eq $s.GwMs) { '-' } else { "{0:N0}ms" -f $s.GwMs }
    "{0} ch{1} {2}dBm {3}Mbps | {4} {5} {6} {7:N0}%" -f $s.Link.Band, $s.Link.Channel, $s.Link.Rssi, $s.Link.Rate, (T '路由器' 'router'), $gw, (T '丢包' 'loss'), $s.GwLoss
}

function Add-Log([string]$Name, $Obj) {
    New-Item -ItemType Directory -Force -Path $Script:DataDir | Out-Null
    $path = Join-Path $Script:DataDir $Name
    ($Obj | ConvertTo-Json -Compress -Depth 5) | Add-Content -Path $path -Encoding UTF8
    if ((Get-Item $path).Length -gt 5MB) { $lines = Get-Content $path; $lines[([int]($lines.Count / 2))..($lines.Count - 1)] | Set-Content $path -Encoding UTF8 }
}

function Read-Log([string]$Name, [datetime]$Since) {
    $path = Join-Path $Script:DataDir $Name
    if (-not (Test-Path $path)) { return @() }
    @(Get-Content $path -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ -and [datetime]$_.ts -ge $Since })
}

function Invoke-Reconnect([string]$Adapter, [string]$WifiProfile) {
    netsh wlan disconnect interface="$Adapter" | Out-Null
    Start-Sleep -Seconds 3
    if ($WifiProfile) { netsh wlan connect name="$WifiProfile" interface="$Adapter" | Out-Null }
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if ($null -ne (Measure-Ping (Get-Gateway) 1).Avg) { return $true }
    }
    $false
}

function Show-Toast([string]$Message) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.Visible = $true
        $n.ShowBalloonTip(8000, 'eduroam-boost', $Message, 'Info')
        Start-Sleep -Seconds 8
        $n.Dispose()
    } catch { Write-Host $Message }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------ commands

function Invoke-Status {
    $s = Measure-Sample
    if (-not $s.Link) { Write-Host (T '没连上 Wi-Fi' 'Not connected to Wi-Fi'); return 1 }
    Write-Host ("{0}  {1}  ({2})" -f (T '网络' 'Network'), $s.Link.SSID, $s.Link.Radio)
    Write-Host ("{0}  {1}  ch {2}" -f (T '频段' 'Band   '), $s.Link.Band, $s.Link.Channel)
    Write-Host ("{0}  {1} dBm" -f (T '信号' 'Signal '), $s.Link.Rssi)
    Write-Host ("{0}  {1} Mbps" -f (T '速率' 'Rate   '), $s.Link.Rate)
    $gw = if ($null -eq $s.GwMs) { '-' } else { "{0:N0} ms" -f $s.GwMs }
    Write-Host ("{0}  {1}, {2} {3:N0}%" -f (T '路由器' 'Router '), $gw, (T '丢包' 'loss'), $s.GwLoss)
    if ($s.FastNearby -gt 0) { Write-Host (T "附近同名 5/6GHz 热点: $($s.FastNearby) 个" "Same network on 5/6 GHz nearby: $($s.FastNearby) AP(s)") }
    $r = Get-Reasons $s
    if ($r) {
        Write-Host ("`n" + (T '诊断: 连接差 — ' 'Diagnosis: slow — ') + ($r -join '; '))
        Write-Host (T '建议: eduroam-boost prefer-5g（一劳永逸）或 eduroam-boost boost' 'Try:  eduroam-boost prefer-5g (persistent) or eduroam-boost boost')
    } else { Write-Host ("`n" + (T '诊断: 正常' 'Diagnosis: fine')) }
    0
}

function Invoke-Prefer5G([switch]$Undo) {
    $adapter = Get-WifiAdapterName
    if (-not (Test-Admin)) {
        Write-Host (T '需要管理员权限，正在请求…' 'Administrator rights needed, requesting…')
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" prefer-5g"
        if ($Undo) { $argList += ' -Undo' }
        Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
        return 0
    }
    $prop = Get-NetAdapterAdvancedProperty -Name $adapter -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Preferred Band|Band Preference|Prefer(red)? ?5|首选频带|首选频段|偏好頻帶|慣用頻帶|Bevorzugtes Band|Bande préférée|Banda preferida' } | Select-Object -First 1
    if (-not $prop) {
        Write-Host (T "网卡 $adapter 的驱动没有“首选频带”选项，只能用 boost。" "The driver of $adapter has no 'Preferred Band' setting; use boost instead.")
        return 2
    }
    if ($Undo) {
        Reset-NetAdapterAdvancedProperty -Name $adapter -DisplayName $prop.DisplayName
        Write-Host (T "已恢复 $($prop.DisplayName) 的默认值" "Restored default for $($prop.DisplayName)")
        return 0
    }
    $target = $prop.ValidDisplayValues | Where-Object { $_ -match '5\s*G' -and $_ -notmatch '2\.4' } | Select-Object -First 1
    if (-not $target) { Write-Host ("No 5 GHz option in: " + ($prop.ValidDisplayValues -join ', ')); return 2 }
    Set-NetAdapterAdvancedProperty -Name $adapter -DisplayName $prop.DisplayName -DisplayValue $target
    Write-Host (T "✅ $($prop.DisplayName) = $target（重启后也有效；网卡会重连一次）" "✅ $($prop.DisplayName) = $target (persists across reboots; the adapter reconnects once)")
    0
}

function Invoke-Boost([int]$Tries, [switch]$Force, [string]$Trigger = 'manual', [switch]$Quiet) {
    $adapter = Get-WifiAdapterName
    $before = Measure-Sample
    if (-not $Quiet) { Write-Host ((T '重连前: ' 'before: ') + (Format-Sample $before)) }
    if (-not $Force -and -not (Get-Reasons $before)) {
        if (-not $Quiet) { Write-Host (T '现在已经不错了（加 -Force 强制重连）。' 'Already good (use -Force to reconnect anyway).') }
        return 0
    }
    $wifiProfile = if ($before.Link) { $before.Link.Profile } else { $null }
    $best = $before; $n = 0
    for ($i = 1; $i -le $Tries; $i++) {
        $n = $i
        if (-not $Quiet) { Write-Host (T "第 $i 次重连（会断网几秒）…" "reconnect #$i (Wi-Fi drops for a few seconds)…") }
        if (-not (Invoke-Reconnect $adapter $wifiProfile)) { continue }
        Start-Sleep -Seconds 2
        $after = Measure-Sample
        if (-not $Quiet) { Write-Host ('  ' + (Format-Sample $after)) }
        if ((Get-Score $after) -lt (Get-Score $best)) { $best = $after }
        if (-not (Get-Reasons $after)) { break }
    }
    $ok = -not (Get-Reasons $best)
    Add-Log 'boosts.jsonl' ([pscustomobject]@{ ts = $before.ts; trigger = $Trigger; tries = $n; success = $ok; before = $before; after = $best })
    if (-not $Quiet) {
        if ($ok) { Write-Host ((T '✅ 好了: ' '✅ done: ') + (Format-Sample $best)) }
        else { Write-Host (T '❌ 还是慢：试试 eduroam-boost prefer-5g，或换个离 AP 近的位置。' '❌ Still slow: try eduroam-boost prefer-5g, or move closer to an AP.') }
    }
    if ($ok) { 0 } else { 2 }
}

function Invoke-Watch([int]$Interval, [switch]$Auto) {
    Write-Host (T "开始监控：每 $Interval 秒一次。日志: $Script:DataDir" "Watching every $Interval s. Logs: $Script:DataDir")
    $streak = 0; $lastFix = [datetime]::MinValue
    while ($true) {
        $s = Measure-Sample 5
        $r = Get-Reasons $s
        $s | Add-Member -NotePropertyName bad -NotePropertyValue ([bool]$r) -Force
        Add-Log 'samples.jsonl' $s
        Write-Host ("{0} {1} {2}" -f $s.ts.Substring(11), (Format-Sample $s), $(if ($r) { '!' } else { '' }))
        if ($r) { $streak++ } else { $streak = 0 }
        if ($streak -ge $Script:BadStreak) {
            $streak = 0
            if ($Auto -and ((Get-Date) - $lastFix).TotalSeconds -gt $Script:Cooldown) {
                $lastFix = Get-Date
                Invoke-Boost -Tries 2 -Trigger 'auto' -Quiet | Out-Null
            } elseif (-not $Auto) {
                Show-Toast ((T 'Wi-Fi 变慢了：' 'Wi-Fi is slow: ') + ($r -join '; '))
            }
        }
        Start-Sleep -Seconds $Interval
    }
}

function Get-Summary($Samples, $Boosts) {
    $out = [ordered]@{ samples = @($Samples).Count; bands = @{}; median = @{}; badShare = $null; boosts = @() }
    foreach ($s in $Samples) {
        $b = if ($s.Link) { $s.Link.Band } else { 'offline' }
        if (-not $out.bands.ContainsKey($b)) { $out.bands[$b] = 0 }
        $out.bands[$b]++
    }
    foreach ($b in @($out.bands.Keys)) {
        $v = @($Samples | Where-Object { $_.Link -and $_.Link.Band -eq $b -and $null -ne $_.GwMs } | ForEach-Object { [double]$_.GwMs } | Sort-Object)
        if ($v.Count) { $out.median[$b] = $v[[int][math]::Floor(($v.Count - 1) / 2)] }
    }
    if ($out.samples) { $out.badShare = @($Samples | Where-Object { $_.bad }).Count / $out.samples }
    foreach ($bo in $Boosts) {
        $start = [datetime]$bo.ts
        $later = @($Samples | Where-Object { [datetime]$_.ts -gt $start.AddSeconds(30) })
        $lasted = $null; $held = $null
        if ($bo.success -and $later.Count) {
            $fb = $later | Where-Object { $_.bad } | Select-Object -First 1
            if ($fb) { $lasted = ([datetime]$fb.ts - $start).TotalMinutes; $held = $false }
            else { $lasted = ([datetime]$later[-1].ts - $start).TotalMinutes; $held = $true }
        }
        $out.boosts += [pscustomobject]@{ ts = $bo.ts; trigger = $bo.trigger; success = $bo.success; before = $bo.before.GwMs; after = $bo.after.GwMs; lasted = $lasted; held = $held }
    }
    [pscustomobject]$out
}

function Invoke-Report([double]$Hours) {
    $since = (Get-Date).AddHours(-$Hours)
    $r = Get-Summary (Read-Log 'samples.jsonl' $since) (Read-Log 'boosts.jsonl' $since)
    Write-Host (T "最近 $Hours 小时" "Last $Hours h")
    if ($r.samples) {
        foreach ($b in $r.bands.Keys) { Write-Host ("  {0}: {1:N0}%  median {2} ms" -f $b, (100 * $r.bands[$b] / $r.samples), $r.median[$b]) }
        Write-Host ((T '  连接差的时间: ' '  slow: ') + ("{0:N0}%" -f (100 * $r.badShare)))
    } else { Write-Host (T '  没有监控数据' '  no watch data') }
    foreach ($b in $r.boosts) {
        $line = "  {0} [{1}] {2}ms -> {3}ms" -f $b.ts, $b.trigger, $b.before, $b.after
        if ($null -ne $b.lasted) { $line += (T ("  保持 {0:N1} 分钟" -f $b.lasted) ("  held {0:N1} min" -f $b.lasted)) }
        if (-not $b.success) { $line += '  x' }
        Write-Host $line
    }
    0
}

function Invoke-Main {
    switch ($Command) {
        'status' { exit (Invoke-Status) }
        'prefer-5g' { exit (Invoke-Prefer5G -Undo:$Undo) }
        'boost' { exit (Invoke-Boost -Tries $Tries -Force:$Force) }
        'watch' { Invoke-Watch -Interval $Interval -Auto:$Auto }
        'report' { exit (Invoke-Report -Hours $Hours) }
        'version' { Write-Host $Script:Version }
        default { Get-Help $PSCommandPath; exit 64 }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
