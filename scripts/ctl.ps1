<#
================================================================
  本地代理控制台  ctl.ps1
  内核: Mihomo Meta    仅监听 127.0.0.1，不对局域网暴露
================================================================
  常用命令:
    .\ctl.ps1 -Action Check                      体检：内核/进程/端口/上游
    .\ctl.ps1 -Action Import -Source "<订阅URL>"  导入上游(自动生成运行时配置)
    .\ctl.ps1 -Action Start                       启动代理
    .\ctl.ps1 -Action Status                      查看状态与节点延迟
    .\ctl.ps1 -Action Switch -Node "香港01"       切换节点
    .\ctl.ps1 -Action Stop                        停止代理
    .\ctl.ps1 -Action Env                         打印命令行工具代理环境变量
    .\ctl.ps1 -Action Browser                     打印浏览器走代理的启动命令
    .\ctl.ps1 -Action Update                      升级内核
================================================================
#>
[CmdletBinding()]
param(
  [ValidateSet('Check','Import','Start','Stop','Restart','Status','Switch','Env','Browser','Update','Test','WarpInstall','WarpRegister','WarpStart','WarpStop','WarpStatus')]
  [string]$Action = 'Check',
  [string]$Source,
  [string]$Group = 'PROXY',
  [string]$Node,
  [switch]$UseProvider,
  [int]$TimeoutSec = 45
)

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot
$BinDir  = Join-Path $Root 'bin'
$CfgDir  = Join-Path $Root 'config'
$LogDir  = Join-Path $Root 'logs'
$Core    = Join-Path $BinDir 'mihomo.exe'
$BaseCfg = Join-Path $CfgDir 'config.yaml'
$RunCfg  = Join-Path $CfgDir 'config.runtime.yaml'
$LogFile = Join-Path $LogDir 'mihomo.log'
$ErrLog  = Join-Path $LogDir 'mihomo.err.log'
$PidFile = Join-Path $LogDir 'mihomo.pid'
$PacFile = Join-Path $CfgDir 'browser.pac'

$MixedPort = 7890
$CtrlPort  = 9090
$ApiBase   = 'http://127.0.0.1:' + $CtrlPort
$Mirror    = 'https://ghproxy.net'
$TaskName  = 'DSH-LocalProxy'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 隧道连续运行超过这个小时数就自动重启。
# 实测: 隧道在连续运行 20.8 小时时失效, 且自带的自动重连只重建了 QUIC
# 连接(日志写 Connected to MASQUE server), 数据面仍然是死的。
# 所以阈值取 8 小时, 远早于实测失效点。
$WarpMaxHours = 8

function Write-File($Path, $Text) { [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom) }
function Read-File($Path) { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function Head($m) {
  Write-Host ''
  Write-Host ('=' * 62) -ForegroundColor DarkCyan
  Write-Host ('  ' + $m) -ForegroundColor Cyan
  Write-Host ('=' * 62) -ForegroundColor DarkCyan
}
function Ok($m)   { Write-Host ('  [OK]   ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('  [警告] ' + $m) -ForegroundColor Yellow }
function Err($m)  { Write-Host ('  [失败] ' + $m) -ForegroundColor Red }
function Info($m) { Write-Host ('  [信息] ' + $m) -ForegroundColor Gray }
function Say($m, $c) { Write-Host $m -ForegroundColor $c }

function Get-LatestTag {
  try {
    $raw = (& curl.exe -s --max-time 15 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest' 2>$null | Out-String)
    if ($raw -match '"tag_name"\s*:\s*"([^"]+)"') { return $Matches[1] }
  } catch { }
  return $null
}

function Invoke-CoreDownload {
  $tag = Get-LatestTag
  if (-not $tag) { Err '无法获取最新版本号 (api.github.com 不可达)'; return $false }
  $asset = 'mihomo-windows-amd64-' + $tag + '.zip'
  $url = $Mirror + '/https://github.com/MetaCubeX/mihomo/releases/download/' + $tag + '/' + $asset
  $zip = Join-Path $BinDir $asset
  Info ('下载 ' + $asset + ' (经镜像)...')
  $code = (& curl.exe -sL --max-time 600 --retry 2 -o $zip -w '%{http_code}' $url 2>&1 | Select-Object -Last 1)
  if ($code -ne '200' -or -not (Test-Path $zip)) { Err ('下载失败 HTTP=' + $code); return $false }
  $magic = [System.IO.File]::ReadAllBytes($zip)[0..1]
  if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) { Err '下载内容不是 ZIP (可能被劫持)'; return $false }
  Expand-Archive -Path $zip -DestinationPath $BinDir -Force
  $exe = Get-ChildItem $BinDir -Filter 'mihomo-windows-amd64*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($exe) { Move-Item $exe.FullName $Core -Force }
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Write-File (Join-Path $BinDir 'VERSION.txt') $tag
  Ok ('内核已安装: ' + $tag)
  return (Test-Path $Core)
}

function Ensure-Core {
  if (Test-Path $Core) { return $true }
  Warn '内核不存在，尝试下载...'
  return (Invoke-CoreDownload)
}

function Ensure-GeoData {
  $need = @()
  foreach ($f in @('geoip.dat', 'geosite.dat', 'geoip.metadb')) {
    $p = Join-Path $BinDir $f
    if (-not (Test-Path $p) -or (Get-Item $p).Length -lt 100000) { $need += $f }
  }
  if ($need.Count -eq 0) { return $true }
  Info ('补下数据文件: ' + ($need -join ', '))
  $base = $Mirror + '/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest'
  foreach ($f in $need) {
    $out = Join-Path $BinDir $f
    & curl.exe -sL --max-time 600 --retry 2 -o $out ($base + '/' + $f) 2>$null | Out-Null
    if (-not (Test-Path $out)) { Err ('下载 ' + $f + ' 失败'); return $false }
  }
  Ok '数据文件就绪'
  return $true
}

# PowerShell 5.1 on zh-CN decodes JSON responses with the ANSI codepage,
# which corrupts Chinese node/group names. Read raw bytes and decode UTF-8.
function Action-ApiGet {
  param([string]$Path)
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $raw = $wc.DownloadString($ApiBase + $Path)
    return ($raw | ConvertFrom-Json)
  } catch { return $null }
}
function Invoke-Api {
  param([string]$Method = 'GET', [string]$Path, $Body)
  if ($Method -eq 'GET') { return (Action-ApiGet -Path $Path) }
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('Content-Type', 'application/json')
    if ($Body) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
      $resp = $wc.UploadData($ApiBase + $Path, $Method, $bytes)
    } else {
      $resp = $wc.UploadData($ApiBase + $Path, $Method, @())
    }
    if ($resp -and $resp.Length -gt 0) {
      return ([System.Text.Encoding]::UTF8.GetString($resp) | ConvertFrom-Json)
    }
    return $null
  } catch { return $null }
}

function Test-IsRunning {
  $c = Get-NetTCPConnection -LocalPort $MixedPort -State Listen -ErrorAction SilentlyContinue
  return [bool]$c
}

function Get-RunConfig {
  if (Test-Path $RunCfg) { return $RunCfg }
  return $BaseCfg
}

function Test-Config([string]$Path) {
  $out = (& $Core -t -d $BinDir -f $Path 2>&1 | Out-String)
  return @{ Ok = ($LASTEXITCODE -eq 0); Output = $out.Trim() }
}

function Test-Egress {
  $targets = @(
    @{ n = 'Google';      u = 'https://www.google.com/generate_204' },
    @{ n = 'X (推特)';    u = 'https://x.com/' },
    @{ n = 'GitHub';      u = 'https://github.com/' },
    @{ n = '百度 (直连)'; u = 'https://www.baidu.com/' }
  )
  Write-Host ''
  Write-Host ('  {0,-14} {1,-14} {2,-10} {3}' -f '目标', 'HTTP 状态', '耗时', '判定') -ForegroundColor Cyan
  Write-Host ('  ' + ('-' * 52)) -ForegroundColor DarkGray
  $proxy = 'http://127.0.0.1:' + $MixedPort
  foreach ($t in $targets) {
    $res = (& curl.exe -s -o NUL -x $proxy -w '%{http_code}|%{time_total}' --max-time 40 $t.u 2>$null)
    $parts = ($res -split '\|')
    $code = $parts[0]
    $secs = $parts[1]
    $okCodes = @('200', '201', '204', '301', '302', '303', '307', '308')
    $verdict = '不通'
    if ($okCodes -contains $code) { $verdict = '通' }
    $color = 'Red'
    if ($verdict -eq '通') { $color = 'Green' }
    $secsTxt = $secs + 's'
    Write-Host ('  {0,-14} {1,-14} {2,-10} {3}' -f $t.n, ('HTTP ' + $code), $secsTxt, $verdict) -ForegroundColor $color
  }
  Write-Host ''
  Info '以上为「通过本地代理端口」的测试结果，「通」代表整条链路可用。'
}

function Action-Import {
  Head '导入上游节点'
  if (-not (Ensure-Core)) { Err '内核缺失，无法继续'; return }

  if (-not $Source) {
    $clip = Get-Clipboard -Raw -ErrorAction SilentlyContinue
    if ($clip -and ($clip.Trim() -match '^(https?://|proxies:|port:|mixed-port:)')) {
      $Source = $clip.Trim()
      Info '已从剪贴板读取上游内容'
    }
  }
  if (-not $Source) { Err '请用 -Source "<订阅URL 或 本地yaml路径>" 指定上游'; return }

  $subText = $null
  if (Test-Path $Source) {
    $subText = Read-File (Resolve-Path $Source).Path
    Info ('读取本地文件: ' + $Source)
  } else {
    Info ('拉取订阅: ' + $Source)
    $raw = (& curl.exe -sL --max-time 60 -A 'clash-verge/v2.0' -w '@@HTTP:%{http_code}' $Source 2>&1 | Out-String)
    $m = [regex]::Match($raw, '@@HTTP:(\d+)\s*$')
    $hcode = ''
    if ($m.Success) { $hcode = $m.Groups[1].Value }
    if ($hcode -ne '200') {
      Err ('订阅拉取失败 (HTTP=' + $hcode + ')')
      Err '很多机场的订阅域名本身被墙，需要先有代理才能拉取。'
      Err '替代做法: 用能上网的设备下载订阅 yaml，再用 -Source <文件路径> 导入。'
      return
    }
    $subText = $raw.Substring(0, $m.Index)
  }
  if (-not $subText -or $subText.Length -lt 20) { Err '订阅内容为空'; return }

  if ($subText -notmatch '(?m)^\s*(proxies|proxy-providers)\s*:') {
    $cand = ($subText -replace '\s', '')
    try {
      $dec = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cand))
      if ($dec -match '(?m)^\s*(proxies|proxy-providers)\s*:') {
        $subText = $dec
        Info '检测到 base64 订阅，已解码'
      }
    } catch { }
  }
  if ($subText -notmatch '(?m)^\s*(proxies|proxy-providers)\s*:') {
    Err '订阅中找不到 proxies: 段，可能不是 Clash 格式'
    return
  }

  $subDir = Join-Path $Root 'subscriptions'
  if (-not (Test-Path $subDir)) { New-Item -ItemType Directory -Force -Path $subDir | Out-Null }
  Write-File (Join-Path $subDir 'last-subscription.yaml') $subText
  Info '原始订阅已存档: subscriptions\last-subscription.yaml'

  $mProx = [regex]::Match($subText, '(?ms)^proxies\s*:\s*(.*?)(?=^\S|\z)')
  $proxBlock = 'proxies: []'
  if ($mProx.Success) { $proxBlock = $mProx.Value.TrimEnd() }

  $names = New-Object System.Collections.Generic.List[string]
  if ($mProx.Success) {
    foreach ($line in ($mProx.Value -split "`r?`n")) {
      if ($line -match '^\s{0,4}-\s+name\s*:\s*[''"]?(.+?)[''"]?\s*$') { $names.Add($Matches[1]) }
      elseif ($line -match '^\s{0,4}-\s*\{\s*name\s*:\s*[''"]?(.+?)[''"]?\s*,') { $names.Add($Matches[1]) }
    }
  }
  $uniq = @($names | Select-Object -Unique)
  Info ('解析到 ' + $uniq.Count + ' 个节点')

  $useProv = ($UseProvider -and $Source -match '^https?://')

  $pool = @()
  if ($useProv) { $pool += '自动选择' }
  $pool += $uniq
  if ($pool.Count -eq 0) { $pool = @('DIRECT') }

  $groupNames = @('PROXY', '自动选择', '故障转移', '手动选择', 'AI', '广告拦截')
  $nodeList = @($pool | Where-Object { $groupNames -notcontains $_ })
  if ($nodeList.Count -eq 0) { $nodeList = @('DIRECT') }

  $nodeLiteral = (($nodeList | ForEach-Object { '"' + $_ + '"' }) -join ', ')
  $firstNode = $nodeList[0]

  $ga = @()
  $ga += 'proxy-groups:'
  $ga += '  - name: PROXY'
  $ga += '    type: select'
  $ga += '    proxies: [' + $nodeLiteral + ', "自动选择", "故障转移", "手动选择", DIRECT]'
  $ga += ''
  $ga += '  - name: 自动选择'
  $ga += '    type: url-test'
  $ga += '    url: https://www.gstatic.com/generate_204'
  $ga += '    interval: 300'
  $ga += '    tolerance: 50'
  $ga += '    proxies: [' + $nodeLiteral + ']'
  $ga += ''
  $ga += '  - name: 故障转移'
  $ga += '    type: fallback'
  $ga += '    url: https://www.gstatic.com/generate_204'
  $ga += '    interval: 300'
  $ga += '    proxies: [' + $nodeLiteral + ']'
  $ga += ''
  $ga += '  - name: 手动选择'
  $ga += '    type: select'
  $ga += '    proxies: [' + $nodeLiteral + ']'
  $ga += ''
  $ga += '  - name: AI'
  $ga += '    type: select'
  $ga += '    proxies: ["自动选择", "手动选择", PROXY, "' + $firstNode + '", DIRECT]'
  $ga += ''
  $ga += '  - name: 广告拦截'
  $ga += '    type: select'
  $ga += '    proxies: [REJECT, DIRECT]'
  $groupsYaml = ($ga -join "`r`n")

  $base = Read-File $BaseCfg
  $new = [regex]::Replace($base, '(?ms)^proxies\s*:.*?(?=^\S|\z)', ($proxBlock + "`r`n`r`n"))

  if ($useProv) {
    $pa = @()
    $pa += 'proxy-providers:'
    $pa += '  SUB:'
    $pa += '    type: http'
    $pa += '    url: "' + $Source + '"'
    $pa += '    interval: 3600'
    $pa += '    path: ./providers/SUB.yaml'
    $pa += '    health-check: { enable: true, url: https://www.gstatic.com/generate_204, interval: 300 }'
    $provYaml = ($pa -join "`r`n")
    $new = [regex]::Replace($new, '(?ms)^proxy-providers\s*:.*?(?=^\S|\z)', ($provYaml + "`r`n"))
  }

  if ($new -notmatch '(?ms)^proxy-groups\s*:') { Err '基础配置缺少 proxy-groups 段'; return }
  $new = [regex]::Replace($new, '(?ms)^proxy-groups\s*:.*?(?=^rules\s*:)', ($groupsYaml + "`r`n`r`n"))
  Write-File $RunCfg $new
  Ok '运行时配置已生成: config\config.runtime.yaml'

  Head '校验配置'
  $t = Test-Config $RunCfg
  if ($t.Ok) {
    Ok '配置校验通过'
  } else {
    Err '配置校验失败:'
    Write-Host $t.Output -ForegroundColor DarkYellow
    return
  }

  if (Test-IsRunning) {
    $body = @{ path = $RunCfg } | ConvertTo-Json -Compress
    Invoke-Api -Method PUT -Path '/configs?force=true' -Body $body | Out-Null
    Ok '已热重载到运行中的内核 (无需重启)'
  } else {
    Info '下一步: .\ctl.ps1 -Action Start'
  }
}

function Action-Start {
  Head '启动本地代理'
  if (-not (Ensure-Core)) { Err '内核缺失'; return }
  if (-not (Ensure-GeoData)) { return }
  if (Test-IsRunning) { Warn ('端口 ' + $MixedPort + ' 已在监听'); Action-Status; return }

  $cfg = Get-RunConfig
  $t = Test-Config $cfg
  if (-not $t.Ok) { Err ('配置校验失败:' + "`n" + $t.Output); return }
  Ok '配置校验通过'

  if ($cfg -eq $BaseCfg) {
    Warn '尚未导入上游节点 —— 分流规则会生效，但没有出境能力'
    Warn '导入命令: .\ctl.ps1 -Action Import -Source "<订阅URL>"'
  }

  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

  $useTask = $false
  try {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
      Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
      $useTask = $true
      Ok ('已通过计划任务启动 (' + $TaskName + ')')
    }
  } catch { $useTask = $false }

  if (-not $useTask) {
    $args = @('-d', $BinDir, '-f', $cfg)
    $p = Start-Process -FilePath $Core -ArgumentList $args -WorkingDirectory $BinDir `
         -WindowStyle Hidden -PassThru `
         -RedirectStandardOutput $LogFile -RedirectStandardError $ErrLog
    Write-File $PidFile ([string]$p.Id)
    Ok ('内核已启动 (PID ' + $p.Id + ')')
    Info ('日志: ' + $LogFile)
  }

  # auto-start WARP when config references a WARP node but tunnel is down
  $rc = Get-RunConfig
  $rcTxt = ''
  if (Test-Path $rc) { $rcTxt = Read-File $rc }
  if ($rcTxt -match 'WARP-') {
    # 自包含：没装就装、没注册就注册、没跑就跑
    Invoke-EnsureWarp | Out-Null
  }

  Info ('等待端口 ' + $MixedPort + ' 就绪 (最多 ' + $TimeoutSec + ' 秒)...')
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-IsRunning) { break }
    Start-Sleep -Milliseconds 400
  }
  if (-not (Test-IsRunning)) {
    Err '端口未就绪，启动失败。日志尾部:'
    foreach ($lf in @($LogFile, $ErrLog)) {
      if (Test-Path $lf) {
        Write-Host ('  --- ' + $lf) -ForegroundColor DarkGray
        Get-Content $lf -Tail 20 -Encoding UTF8 | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkYellow }
      }
    }
    return
  }
  Ok ('代理已就绪: 127.0.0.1:' + $MixedPort + ' (HTTP + SOCKS5)')
  Invoke-EnsureWatchdog
  Head '连通性自检'
  Test-Egress

  # ---------- 熔断保护 ----------
  # 关键：只有端到端探测通过才开启系统代理。
  # 否则会把对方的浏览器指向一个没有出口的端口，等于把他的网搞坏。
  Head '检查是否可安全接管系统代理'
  if (Test-ProxyEgress) {
    Ok '出口正常，开启系统代理'
    Invoke-SetSystemProxy -Enable | Out-Null
    $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer
    Ok ('系统代理已开启: ' + $p)
  } else {
    if (Get-SystemProxyEnabled) {
      Invoke-SetSystemProxy | Out-Null   # 关掉
      Warn '探测未通过，已确保系统代理处于【关闭】状态（不会影响你的正常上网）'
    } else {
      Warn '探测未通过，系统代理保持【关闭】'
    }
    Write-Host ''
    Err '上游不通，暂不接管系统代理 —— 你的网络仍可正常使用（国内网站直连）'
    Info '请先解决上游问题，再重新运行本脚本。排查顺序:'
    Info '   1. .\ctl.ps1 -Action WarpStatus   看隧道是否就绪'
    Info '   2. .\ctl.ps1 -Action WarpStop 然后 -Action WarpStart  重建连接'
    Info '   3. .\diag.ps1                     完整诊断'
    Info '常见原因: 当前网络封了 MASQUE(QUIC 443)，或 WARP 被限速'
  }
}

function Action-Stop {
  Head '停止本地代理'
  try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
  $killed = 0
  Get-Process -Name 'mihomo' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      Stop-Process -Id $_.Id -Force -ErrorAction Stop
      $killed = $killed + 1
      Ok ('已结束 PID ' + $_.Id)
    } catch { Err ('无法结束 PID ' + $_.Id) }
  }
  Stop-Watchdog
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
  if ($killed -eq 0) { Info '没有正在运行的代理进程' }
  Start-Sleep -Milliseconds 500
  if (Test-IsRunning) { Warn ('端口 ' + $MixedPort + ' 仍被占用 (可能是别的程序)') } else { Ok '代理已停止' }
}

function Action-Status {
  Head '代理状态'
  if (-not (Test-IsRunning)) {
    Warn ('未运行 (端口 ' + $MixedPort + ' 无监听)')
    Info '启动: .\ctl.ps1 -Action Start'
    return
  }
  Ok ('监听中: 127.0.0.1:' + $MixedPort + ' (HTTP + SOCKS5)')

  $cfg = Invoke-Api -Path '/configs'
  if ($cfg) { Info ('运行模式: ' + $cfg.mode) } else { Warn '控制接口 ' + $CtrlPort + ' 无响应' }

  $proxies = Invoke-Api -Path '/proxies'
  if ($proxies) {
    $all = $proxies.proxies
    $builtin = @('Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay', 'Direct', 'Reject', 'RejectDrop', 'Pass', 'PassRule', 'Compatible', 'RejectDrop')
    $real = @($all.PSObject.Properties | Where-Object { $builtin -notcontains $_.Value.type })
    Info ('可用上游节点: ' + $real.Count)
    $sel = $all.PROXY
    if ($sel) { Info ('PROXY 当前指向: ' + $sel.now) }
    if ($real.Count -eq 0) {
      Warn '没有任何上游节点 —— 代理无法出境。请执行 Import。'
    } else {
      Write-Host ''
      Write-Host '  节点延迟 (最多显示 15 个):' -ForegroundColor Cyan
      $real | Select-Object -First 15 | ForEach-Object {
        $h = $_.Value.history
        $d = '未测'
        if ($h -and $h.Count -gt 0) { $d = ([string]$h[-1].delay) + ' ms' }
        Write-Host ('    {0,-40} {1}' -f $_.Name, $d)
      }
    }
  }
}

function Action-Switch {
  Head '切换节点'
  if (-not $Node) { Err '请用 -Node "<节点名>" 指定目标节点'; return }
  $body = @{ name = $Node } | ConvertTo-Json -Compress
  $enc = [uri]::EscapeDataString($Group)
  Invoke-Api -Method PUT -Path ('/proxies/' + $enc) -Body $body | Out-Null
  Start-Sleep -Milliseconds 300
  $chk = Invoke-Api -Path '/proxies'
  if ($chk -and $chk.proxies.$Group -and $chk.proxies.$Group.now -eq $Node) {
    Ok ('已切换 [' + $Group + '] -> ' + $Node)
  } else {
    Warn '未确认切换成功，请用 -Action Status 检查组名/节点名拼写'
  }
}

function Action-Env {
  Head '让命令行工具走代理'
  Say '  # 复制下面几行到 PowerShell 会话 (仅当前窗口生效)' DarkGray
  Say '  # 覆盖 git / pip / npm / curl / winget 等' DarkGray
  Write-Host ''
  $p = 'http://127.0.0.1:' + $MixedPort
  $s = 'socks5://127.0.0.1:' + $MixedPort
  Write-Host ('  $env:HTTP_PROXY  = ''' + $p + '''') -ForegroundColor Green
  Write-Host ('  $env:HTTPS_PROXY = ''' + $p + '''') -ForegroundColor Green
  Write-Host ('  $env:ALL_PROXY   = ''' + $s + '''') -ForegroundColor Green
  Write-Host ('  $env:NO_PROXY    = ''localhost,127.0.0.1,.cn,baidu.com,qq.com,aliyun.com''') -ForegroundColor Green
  Write-Host ''
  Say '  # 取消:' DarkGray
  Write-Host '  Remove-Item Env:HTTP_PROXY,Env:HTTPS_PROXY,Env:ALL_PROXY,Env:NO_PROXY -ErrorAction SilentlyContinue' -ForegroundColor DarkYellow
  Write-Host ''
  Say '  # git 永久代理 (可选):' DarkGray
  Write-Host ('  git config --global http.proxy ' + $p) -ForegroundColor DarkGray
  Write-Host ('  git config --global https.proxy ' + $p) -ForegroundColor DarkGray
  Write-Host ''
  Say '  # pip (写入 %APPDATA%\pip\pip.ini):' DarkGray
  Write-Host '  [global]' -ForegroundColor DarkGray
  Write-Host ('  proxy = ' + $p) -ForegroundColor DarkGray
}

function Action-Browser {
  Head '浏览器走代理 (不修改系统代理设置)'
  $pacUrl = 'file:///' + ($PacFile -replace '\\', '/')

  $cands = @(
    @{ n = 'Edge';   p = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' },
    @{ n = 'Edge';   p = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' },
    @{ n = 'Chrome'; p = 'C:\Program Files\Google\Chrome\Application\chrome.exe' },
    @{ n = 'Chrome'; p = 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe' },
    @{ n = 'Chrome'; p = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe') }
  )
  $found = @()
  foreach ($c in $cands) {
    if ((Test-Path $c.p) -and ($found.p -notcontains $c.p)) { $found += $c }
  }

  Say '  方案 A: PAC 定向代理 (推荐 —— 只有名单内域名走代理，其余直连)' White
  Write-Host ''
  Write-Host '  # 先【完全退出】浏览器，再执行对应命令:' -ForegroundColor DarkGray
  Write-Host ''
  if ($found.Count -gt 0) {
    foreach ($f in $found) {
      Write-Host ('  # ' + $f.n) -ForegroundColor DarkGray
      $q = [char]39
      $dq = [char]34
      $cmd = '  & ' + $q + $f.p + $q + ' --proxy-pac-url=' + $dq + $pacUrl + $dq
      Write-Host $cmd -ForegroundColor Green
      Write-Host ''
    }
  } else {
    Warn '  未在本机常见路径找到 Chrome / Edge'
    Say ('  请手动把浏览器快捷方式的目标改为: --proxy-pac-url="' + $pacUrl + '"') DarkGray
    Write-Host ''
  }

  Say '  方案 B: SwitchyOmega 扩展 (可随时切换，最灵活)' White
  Say ('    HTTP 代理   127.0.0.1 : ' + $MixedPort) DarkGray
  Say ('    PAC 地址    ' + $pacUrl) DarkGray
  Write-Host ''
  Say '  方案 C: 开启系统代理 (会影响所有软件，微信/游戏等也可能被代理)' White
  Say '    见 scripts\system-proxy.ps1 -Enable / -Disable' DarkGray
  Write-Host ''
  Say '  验证: 浏览器打开 https://www.google.com ，能出搜索结果即成功' Cyan
  Write-Host ''
  Info 'PAC 只覆盖名单内域名；国内网站仍直连，速度不受影响。'
}

function Action-Update {
  Head '升级内核'
  $vfile = Join-Path $BinDir 'VERSION.txt'
  $cur = '未知'
  if (Test-Path $vfile) { $cur = (Read-File $vfile).Trim() }
  $latest = Get-LatestTag
  $latestTxt = '获取失败'
  if ($latest) { $latestTxt = $latest }
  Info ('当前: ' + $cur + '    最新: ' + $latestTxt)
  if (-not $latest) { Warn '无法获取最新版本，跳过'; return }
  if ($cur -eq $latest) { Ok '已是最新版本'; return }
  if (Test-IsRunning) { Warn '代理运行中，先停止'; Action-Stop }
  if (Invoke-CoreDownload) { Ok '升级完成，请重新 Start' }
}

# ==================== WARP (free MASQUE tunnel) ====================
function Get-WarpDir {
  # 先找项目内自带组件（便于整个文件夹拷给别人直接用），找不到再回退用户目录
  $local = Join-Path $BinDir 'warp'
  if (Test-Path (Join-Path $local 'usque.exe')) { return $local }
  $c = Join-Path $env:LOCALAPPDATA 'WARP'
  if (Test-Path (Join-Path $c 'bin\usque.exe')) { return $c }
  return $null
}
function Get-UsqueExe {
  # 兼容两种布局：
  #   项目自包含: <项目>\bin\warp\usque.exe
  #   用户目录:   %LOCALAPPDATA%\WARP\bin\usque.exe
  param([string]$Dir)
  $a = Join-Path $Dir 'bin\usque.exe'
  if (Test-Path $a) { return $a }
  $b = Join-Path $Dir 'usque.exe'
  if (Test-Path $b) { return $b }
  return $null
}

function Test-WarpStale {
  # 返回 @{ Running=bool; Stale=bool; Hours=double }
  $p = Get-Process -Name 'usque' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $p) { return @{ Running = $false; Stale = $false; Hours = 0.0 } }
  try {
    $h = ((Get-Date) - $p.StartTime).TotalHours
    return @{ Running = $true; Stale = ($h -ge $WarpMaxHours); Hours = $h }
  } catch {
    return @{ Running = $true; Stale = $false; Hours = 0.0 }
  }
}

function Test-WarpRunning {
  $c = Get-NetTCPConnection -LocalPort 1080 -State Listen -ErrorAction SilentlyContinue
  return [bool]$c
}

# WARP warm-up: usque keeps the tunnel idle until outbound activity,
# so the first request can take ~15s. Probe once so later tests are fair.
function Invoke-WarpWarmup {
  Info '预热隧道 (首次建连可能需要十几秒)...'
  $deadline = (Get-Date).AddSeconds(60)
  $attempt = 0
  while ((Get-Date) -lt $deadline) {
    $attempt = $attempt + 1
    $r = & curl.exe -s -o NUL -x socks5h://127.0.0.1:1080 -w '%{http_code}' --max-time 20 'https://www.google.com/generate_204' 2>$null
    if ($r -in @('200', '204', '301', '302')) {
      Ok ('隧道已连通 (第 ' + $attempt + ' 次尝试)')
      return $true
    }
    Start-Sleep -Milliseconds 800
  }
  Warn '预热未成功 —— 隧道可能不稳定或 WARP 被限速，稍后可用 -Action WarpStatus 复查'
  return $false
}

function Action-WarpStatus {
  Head 'WARP (MASQUE) 状态'
  $d = Get-WarpDir
  if (-not $d) {
    Err '未安装 WARP 组件'
    Info '安装: .\ctl.ps1 -Action WarpInstall'
    return
  }
  Ok ('组件目录: ' + $d)
  $cfgp = Join-Path $d 'config.json'
  if (Test-Path $cfgp) {
    Ok '账号: 已注册'
    try {
      $o = Get-Content $cfgp -Raw | ConvertFrom-Json
      Info ('MASQUE 端点: ' + $o.endpoint_v4)
    } catch { }
  } else {
    Warn '账号未注册 -> .\ctl.ps1 -Action WarpRegister'
  }
  $st = Test-WarpStale
  if ($st.Running) {
    $warnStale = ''
    if ($st.Stale) { $warnStale = '  <== 超过阈值，下次 Start 会自动重启' }
    Info ('已运行 {0:N1} 小时（阈值 {1} 小时）{2}' -f $st.Hours, $WarpMaxHours, $warnStale)
  }
  if (Test-WarpRunning) {
    Ok '隧道运行中 (127.0.0.1:1080 SOCKS5)'
    Write-Host ''
    foreach ($t in @(
        @{ n = 'Google'; u = 'https://www.google.com/generate_204' },
        @{ n = 'X'; u = 'https://x.com/' }
      )) {
      $r = & curl.exe -s -o NUL -x socks5h://127.0.0.1:1080 -w '%{http_code}|%{time_total}' --max-time 40 $t.u 2>$null
      $p = $r -split '\|'
      $ok = $p[0] -in @('200', '204', '301', '302')
      $verdict = '不通'
      if ($ok) { $verdict = '通' }
      $col = 'Red'
      if ($ok) { $col = 'Green' }
      Write-Host ('    {0,-10} HTTP={1,-6} {2,-10} {3}' -f $t.n, $p[0], ($p[1] + 's'), $verdict) -ForegroundColor $col
    }
    Write-Host ''
    $tr = & curl.exe -s -x socks5h://127.0.0.1:1080 --max-time 20 'https://www.cloudflare.com/cdn-cgi/trace' 2>$null | Out-String
    if ($tr) {
      $tr.Trim() -split "`r?`n" | Where-Object { $_ -match '^(ip|loc|colo|warp)=' } | ForEach-Object { Info ('  ' + $_) }
    }
  } else {
    Warn '隧道未运行 -> .\ctl.ps1 -Action WarpStart'
  }
}

function Action-WarpInstall {
  Head '安装 WARP 组件 (无需管理员权限)'
  $d = Join-Path $env:LOCALAPPDATA 'WARP'
  $bd = Join-Path $d 'bin'
  New-Item -ItemType Directory -Force -Path $bd | Out-Null
  $asset = 'usque_4.2.1_windows_amd64.zip'
  $url = $Mirror + '/https://github.com/Diniboy1123/usque/releases/download/v4.2.1/' + $asset
  $zip = Join-Path $d 'usque.zip'
  Info ('下载 ' + $asset + ' ...')
  $code = (& curl.exe -sL --max-time 300 --retry 2 -o $zip -w '%{http_code}' $url 2>&1 | Select-Object -Last 1)
  if ($code -ne '200') { Err ('下载失败 HTTP=' + $code); return }
  $m = [System.IO.File]::ReadAllBytes($zip)[0..1]
  if ($m[0] -ne 0x50 -or $m[1] -ne 0x4B) { Err '下载内容不是 ZIP'; return }
  Expand-Archive -Path $zip -DestinationPath $bd -Force
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Get-ChildItem $bd -Filter '*.exe' | ForEach-Object { Unblock-File $_.FullName -ErrorAction SilentlyContinue }
  Ok ('已安装到 ' + $bd)
  Info '下一步: .\ctl.ps1 -Action WarpRegister'
}

function Action-WarpRegister {
  Head '注册免费 WARP 账号'
  $d = Get-WarpDir
  if (-not $d) { Err '请先执行 -Action WarpInstall'; return }
  $cfgp = Join-Path $d 'config.json'
  if (Test-Path $cfgp) { Warn '已存在 config.json，跳过注册'; return }
  $out = ''
  $okR = $false
  Push-Location $d
  # 关键: usque 会把「Config file not found」写到 stderr, 而这是首次注册的正常
  # 提示(它随后会完成注册)。$ErrorActionPreference=Stop 会把 stderr 当成终止性
  # 错误, 使脚本在注册完成前中断 —— 实测踩到过。这里临时放宽, 并只以
  # 「config.json 是否生成」作为成功判据。
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = (& (Get-UsqueExe -Dir $d) register --accept-tos --name 'DSH-LocalProxy' 2>&1 | Out-String)
  } catch {
    $out = $_.Exception.Message
  }
  $ErrorActionPreference = $prevEAP
  $okR = Test-Path $cfgp
  Pop-Location
  if ($okR) { Ok '注册成功'; Action-WarpStatus }
  else { Err '注册失败:'; Write-Host $out -ForegroundColor DarkYellow }
}

function Action-WarpStart {
  Head '启动 WARP 隧道 (MASQUE / HTTP3 over QUIC 443)'
  $d = Get-WarpDir
  if (-not $d) { Err '未安装 -> .\ctl.ps1 -Action WarpInstall'; return }
  if (-not (Test-Path (Join-Path $d 'config.json'))) { Err '未注册 -> .\ctl.ps1 -Action WarpRegister'; return }
  if (Test-WarpRunning) { Warn 'WARP 已在运行 (127.0.0.1:1080)'; return }
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
  $elog = Join-Path $LogDir 'warp.err.log'
  $a = @('socks', '-b', '127.0.0.1', '-p', '1080', '-P', '443',
         '-s', 'consumer-masque.cloudflareclient.com', '--always-reconnect')
  $p = Start-Process -FilePath (Get-UsqueExe -Dir $d) -ArgumentList $a `
       -WorkingDirectory $d -WindowStyle Hidden -PassThru `
       -RedirectStandardOutput (Join-Path $LogDir 'warp.log') -RedirectStandardError $elog
  Ok ('WARP 进程已启动 (PID ' + $p.Id + ')')
  Info '等待 SOCKS5 端口 1080 就绪...'
  $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline) {
    if (Test-WarpRunning) { break }
    Start-Sleep -Milliseconds 400
  }
  if (Test-WarpRunning) {
    Ok 'WARP 就绪 (127.0.0.1:1080)'
    Invoke-WarpWarmup | Out-Null
    Info '首次访问稍慢: 隧道需先建连，之后由 --always-reconnect 保持'
  } else {
    Err 'WARP 启动失败，日志尾部:'
    if (Test-Path $elog) { Get-Content $elog -Tail 15 -Encoding UTF8 | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkYellow } }
  }
}

function Action-WarpStop {
  Head '停止 WARP 隧道'
  $killed = 0
  Get-Process -Name 'usque' -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $killed = $killed + 1; Ok ('已结束 PID ' + $_.Id) } catch { }
  }
  if ($killed -eq 0) { Info 'WARP 未在运行' }
  Start-Sleep -Milliseconds 500
  if (Test-WarpRunning) { Warn '端口 1080 仍被占用' } else { Ok 'WARP 已停止' }
  Warn '提醒: WARP 停止后若 PROXY 仍指向 "WARP-免费"，国外网站将打不开'
  Info '切回直连: .\ctl.ps1 -Action Switch -Group PROXY -Node DIRECT'
}

function Test-ProxyEgress {
  # 端到端探测：经 7890 混合端口访问 Google。
  # 用于「熔断保护」——探测不过就不开系统代理，避免把对方的浏览器搞坏。
  param([int]$TimeoutSec = 18)
  try {
    $r = & curl.exe -s -o NUL -x 'http://127.0.0.1:7890' `
         -w '%{http_code}' --max-time $TimeoutSec `
         'https://www.google.com/generate_204' 2>$null
    return ($r -in @('200', '204', '301', '302'))
  } catch { return $false }
}

function Invoke-SetSystemProxy {
  # 用独立 powershell 进程调用 system-proxy.ps1，并显式带 -ExecutionPolicy Bypass。
  # 原因: Windows 默认执行策略是 Restricted。若用户不用 .bat 而是直接开 PowerShell
  # 跑 ctl.ps1，进程内策略可能是 Restricted，点调用子脚本会被拦。
  # 独立进程 + Bypass 可彻底消除这个不确定性。
  param([switch]$Enable)
  $sp = Join-Path $PSScriptRoot 'system-proxy.ps1'
  if (-not (Test-Path $sp)) { return $false }
  try {
    $verb = if ($Enable) { '-Enable' } else { '-Disable' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $sp $verb -Quiet | Out-Null
    return $true
  } catch { return $false }
}

function Get-SystemProxyEnabled {
  try {
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable
    return ($v -eq 1)
  } catch { return $false }
}

function Invoke-EnsureWarp {
  # 让上游就绪：没装就装，没注册就注册，没跑就跑，跑太久就重启。
  # 返回 $true 表示 1080 端口已在监听。
  $st = Test-WarpStale
  if ($st.Running -and $st.Stale) {
    Warn ('WARP 隧道已连续运行 {0:N1} 小时（超过 {1} 小时的阈值），正在自动重启以恢复性能' -f $st.Hours, $WarpMaxHours)
    Action-WarpStop
    Start-Sleep -Seconds 1
    # 继续走下面的启动流程
  } elseif (Test-WarpRunning) {
    Ok ('WARP 隧道已在运行（已运行 {0:N1} 小时）' -f $st.Hours)
    return $true
  }

  if (-not (Get-WarpDir)) {
    Warn '未检测到 WARP 组件，正在自动安装（首次约 5 MB）...'
    Action-WarpInstall
    if (-not (Get-WarpDir)) {
      Err 'WARP 组件安装失败'
      Info '手动重试: .\ctl.ps1 -Action WarpInstall'
      return $false
    }
  }

  $d = Get-WarpDir
  if (-not (Test-Path (Join-Path $d 'config.json'))) {
    Warn '未检测到 WARP 账号，正在自动注册（免费）...'
    Action-WarpRegister
    if (-not (Test-Path (Join-Path $d 'config.json'))) {
      Err 'WARP 账号注册失败'
      Info '手动重试: .\ctl.ps1 -Action WarpRegister'
      return $false
    }
  }

  Action-WarpStart
  return (Test-WarpRunning)
}

function Invoke-EnsureWatchdog {
  # 启动后台健康检查（单实例）。它每隔 5 分钟探一次隧道，
  # 连续失败或运行超时都会自动重启 usque。
  $wd = Join-Path $PSScriptRoot 'watchdog.ps1'
  if (-not (Test-Path $wd)) { Warn 'watchdog.ps1 不存在，跳过后台健康检查'; return }

  $pidf = Join-Path $LogDir 'watchdog.pid'
  if (Test-Path $pidf) {
    $old = 0
    try { $old = [int]((Get-Content $pidf -Raw -ErrorAction Stop).Trim()) } catch { }
    if ($old -gt 0 -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
      Ok ('后台健康检查已在运行 (PID ' + $old + ')')
      return
    }
  }

  try {
    $p = Start-Process -FilePath 'powershell' `
         -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wd) `
         -WindowStyle Hidden -PassThru
    Ok ('后台健康检查已启动 (PID ' + $p.Id + ')，每 5 分钟检查一次隧道')
  } catch {
    Warn ('后台健康检查启动失败: ' + $_.Exception.Message)
  }
}

function Stop-Watchdog {
  $pidf = Join-Path $LogDir 'watchdog.pid'
  if (-not (Test-Path $pidf)) { return }
  $old = 0
  try { $old = [int]((Get-Content $pidf -Raw -ErrorAction Stop).Trim()) } catch { }
  if ($old -gt 0) {
    try { Stop-Process -Id $old -Force -ErrorAction Stop; Ok ('已停止后台健康检查 (PID ' + $old + ')') } catch { }
  }
  Remove-Item $pidf -Force -ErrorAction SilentlyContinue
}

switch ($Action) {
  'Check' {
    Head '环境体检'
    Ok ('工作目录: ' + $Root)
    $dl = $Root.Substring(0, 1)
    $vol = Get-Volume -DriveLetter $dl -ErrorAction SilentlyContinue
    if ($vol) {
      Info ('文件系统: ' + $vol.FileSystem + '  (' + $vol.DriveType + ')')
      if ($vol.FileSystem -eq 'FAT32') { Warn 'FAT32 不支持硬链接/ACL，代理运行期间请勿拔出该盘' }
    }
    $coreTxt = '缺失'
    if (Test-Path $Core) { $coreTxt = (Get-Item $Core).Length.ToString('N0') + ' 字节' }
    Info ('内核: ' + $coreTxt)
    if (Test-Path $Core) {
      $ver = (& $Core -v 2>&1 | Select-Object -First 1)
      Info ('版本: ' + $ver)
    }
    $g1 = '缺失'; if (Test-Path (Join-Path $BinDir 'geoip.dat')) { $g1 = '就绪' }
    $g2 = '缺失'; if (Test-Path (Join-Path $BinDir 'geosite.dat')) { $g2 = '就绪' }
    Info ('GeoIP: ' + $g1 + '    GeoSite: ' + $g2)
    $rt = '未生成 (尚未导入上游)'; if (Test-Path $RunCfg) { $rt = '已生成 (含上游)' }
    Info ('运行时配置: ' + $rt)
    if (Test-IsRunning) { Ok ('代理运行中 (127.0.0.1:' + $MixedPort + ')') } else { Warn '代理未运行' }
    if (Test-WarpRunning) { Ok 'WARP 隧道: 运行中 (127.0.0.1:1080)' }
    elseif (Get-WarpDir) { Warn 'WARP 隧道: 已安装但未运行' }
    else { Info 'WARP 隧道: 未安装' }
    $sp = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable
    $spTxt = '未开启 (本方案默认不改它)'
    if ($sp -eq 1) { $spTxt = '已开启' }
    Info ('系统代理: ' + $spTxt)
    Write-Host ''
    Info '下一步: .\ctl.ps1 -Action Start'
  }
  'Import'  { Action-Import }
  'Start'   { Action-Start }
  'Stop'    { Action-Stop }
  'Restart' { Action-Stop; Start-Sleep -Seconds 1; Action-Start }
  'Status'  { Action-Status }
  'Switch'  { Action-Switch }
  'Env'     { Action-Env }
  'Browser' { Action-Browser }
  'Update'  { Action-Update }
  'WarpInstall'  { Action-WarpInstall }
  'WarpRegister' { Action-WarpRegister }
  'WarpStart'    { Action-WarpStart }
  'WarpStop'     { Action-WarpStop }
  'WarpStatus'   { Action-WarpStatus }
  'Test' {
    Head '连通性测试'
    if (-not (Test-IsRunning)) { Err '代理未运行'; return }
    Test-Egress
  }
}