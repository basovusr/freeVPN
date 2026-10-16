<#
================================================================
  系统代理开关  system-proxy.ps1
================================================================
  说明:
    本方案【默认不需要】开系统代理。
    浏览器用 PAC 定向代理、命令行用环境变量即可，
    这样不会影响微信/钉钉/游戏等无关软件。

    只有当你希望「所有软件都走代理」时才用这个脚本。

  用法:
    .\system-proxy.ps1 -Enable     开启系统代理
    .\system-proxy.ps1 -Disable    关闭并还原
    .\system-proxy.ps1 -Status     查看当前状态
================================================================
#>
[CmdletBinding()]
param(
  [switch]$Enable,
  [switch]$Disable,
  [switch]$Status,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Key  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$Port = 7890
$Bypass = 'localhost;127.*;10.*;172.16.*-172.31.*;192.168.*;<local>;*.cn;*.baidu.com;*.qq.com;*.taobao.com;*.tmall.com;*.alipay.com;*.aliyun.com;*.alicdn.com;*.jd.com;*.bilibili.com;*.zhihu.com;*.csdn.net;*.163.com;*.weibo.com;*.gitee.com;*.douyin.com;*.meituan.com;*.xiaohongshu.com;*.tencent.com;*.huawei.com;*.xiaomi.com'

function Show-Status {
  if ($Quiet) { return }
  $p = Get-ItemProperty -Path $Key
  $on = $p.ProxyEnable -eq 1
  Write-Host ''
  Write-Host ('  系统代理: ' + $(if ($on) { '已开启' } else { '未开启' })) -ForegroundColor $(if ($on) { 'Green' } else { 'Gray' })
  Write-Host ('  代理地址: ' + $p.ProxyServer)
  Write-Host ('  绕过列表: ' + $p.ProxyOverride)
  Write-Host ('  PAC 地址: ' + $p.AutoConfigURL)
  Write-Host ''
}

function Refresh-InternetSettings {
  # 让设置立即生效，无需注销
  $sig = @'
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
'@
  try {
    $t = Add-Type -MemberDefinition $sig -Name 'WinINet' -Namespace 'ProxyUtil' -PassThru -ErrorAction Stop
    $t::InternetSetOption([System.IntPtr]::Zero, 39, [System.IntPtr]::Zero, 0) | Out-Null  # SETTINGS_CHANGED
    $t::InternetSetOption([System.IntPtr]::Zero, 37, [System.IntPtr]::Zero, 0) | Out-Null  # REFRESH
  } catch {
    Write-Host '  [提示] 设置已写入注册表，若未立即生效请重启浏览器' -ForegroundColor Yellow
  }
}

function Test-ProxyAlive {
  $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  return [bool]$c
}

if ($Status -or (-not $Enable -and -not $Disable)) {
  Write-Host ''
  Write-Host '=== 系统代理状态 ===' -ForegroundColor Cyan
  Show-Status
  exit 0
}

if ($Enable) {
  Write-Host ''
  if (-not $Quiet) { Write-Host '=== 开启系统代理 ===' -ForegroundColor Cyan }
  if (-not (Test-ProxyAlive)) {
    if (-not $Quiet) {
      Write-Host ('  [警告] 本地代理端口 ' + $Port + ' 没有监听 —— 开启后可能全部断网') -ForegroundColor Yellow
      Write-Host '  [警告] 请先运行: scripts\ctl.ps1 -Action Start' -ForegroundColor Yellow
    }
    if ($Quiet) { Write-Host '  [警告] 代理未运行，仍按请求开启系统代理' -ForegroundColor Yellow }
    else {
      $ans = Read-Host '  仍要继续吗? (y/N)'
      if ($ans -ne 'y') { Write-Host '  已取消' -ForegroundColor Gray; exit 0 }
    }
  }
  Set-ItemProperty -Path $Key -Name ProxyEnable  -Value 1 -Type DWord
  Set-ItemProperty -Path $Key -Name ProxyServer  -Value ('127.0.0.1:' + $Port) -Type String
  Set-ItemProperty -Path $Key -Name ProxyOverride -Value $Bypass -Type String
  Set-ItemProperty -Path $Key -Name AutoConfigURL -Value '' -Type String
  Refresh-InternetSettings
  if (-not $Quiet) { Write-Host '  [OK] 已开启' -ForegroundColor Green }
  Show-Status
  if (-not $Quiet) { Write-Host '  关闭命令: .\system-proxy.ps1 -Disable' -ForegroundColor Gray }
}

if ($Disable) {
  Write-Host ''
  if (-not $Quiet) { Write-Host '=== 关闭系统代理 ===' -ForegroundColor Cyan }
  Set-ItemProperty -Path $Key -Name ProxyEnable -Value 0 -Type DWord
  Set-ItemProperty -Path $Key -Name ProxyServer -Value '' -Type String
  Set-ItemProperty -Path $Key -Name ProxyOverride -Value '' -Type String
  Set-ItemProperty -Path $Key -Name AutoConfigURL -Value '' -Type String
  Refresh-InternetSettings
  if (-not $Quiet) { Write-Host '  [OK] 已关闭并还原' -ForegroundColor Green }
  Show-Status
}
