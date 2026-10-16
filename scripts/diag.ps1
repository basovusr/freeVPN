<#
================================================================
  端到端诊断  diag.ps1
================================================================
  一键回答四个问题:
    1. 修复前: 哪些站点被墙 / DNS 是否被投毒
    2. 本地代理是否在正常工作
    3. 分流是否正确 (国内直连 / 国外走代理)
    4. DNS 防污染是否生效
  用法:  .\diag.ps1
         .\diag.ps1 -PacCheck     额外校验 PAC 文件规则
================================================================
#>
[CmdletBinding()]
param([switch]$PacCheck)

$ErrorActionPreference = 'Continue'
$Root    = Split-Path -Parent $PSScriptRoot
$Mixed   = 7890
$DnsPort = 1053
$PacFile = Join-Path $Root 'config\browser.pac'

function Section($t) {
  Write-Host ''
  Write-Host ('=' * 64) -ForegroundColor DarkCyan
  Write-Host ('  ' + $t) -ForegroundColor Cyan
  Write-Host ('=' * 64) -ForegroundColor DarkCyan
}
function Line($name, $val, $color) {
  if (-not $color) { $color = 'Gray' }
  Write-Host ('  {0,-30} {1}' -f $name, $val) -ForegroundColor $color
}

Section '1. 直连基线（不使用任何代理）'
Line '检测时间' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$sysP = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable
Line '系统代理' $(if ($sysP -eq 1) { '已开启(可能干扰本诊断)' } else { '未开启' }) $(if ($sysP -eq 1) { 'Yellow' } else { 'Gray' })

foreach ($h in @('www.google.com', 'x.com', 'www.baidu.com')) {
  $ips = ''
  try {
    $r = Resolve-DnsName -Name $h -Type A -Server 114.114.114.114 -DnsOnly -ErrorAction Stop |
         Where-Object { $_.IPAddress -and $_.Type -eq 'A' }
    $ips = ($r | Select-Object -First 2 -ExpandProperty IPAddress) -join ', '
  } catch { $ips = '解析失败' }
  $susp = ''
  if ($h -eq 'www.google.com' -and $ips -match '^(157\.240\.|31\.13\.|185\.45\.|2001::|127\.0\.0\.)') {
    $susp = '  <== DNS 投毒'
  }
  Line ('  ' + $h + ' 解析') ($ips + $susp) $(if ($susp) { 'Red' } else { 'Gray' })
}

Write-Host ''
Write-Host '  直连可达性:' -ForegroundColor DarkGray
foreach ($t in @(
    @{ n = 'Google'; u = 'https://www.google.com/generate_204' },
    @{ n = 'X'; u = 'https://x.com/' },
    @{ n = '百度'; u = 'https://www.baidu.com/' }
  )) {
  $r = & curl.exe -s -o NUL --noproxy '*' -w '%{http_code}|%{time_total}' --max-time 6 $t.u 2>$null
  $p = $r -split '\|'
  $ok = $p[0] -in @('200', '204', '301', '302')
  Line ('  ' + $t.n) ('HTTP ' + $p[0] + '  ' + $p[1] + 's') $(if ($ok) { 'Green' } else { 'Red' })
}

Section '2. 本地代理状态'
$listen = Get-NetTCPConnection -LocalPort $Mixed -State Listen -ErrorAction SilentlyContinue
if ($listen) {
  Line ('端口 ' + $Mixed) '监听中' 'Green'
  $proc = Get-Process -Id $listen[0].OwningProcess -ErrorAction SilentlyContinue
  if ($proc) { Line '进程' ($proc.ProcessName + ' (PID ' + $proc.Id + ')') 'Gray' }
  try {
    $cfg = Invoke-RestMethod ('http://127.0.0.1:9090/configs') -TimeoutSec 5
    Line '内核模式' $cfg.mode 'Gray'
  } catch { Line '控制接口 9090' '无响应' 'Yellow' }
} else {
  Line ('端口 ' + $Mixed) '未监听 —— 代理没在跑' 'Red'
  Write-Host '  请先执行: scripts\ctl.ps1 -Action Start' -ForegroundColor Yellow
}

Section '3. 分流验证（经代理端口）'
if ($listen) {
  $px = 'http://127.0.0.1:' + $Mixed
  foreach ($t in @(
      @{ n = '百度'; d = '应命中 GEOSITE,cn -> DIRECT' },
      @{ n = 'Google'; d = '应命中 GEOSITE,gfw -> PROXY' },
      @{ n = 'X'; d = '应命中 GEOSITE,gfw -> PROXY' },
      @{ n = 'GitHub'; d = '应命中 GEOSITE,github -> PROXY' }
    )) {
    $url = switch ($t.n) {
      '百度' { 'https://www.baidu.com/' }
      'Google' { 'https://www.google.com/generate_204' }
      'X' { 'https://x.com/' }
      'GitHub' { 'https://github.com/' }
    }
    $r = & curl.exe -s -o NUL -x $px -w '%{http_code}|%{time_total}' --max-time 20 $url 2>$null
    $p = $r -split '\|'
    $ok = $p[0] -in @('200', '204', '301', '302')
    $verdict = '不通'
    if ($ok) { $verdict = '通' }
    Line ('  ' + $t.n) ('HTTP ' + $p[0] + '  ' + $p[1] + 's  ' + $verdict) $(if ($ok) { 'Green' } else { 'Red' })
    Write-Host ('      ' + $t.d) -ForegroundColor DarkGray
  }

  Write-Host ''
  Write-Host '  最近路由决策 (内核日志):' -ForegroundColor DarkGray
  $lf = Join-Path $Root 'logs\mihomo.log'
  if (Test-Path $lf) {
    Get-Content $lf -Encoding UTF8 -Tail 300 |
      Select-String -Pattern 'using (DIRECT|PROXY|GLOBAL|REJECT)' |
      Select-Object -Last 8 | ForEach-Object {
        $l = $_.Line -replace '^time="[^"]+" level=\w+ msg="', '' -replace '"$', ''
        Write-Host ('    ' + $l) -ForegroundColor DarkGray
      }
  }
}

Section '4. DNS 防污染验证'
$dnsListen = Get-NetTCPConnection -LocalPort $DnsPort -State Listen -ErrorAction SilentlyContinue
if ($dnsListen) {
  Line ('内建 DNS 端口 ' + $DnsPort) '监听中' 'Green'
  foreach ($h in @('www.google.com', 'x.com')) {
    try {
      $r = Resolve-DnsName -Name $h -Type A -Server 127.0.0.1 -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress -and $_.Type -eq 'A' }
      $ips = ($r | Select-Object -First 2 -ExpandProperty IPAddress) -join ', '
      $isFake = $ips -match '^198\.18\.'
      Line ('  ' + $h) ($ips + $(if ($isFake) { '  (fake-ip 生效)' } else { '' })) $(if ($isFake) { 'Green' } else { 'Yellow' })
    } catch {
      Line ('  ' + $h) '查询失败(无上游时正常)' 'Yellow'
    }
  }
} else {
  Line ('内建 DNS 端口 ' + $DnsPort) '未监听' 'Yellow'
}

if ($PacCheck) {
  Section '5. PAC 文件规则校验'
  if (Test-Path $PacFile) {
    $pac = [System.IO.File]::ReadAllText($PacFile, [System.Text.Encoding]::UTF8)
    Line 'PAC 文件' ((Get-Item $PacFile).Length.ToString() + ' 字节') 'Green'
    $pc = ([regex]::Matches($pac, '(?m)^\s{2}"[^"]+"')).Count
    Line '代理域名条数' $pc 'Gray'
    foreach ($d in @('google.com', 'x.com', 'github.com', 'openai.com', 'baidu.com')) {
      $inProxy = $pac -match ('"' + [regex]::Escape($d) + '"')
      Line ('  含 ' + $d) $(if ($inProxy) { '是' } else { '否' }) 'Gray'
    }
  } else {
    Line 'PAC 文件' '不存在' 'Red'
  }
}

Section '结论建议'
if (-not $listen) {
  Write-Host '  * 代理未运行 -> 执行 scripts\ctl.ps1 -Action Start' -ForegroundColor Yellow
} else {
  $hasNode = $false
  try {
    $px2 = Invoke-RestMethod 'http://127.0.0.1:9090/proxies' -TimeoutSec 5
    $builtin = @('Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay', 'Direct', 'Reject', 'RejectDrop', 'Pass', 'PassRule', 'Compatible', 'RejectDrop')
    $real = @($px2.proxies.PSObject.Properties | Where-Object { $_.Value -and $_.Value.type -and ($builtin -notcontains $_.Value.type) })
    if ($real.Count -gt 0) { $hasNode = $true }
  } catch { }
  if (-not $hasNode) {
    Write-Host '  * 没有上游节点 -> 代理无法出境，这是 Google/X 打不开的原因' -ForegroundColor Red
    Write-Host '    导入命令: scripts\ctl.ps1 -Action Import -Source "<订阅URL>"' -ForegroundColor Yellow
    Write-Host '    详见: README.md 「第二步: 准备上游」' -ForegroundColor Yellow
  } else {
    Write-Host '  * 已配置上游节点。若 Google/X 仍不通，用下面命令换节点试试:' -ForegroundColor Yellow
    Write-Host '      scripts\ctl.ps1 -Action Status' -ForegroundColor DarkGray
    Write-Host '      scripts\ctl.ps1 -Action Switch -Node "<节点名>"' -ForegroundColor DarkGray
  }
}
Write-Host ''
