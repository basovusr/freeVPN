<#
================================================================
  隧道健康看门狗  watchdog.ps1
================================================================
  由 ctl.ps1 -Action Start 自动在后台拉起，不需要手动运行。

  做什么:
    · 每 5 分钟经 usque 的 SOCKS5 探测一次外网
    · 连续 3 次失败 -> 自动重启 usque 隧道
    · 运行时长超过上限 -> 主动重启，避免"连得上但数据面已死"的状态
    · 全程写日志 logs\watchdog.log

  为什么需要它:
    实测 usque 隧道连续运行约 21 小时后会失效，且它自带的自动重连
    只重建 QUIC 连接(日志写 Connected to MASQUE server)，数据面仍是死的，
    SOCKS5 请求全部 30 秒超时。没有后台检查的话，电脑开着不动就会
    悄悄失去国外访问能力。

  手动运行(调试用):
    .\watchdog.ps1 -IntervalSec 60 -MaxFails 1
================================================================
#>
[CmdletBinding()]
param(
  [int]$IntervalSec  = 300,   # 探查间隔(秒)
  [int]$MaxFails     = 3,     # 连续失败几次触发重启
  [int]$ProbeTimeout = 12,    # 单次探测超时(秒)
  [int]$MaxHours     = 8,     # 隧道运行时长上限(小时)，超过就主动重启
  [int]$MixedPort    = 7890   # mihomo 的混合端口，也就是用户实际使用的入口
)

$ErrorActionPreference = 'Continue'
$Root     = Split-Path -Parent $PSScriptRoot
$LogDir   = Join-Path $Root 'logs'
$PidFile  = Join-Path $LogDir 'watchdog.pid'
$LogFile  = Join-Path $LogDir 'watchdog.log'
$Ctl      = Join-Path $PSScriptRoot 'ctl.ps1'
$Socks    = 'socks5h://127.0.0.1:1080'
$Utf8     = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Log($msg) {
  $line = ('[{0}] {1}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $msg)
  try { [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8) } catch { }
}

function Test-Tunnel {
  # 返回 $true 表示隧道数据面可用
  try {
    $r = & curl.exe -s -o NUL -x $Socks -w '%{http_code}' --max-time $ProbeTimeout `
         'https://www.gstatic.com/generate_204' 2>$null
    return ($r -in @('200', '204'))
  } catch { return $false }
}

function Test-Frontend {
  # 用户实际使用的路径：经 mihomo 的混合端口访问外网。
  # 之前只探测 usque(1080)，导致 mihomo 前端坏了却报告"一切正常" ——
  # 实测 10-22 09:08~15:36 之间看门狗零失败日志，但用户无法上网。
  try {
    $r = & curl.exe -s -o NUL -x ('http://127.0.0.1:' + $MixedPort) -w '%{http_code}' --max-time $ProbeTimeout `
         'https://www.gstatic.com/generate_204' 2>$null
    return ($r -in @('200', '204'))
  } catch { return $false }
}

function Get-SystemProxyEnabled {
  try {
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable
    return ($v -eq 1)
  } catch { return $false }
}

function Restart-Frontend($reason) {
  # 只重启 mihomo，不动看门狗自己。
  # 调 ctl.ps1 -Action Start（不是 Restart）：Start 里的 Invoke-EnsureWatchdog
  # 会读 PID 文件发现本实例还活着，于是跳过，不会把自己杀掉。
  Log ('RESTART-FRONTEND: ' + $reason)
  try {
    Get-Process -Name 'mihomo' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Invoke-CtlChild 'Start'
    Start-Sleep -Seconds 3
    if (Test-Frontend) {
      Log 'RESTART-FRONTEND OK: 前端已恢复'
      return $true
    }
    Log 'RESTART-FRONTEND FAILED: 重启后前端仍不通'
    return $false
  } catch {
    Log ('RESTART-FRONTEND ERROR: ' + $_.Exception.Message)
    return $false
  }
}

function Get-UptimeHours {
  $p = Get-Process -Name 'usque' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $p) { return -1 }
  try { return ((Get-Date) - $p.StartTime).TotalHours } catch { return 0 }
}

function Invoke-CtlChild($action) {
  # 关键：不能用管道(& ... | Out-Null)。
  # ctl.ps1 -Action WarpStart 会启动 usque 这个长驻进程，它继承管道写端，
  # 子进程退出后管道仍被 usque 持有，Out-Null 永远等不到 EOF ->
  # 看门狗死锁，之后再也不会探测(实测卡死 2 小时)。
  # 改用 Start-Process 重定向到文件 + 带超时的等待，彻底避开管道。
  $o = Join-Path $LogDir 'wd_child.log'
  $e = Join-Path $LogDir 'wd_child.err.log'
  try {
    $p = Start-Process -FilePath 'powershell' `
         -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Ctl, '-Action', $action) `
         -WindowStyle Hidden -PassThru `
         -RedirectStandardOutput $o -RedirectStandardError $e
    if (-not $p.WaitForExit(150000)) {
      Log ('子进程 ' + $action + ' 超时(150s)，强制结束')
      try { $p.Kill() } catch { }
    }
  } catch {
    Log ('子进程 ' + $action + ' 启动失败: ' + $_.Exception.Message)
  }
}

function Restart-Tunnel($reason) {
  Log ('RESTART: ' + $reason)
  try {
    Invoke-CtlChild 'WarpStop'
    Start-Sleep -Seconds 2
    Invoke-CtlChild 'WarpStart'
    # 实测 MASQUE 建连 + 预热需要 15~25 秒，8 秒会误判为失败
    Log '等待隧道预热(最多 40 秒)...'
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 3
      if (Test-Tunnel) { break }
    }
    if (Test-Tunnel) {
      Log 'RESTART OK: 隧道已恢复'
      return $true
    }
    Log 'RESTART FAILED: 重启后仍不通，等待下个周期重试'
    return $false
  } catch {
    Log ('RESTART ERROR: ' + $_.Exception.Message)
    return $false
  }
}

# ---- 单实例保护 ----
if (Test-Path $PidFile) {
  $old = 0
  try { $old = [int]((Get-Content $PidFile -Raw -ErrorAction Stop).Trim()) } catch { }
  if ($old -gt 0) {
    $alive = Get-Process -Id $old -ErrorAction SilentlyContinue
    if ($alive) {
      Log ('已有 watchdog 在运行 (PID ' + $old + ')，本实例退出')
      exit 0
    }
  }
}
[System.IO.File]::WriteAllText($PidFile, [string]$PID, $Utf8)

Log ('watchdog 启动 PID=' + $PID + '  间隔=' + $IntervalSec + 's  失败阈值=' + $MaxFails + '  时长上限=' + $MaxHours + 'h')

$fails = 0
$frontFails = 0
$proxyOffCount = 0
while ($true) {
  # mihomo 是用户实际使用的入口。它挂了不能退出，要负责拉起。
  # (早期版本这里直接 break，导致前端崩溃时看门狗自己先退出，
  #  永远不会重启 mihomo —— 实测 10-22 复现。)
  if (-not (Get-Process -Name 'mihomo' -ErrorAction SilentlyContinue)) {
    Log 'mihomo 进程不存在，尝试重启前端'
    Restart-Frontend 'mihomo 进程已消失' | Out-Null
    $frontFails = 0
    Start-Sleep -Seconds $IntervalSec
    continue
  }

  $up = Get-UptimeHours

  # 1) 运行时长超上限 -> 主动重启（预防"连得上但数据面已死"）
  if ($up -ge $MaxHours) {
    Restart-Tunnel ('运行 ' + [math]::Round($up, 1) + ' 小时，超过上限 ' + $MaxHours + ' 小时') | Out-Null
    $fails = 0
    $frontFails = 0
    Start-Sleep -Seconds $IntervalSec
    continue
  }

  # 2) 隧道数据面（usque SOCKS5 1080）
  $tunOk = Test-Tunnel
  if ($tunOk) {
    if ($fails -gt 0) { Log ('隧道探测恢复，失败计数清零 (之前 ' + $fails + ' 次)') }
    $fails = 0
  } else {
    $fails++
    Log ('隧道探测失败 ' + $fails + '/' + $MaxFails + '（隧道运行 ' + [math]::Round($up, 1) + 'h）')
    if ($fails -ge $MaxFails) {
      Restart-Tunnel ('连续 ' + $fails + ' 次隧道探测失败') | Out-Null
      $fails = 0
    }
  }

  # 3) 用户实际路径（mihomo 7890）。这一层之前完全没覆盖。
  if (Test-Frontend) {
    if ($frontFails -gt 0) { Log ('前端探测恢复，失败计数清零 (之前 ' + $frontFails + ' 次)') }
    $frontFails = 0
    # 连续 2 次都关闭才提醒：启动瞬间 ctl.ps1 可能还没走到开启系统代理那一步，
    # 单次检查会误报（实测 10-22 启动后就误报过一次）。
    if (Get-SystemProxyEnabled) {
      $proxyOffCount = 0
    } else {
      $proxyOffCount++
      if ($proxyOffCount -ge 2) {
        Log '提醒: 系统代理持续为【关闭】，浏览器不会走代理。若不是你主动关的，运行 系统代理开关.bat 选[1]开启'
        $proxyOffCount = 0
      }
    }
  } else {
    $frontFails++
    $tunTxt = '正常'
    if (-not $tunOk) { $tunTxt = '也异常' }
    Log ('前端探测失败 ' + $frontFails + '/' + $MaxFails + '（mihomo:' + $MixedPort + ' 不通，隧道' + $tunTxt + '）')
    if ($frontFails -ge $MaxFails) {
      if ($tunOk) {
        Restart-Frontend '连续失败但隧道正常，判定 mihomo 前端故障' | Out-Null
      } else {
        Log '隧道同样不通，已在上一步处理，跳过前端重启'
      }
      $frontFails = 0
    }
  }

  Start-Sleep -Seconds $IntervalSec
}

Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
Log 'watchdog 已退出'
