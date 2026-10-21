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
  [int]$MaxHours     = 8      # 隧道运行时长上限(小时)，超过就主动重启
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

function Get-UptimeHours {
  $p = Get-Process -Name 'usque' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $p) { return -1 }
  try { return ((Get-Date) - $p.StartTime).TotalHours } catch { return 0 }
}

function Restart-Tunnel($reason) {
  Log ('RESTART: ' + $reason)
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Ctl -Action WarpStop 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Ctl -Action WarpStart 2>&1 | Out-Null
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
while ($true) {
  # mihomo 不在了就没必要继续
  if (-not (Get-Process -Name 'mihomo' -ErrorAction SilentlyContinue)) {
    Log 'mihomo 已退出，watchdog 结束'
    break
  }

  $up = Get-UptimeHours

  # 1) 运行时长超上限 -> 主动重启（预防"连得上但数据面已死"）
  if ($up -ge $MaxHours) {
    Restart-Tunnel ('运行 ' + [math]::Round($up, 1) + ' 小时，超过上限 ' + $MaxHours + ' 小时') | Out-Null
    $fails = 0
    Start-Sleep -Seconds $IntervalSec
    continue
  }

  # 2) 数据面探测
  if (Test-Tunnel) {
    if ($fails -gt 0) { Log ('探测恢复，失败计数清零 (之前 ' + $fails + ' 次)') }
    $fails = 0
  } else {
    $fails++
    Log ('探测失败 ' + $fails + '/' + $MaxFails + '（隧道运行 ' + [math]::Round($up, 1) + 'h）')
    if ($fails -ge $MaxFails) {
      Restart-Tunnel ('连续 ' + $fails + ' 次探测失败') | Out-Null
      $fails = 0
    }
  }

  Start-Sleep -Seconds $IntervalSec
}

Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
Log 'watchdog 已退出'
