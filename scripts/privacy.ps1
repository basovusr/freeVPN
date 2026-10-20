<#
================================================================
  隐私加固  privacy.ps1
================================================================
  用途: 审计并减少"真实 IP 暴露"的面。

  常用:
    .\privacy.ps1 -Action Test       完整体检（出口IP / DNS / IPv6 / WebRTC）
    .\privacy.ps1 -Action On         开启严格模式（全部流量走 WARP，无直连退路）
    .\privacy.ps1 -Action Off        恢复分流模式（国内直连，速度快）
    .\privacy.ps1 -Action Browser    打印禁用 WebRTC 的浏览器启动命令
    .\privacy.ps1 -Action Status     查看当前模式
================================================================
#>
[CmdletBinding()]
param(
  [ValidateSet('Test', 'On', 'Off', 'Browser', 'Status')]
  [string]$Action = 'Test'
)

$ErrorActionPreference = 'Continue'
$Root     = Split-Path -Parent $PSScriptRoot
$ApiBase  = 'http://127.0.0.1:9090'
$MixedPort = 7890
$ProxyUrl = 'http://127.0.0.1:7890'
$StrictGroup = 'PRIVACY'

function Head($m) {
  Write-Host ''
  Write-Host ('=' * 64) -ForegroundColor DarkCyan
  Write-Host ('  ' + $m) -ForegroundColor Cyan
  Write-Host ('=' * 64) -ForegroundColor DarkCyan
}
function Ok($m)   { Write-Host ('  [OK]   ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('  [警告] ' + $m) -ForegroundColor Yellow }
function Bad($m)  { Write-Host ('  [风险] ' + $m) -ForegroundColor Red }
function Info($m) { Write-Host ('  [信息] ' + $m) -ForegroundColor Gray }

function Api-Get($path) {
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    return ($wc.DownloadString($ApiBase + $path) | ConvertFrom-Json)
  } catch { return $null }
}
function Api-Json($method, $path, $obj) {
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('Content-Type', 'application/json')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
    $null = $wc.UploadData($ApiBase + $path, $method, $bytes)
    return $true
  } catch { return $false }
}

function Get-ExitIp {
  param([switch]$Direct)
  $args = @('-s', '--max-time', '25')
  if (-not $Direct) { $args += @('-x', $ProxyUrl) }
  $args += 'https://www.cloudflare.com/cdn-cgi/trace'
  $t = (& curl.exe @args 2>$null | Out-String)
  $ip = ''; $warp = ''; $colo = ''
  if ($t -match 'ip=([^\r\n]+)')   { $ip = $Matches[1].Trim() }
  if ($t -match 'warp=([^\r\n]+)') { $warp = $Matches[1].Trim() }
  if ($t -match 'colo=([^\r\n]+)') { $colo = $Matches[1].Trim() }
  return @{ Ip = $ip; Warp = $warp; Colo = $colo; Raw = $t }
}

function Test-StunLeak {
  # 返回可达的 STUN 服务器列表；可达即意味着网页可用 WebRTC 拿到真实公网 IP
  $found = @()
  foreach ($s in @(
      @{ n = 'stun.cloudflare.com'; p = 3478 },
      @{ n = 'stun.l.google.com'; p = 19302 },
      @{ n = 'stun.miwifi.com'; p = 3478 }
    )) {
    try {
      $u = New-Object System.Net.Sockets.UdpClient
      $u.Client.ReceiveTimeout = 2500
      $u.Connect($s.n, $s.p)
      $pkt = New-Object byte[] 20
      $pkt[0] = 0x00; $pkt[1] = 0x01; $pkt[2] = 0x00; $pkt[3] = 0x00
      $pkt[4] = 0x21; $pkt[5] = 0x12; $pkt[6] = 0xA4; $pkt[7] = 0x42
      $rnd = [guid]::NewGuid().ToByteArray()
      for ($i = 0; $i -lt 12; $i++) { $pkt[8 + $i] = $rnd[$i] }
      $u.Send($pkt, 20) | Out-Null
      $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
      $resp = $u.Receive([ref]$ep)
      $u.Close()
      $leaked = ''
      if ($resp.Length -ge 32) {
        for ($i = 20; $i -lt $resp.Length - 8; $i++) {
          if ($resp[$i] -eq 0x00 -and $resp[$i + 1] -eq 0x20 -and $resp[$i + 5] -eq 0x01) {
            $a1 = [int]$resp[$i + 8] -bxor 0x21
            $a2 = [int]$resp[$i + 9] -bxor 0x12
            $a3 = [int]$resp[$i + 10] -bxor 0xA4
            $a4 = [int]$resp[$i + 11] -bxor 0x42
            $leaked = "$a1.$a2.$a3.$a4"
            break
          }
        }
      }
      $found += [pscustomobject]@{ Server = $s.n; Leaked = $leaked }
    } catch { }
  }
  return $found
}

function Get-Mode { $c = Api-Get '/configs'; if ($c) { return $c.mode }; return '' }

# ============================ Test ============================
function Action-Test {
  Head '隐私体检'

  $running = [bool](Get-NetTCPConnection -LocalPort $MixedPort -State Listen -ErrorAction SilentlyContinue)
  if (-not $running) { Bad ('代理未运行（端口 ' + $MixedPort + ' 无监听）'); Info '先运行 scripts\ctl.ps1 -Action Start 或双击 启动代理.bat'; return }

  $mode = Get-Mode
  Info ('当前模式: ' + $mode)
  if ($mode -eq 'rule') {
    Warn '分流模式: 国内网站走真实 IP（可见你的真实身份）'
  } else {
    Ok '全隧道模式: 所有流量经 WARP'
  }

  # ---- 1. 出口 IP ----
  $directIp = Get-ExitIp -Direct
  $proxyIp  = Get-ExitIp
  Write-Host ''
  Write-Host '  ── 出口 IP ──' -ForegroundColor DarkGray
  Info ('直连（真实）: ' + $directIp.Ip)
  Info ('经代理      : ' + $proxyIp.Ip + '    warp=' + $proxyIp.Warp + '  colo=' + $proxyIp.Colo)
  if ($proxyIp.Ip -and $directIp.Ip -and $proxyIp.Ip -ne $directIp.Ip) {
    Ok '对外 IP 已替换为 Cloudflare 出口'
  } else {
    Bad '对外 IP 与真实 IP 相同 —— 代理没有生效'
  }

  # ---- 2. IPv6 ----
  $v6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(::1|fe80|fc|fd)' -and $_.IPAddress -notlike '::*' }
  Write-Host ''
  Write-Host '  ── IPv6 ──' -ForegroundColor DarkGray
  if ($v6) { Bad ('检测到公网 IPv6: ' + (($v6 | ForEach-Object { $_.IPAddress }) -join ', ')); Info 'IPv6 可能绕过代理直连，建议在网卡上禁用' }
  else { Ok '无公网 IPv6，不存在 IPv6 绕过' }

  # ---- 3. WebRTC / STUN（最关键）----
  Write-Host ''
  Write-Host '  ── WebRTC 泄漏（最容易被追踪的渠道）──' -ForegroundColor DarkGray
  $stun = Test-StunLeak
  if ($stun.Count -eq 0) {
    Ok 'STUN 不可达，网页无法通过 WebRTC 拿到真实 IP'
  } else {
    foreach ($s in $stun) {
      Bad ('STUN 可达: ' + $s.Server + '  -> 泄漏真实 IP ' + $s.Leaked)
    }
    Warn 'WebRTC 走 UDP，不经过 HTTP 代理 —— 代理无法拦截'
    Info '处理办法（任选一种）:'
    Info '   1. 运行 .\privacy.ps1 -Action Browser 用带 WebRTC 限制的浏览器启动命令'
    Info '   2. 浏览器设置里禁用 WebRTC（Edge: edge://flags/#disable-webrtc）'
    Info '   3. 用防火墙阻挡本机出站 UDP 3478/19302'
  }

  # ---- 4. 直连退路检查 ----
  Write-Host ''
  Write-Host '  ── 直连退路（失败时是否会悄悄暴露真实 IP）──' -ForegroundColor DarkGray
  $px = Api-Get '/proxies'
  if ($px) {
    if ($mode -eq 'global') {
      # 全隧道模式只看 GLOBAL 实际指向的那条路径, 其它组不生效
      $g = $px.proxies.GLOBAL
      $target = $g.now
      $tg = $px.proxies.$target
      $reach = @()
      if ($tg) { $reach = @($tg.all) } else { $reach = @($target) }
      if ($reach -contains 'DIRECT') {
        Bad ('GLOBAL 指向 ' + $target + ', 其中仍含 DIRECT 退路')
        Info 'WARP 挂掉时会静默退回真实 IP; 建议指向 PRIVACY 组'
      } elseif ($target -eq 'DIRECT') {
        Bad 'GLOBAL 当前指向 DIRECT —— 全部流量走真实 IP'
      } else {
        Ok ('当前路径 ' + $target + ' 不含 DIRECT 退路, 失败时会直接断网而不是泄漏')
      }
    } else {
      $risky = @()
      foreach ($p in $px.proxies.PSObject.Properties) {
        if ($p.Value.type -in @('Fallback', 'URLTest', 'Selector')) {
          if ($p.Value.all -contains 'DIRECT') { $risky += $p.Name }
        }
      }
      if ($risky.Count -gt 0) {
        Bad ('以下策略组含 DIRECT 退路: ' + ($risky -join ', '))
        Info 'WARP 挂掉时这些组会静默退回真实 IP。严格模式会避开它们。'
      } else {
        Ok '策略组中无 DIRECT 退路'
      }
    }
  }

  Head '结论'
  $score = 0
  if ($proxyIp.Ip -and $proxyIp.Ip -ne $directIp.Ip) { $score += 2 }
  if (-not $v6) { $score += 1 }
  if ($stun.Count -eq 0) { $score += 2 }
  if ($mode -ne 'rule') { $score += 1 }
  Info ('当前隐私得分: ' + $score + ' / 6')
  Write-Host ''
  if ($stun.Count -gt 0) {
    Bad '最大问题: WebRTC 可直接暴露真实 IP，与代理是否开启无关'
  }
  if ($mode -eq 'rule') {
    Warn '分流模式下国内网站仍能看到真实 IP；需要完全隐藏请运行 -Action On'
  }
  Info '提示: 换 IP 不等于匿名。登录的账号、Cookie、浏览器指纹都会识别到你。'
  Info '      WARP 是"改善路由"的服务，不是匿名服务，Cloudflare 仍可关联你的真实身份。'
}

# ============================ On ============================
function Action-On {
  Head '开启严格模式（全部流量经 WARP，无直连退路）'
  if (-not (Get-NetTCPConnection -LocalPort $MixedPort -State Listen -ErrorAction SilentlyContinue)) {
    Bad '代理未运行'; return
  }
  $px = Api-Get '/proxies'
  if (-not $px) { Bad '控制接口不可用'; return }
  if (-not ($px.proxies.PSObject.Properties.Name -contains $StrictGroup)) {
    Bad ('找不到策略组 ' + $StrictGroup)
    Info '请先运行 scripts\ctl.ps1 -Action Start 让它加载最新配置'
    return
  }
  # 先把 GLOBAL 指向只含 WARP 的严格组，再切 global 模式
  if (-not (Api-Json 'PUT' ('/proxies/GLOBAL') @{ name = $StrictGroup })) {
    Bad '无法设置 GLOBAL 指向严格组'; return
  }
  if (-not (Api-Json 'PATCH' '/configs' @{ mode = 'global' })) {
    Bad '无法切换到 global 模式'; return
  }
  Start-Sleep -Milliseconds 500
  Ok ('已切换到严格模式，GLOBAL -> ' + $StrictGroup)
  Warn '代价: 国内网站也会绕道海外，百度从 0.06 秒变成 2 秒左右'
  Info '恢复: .\privacy.ps1 -Action Off'
  Write-Host ''
  Info '别忘了 WebRTC —— 它是代理拦不住的，见 -Action Test 的提示'
}

# ============================ Off ============================
function Action-Off {
  Head '恢复分流模式'
  if (Api-Json 'PATCH' '/configs' @{ mode = 'rule' }) { Ok '已切回 rule 模式（国内直连，速度恢复）' }
  else { Bad '切换失败（代理可能未运行）' }
  Info '注意: 分流模式下国内网站能看到你的真实 IP'
}

# ============================ Browser ============================
function Action-Browser {
  Head '浏览器 WebRTC 加固'
  Info 'WebRTC 用 UDP 直连 STUN，不经过 HTTP 代理，代理无法拦截。'
  Info '下面的启动参数会禁止浏览器通过非代理 UDP 发送 WebRTC 流量。'
  Write-Host ''
  Write-Host '  # Edge —— 先完全退出浏览器再执行:' -ForegroundColor Green
  Write-Host '  & "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" `' -ForegroundColor Green
  Write-Host '      --force-webrtc-ip-handling-policy=disable_non_proxied_udp' -ForegroundColor Green
  Write-Host ''
  Write-Host '  # Chrome:' -ForegroundColor Green
  Write-Host '  & "C:\Program Files\Google\Chrome\Application\chrome.exe" `' -ForegroundColor Green
  Write-Host '      --force-webrtc-ip-handling-policy=disable_non_proxied_udp' -ForegroundColor Green
  Write-Host ''
  Info '更彻底的做法（推荐）: 在浏览器设置界面禁用 WebRTC'
  Info '   Edge: 地址栏输入 edge://flags/#disable-webrtc  设为 Enabled 并重启'
  Info '   Chrome: chrome://flags/#disable-webrtc'
  Info '或者用扩展 "WebRTC Leak Prevent"（Policy: disable_non_proxied_udp）'
  Write-Host ''
  Warn '另外: 浏览器若启用 QUIC/HTTP3，部分流量可能走 UDP 绕过代理'
  Info '  可在 edge://flags/#enable-quic / chrome://flags/#enable-quic 关闭'
}

# ============================ Status ============================
function Action-Status {
  Head '当前隐私模式'
  if (-not (Get-NetTCPConnection -LocalPort $MixedPort -State Listen -ErrorAction SilentlyContinue)) {
    Bad '代理未运行'; return
  }
  $mode = Get-Mode
  Info ('模式: ' + $mode)
  $px = Api-Get '/proxies'
  if ($px -and $px.proxies.GLOBAL) { Info ('GLOBAL 指向: ' + $px.proxies.GLOBAL.now) }
  if ($mode -eq 'global') { Ok '严格模式：所有流量经 WARP' } else { Warn '分流模式：国内直连，真实 IP 对国内站点可见' }
}

switch ($Action) {
  'Test'    { Action-Test }
  'On'      { Action-On }
  'Off'     { Action-Off }
  'Browser' { Action-Browser }
  'Status'  { Action-Status }
}
