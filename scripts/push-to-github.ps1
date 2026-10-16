<#
================================================================
  推送到 GitHub
================================================================
  用法:
    cd E:\\VPN\\scripts

    # 首次推送（会自动创建仓库）
    .\\push-to-github.ps1 -User "你的GitHub用户名" -Token "ghp_xxxxxxxx"

    # 之后更新
    .\\push-to-github.ps1 -User "你的GitHub用户名" -Token "ghp_xxxxxxxx" -Message "更新说明"

  关于 Token:
    GitHub 早已不支持密码推送，必须用 Personal Access Token (PAT)。
    获取步骤:
      1. 打开 https://github.com/settings/tokens
      2. 点 "Generate new token" -> 选 "classic"
      3. 勾选 scope:  repo   （勾这一项就够）
      4. 生成后立刻复制，页面关掉就再也看不到了
    注意: Token 等同密码，不要提交到仓库、不要发给别人。
          本脚本不会保存 Token，只在本次命令中使用。
================================================================
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$User,
  [Parameter(Mandatory = $true)][string]$Token,
  [string]$Repo = 'freeVPN',
  [string]$Message,
  [string]$Description = '免管理员权限的 Windows 本地代理：Cloudflare WARP MASQUE + Mihomo 智能分流',
  [switch]$Private
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

# ---------------- 定位 git ----------------
function Find-Git {
  $c = Get-Command git -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
  if (Test-Path $wg) {
    $hit = Get-ChildItem $wg -Recurse -Filter 'git.exe' -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -match 'mingw64\\bin\\git\.exe$' } |
           Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

$Git = Find-Git
if (-not $Git) {
  Err '未找到 git。请先安装: winget install --id Git.MinGit --scope user'
  exit 1
}
# 让 MinGit 的配套 dll 可被加载
$env:PATH = (Split-Path $Git -Parent) + ';' + $env:PATH
Info ('git: ' + $Git)

# ---------------- 前置检查 ----------------
Head '推送前检查'

Push-Location $Root
try {
  # 代理：GitHub 直连通常不可达，必须走本地代理
  $httpsProxy = (& $Git config --global --get https.proxy)
  if (-not $httpsProxy) {
    Info '未配置 git 代理，设置为 127.0.0.1:7890'
    & $Git config --global http.proxy  'http://127.0.0.1:7890'
    & $Git config --global https.proxy 'http://127.0.0.1:7890'
  } else {
    Ok ('git 代理: ' + $httpsProxy)
  }

  # 代理是否真的在跑
  $listening = [bool](Get-NetTCPConnection -LocalPort 7890 -State Listen -ErrorAction SilentlyContinue)
  if (-not $listening) {
    Err '本地代理端口 7890 未监听 —— 无法访问 GitHub'
    Info '请先启动代理: .\ctl.ps1 -Action Start   或双击 启动代理.bat'
    exit 1
  }
  Ok '本地代理 7890 正在监听'

  # safe.directory（FAT32 不记录所有者，git 会拒绝操作）
  $sd = (& $Git config --global --get-all safe.directory) -join ';'
  if ($sd -notmatch [regex]::Escape($Root)) {
    & $Git config --global --add safe.directory ($Root -replace '\\', '/')
    Ok '已添加 safe.directory'
  }

  # 仓库是否已初始化
  if (-not (Test-Path (Join-Path $Root '.git'))) {
    Err '当前目录不是 git 仓库。请先在项目根目录执行: git init -b main'
    exit 1
  }

  # 连通性
  Info '测试经代理访问 GitHub...'
  $probe = (& $Git ls-remote https://github.com/git/git.git HEAD 2>&1 | Out-String)
  if ($probe -notmatch '^[0-9a-f]{40}') {
    Err '无法访问 GitHub，请确认代理正常工作'
    exit 1
  }
  Ok 'GitHub 可达'

  # ---------------- 有变更则提交 ----------------
  $dirty = (& $Git status --porcelain)
  if ($dirty) {
    if (-not $Message) { $Message = 'update: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    & $Git add -A | Out-Null
    & $Git commit -m $Message | Out-Null
    Ok ('已提交变更: ' + $Message)
  } else {
    Info '工作区无未提交变更'
  }

  # ---------------- 创建远程仓库（若不存在）----------------
  Head ('检查远程仓库 ' + $User + '/' + $Repo)

  $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(($User + ':' + $Token)))
  $apiHeaders = @{
    Authorization          = 'Basic ' + $auth
    Accept                 = 'application/vnd.github+json'
    'User-Agent'           = 'freeVPN-push-script'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  $exists = $false
  try {
    $r = Invoke-WebRequest -Uri ('https://api.github.com/repos/' + $User + '/' + $Repo) `
         -Headers $apiHeaders -Method GET -UseBasicParsing -TimeoutSec 30
    if ($r.StatusCode -eq 200) { $exists = $true }
  } catch {
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 404) { $exists = $false }
    elseif ($code -eq 401) {
      Err 'Token 无效或已过期 (401)'
      Info '请到 https://github.com/settings/tokens 重新生成，记得勾选 repo 权限'
      exit 1
    } else {
      Err ('检查仓库失败: ' + $_.Exception.Message)
      exit 1
    }
  }

  if ($exists) {
    Ok '仓库已存在，直接推送'
  } else {
    Info '仓库不存在，正在创建...'
    $body = @{
      name        = $Repo
      description = $Description
      private     = [bool]$Private
      auto_init   = $false
    } | ConvertTo-Json -Compress
    try {
      $cr = Invoke-WebRequest -Uri 'https://api.github.com/user/repos' -Headers $apiHeaders `
            -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 30
      Ok ('仓库已创建: ' + $User + '/' + $Repo)
    } catch {
      $resp = ''
      if ($_.Exception.Response) {
        $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
        $resp = $sr.ReadToEnd()
      }
      Err ('创建仓库失败: ' + $_.Exception.Message)
      if ($resp) { Write-Host ('    ' + $resp) -ForegroundColor DarkYellow }
      Info '可能原因: Token 没有 repo 权限'
      exit 1
    }
  }

  # ---------------- 配置 remote 并推送 ----------------
  Head '推送'
  $remoteUrl = 'https://' + $User + ':' + $Token + '@github.com/' + $User + '/' + $Repo + '.git'

  $hasOrigin = (& $Git remote) -contains 'origin'
  if ($hasOrigin) { & $Git remote set-url origin $remoteUrl }
  else            { & $Git remote add origin $remoteUrl }
  Ok 'remote origin 已配置'

  # .git 必须先有 main 分支
  $branch = (& $Git rev-parse --abbrev-ref HEAD)
  if ($branch -ne 'main') {
    & $Git branch -M main
    Info '已重命名为 main 分支'
  }

  # git 会把正常进度写到 stderr。$ErrorActionPreference='Stop' 会把 stderr 当成
  # 终止性错误，导致脚本在「清理 Token」之前就退出 —— 真实发生过，Token 因此
  # 残留在 .git/config 里。所以这里必须临时放宽，并始终以 exit code 判断成败。
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  # 走 cmd 中转: PowerShell 会把原生命令的 stderr 包成 NativeCommandError
  # 并打印红字，即便 exit code 为 0。经 cmd 重定向可彻底避免这种噪音。
  $pushOut = (cmd /c "`"$Git`" push -u origin main 2>&1" | Out-String)
  $pushCode = $LASTEXITCODE
  $ErrorActionPreference = $prevEAP

  foreach ($line in ($pushOut -split "`r?`n")) {
    if ($line.Trim()) { Write-Host ('  ' + $line) }
  }

  if ($pushCode -eq 0) {
    Ok '推送成功'
    Head '完成'
    Write-Host ('  仓库地址: https://github.com/' + $User + '/' + $Repo) -ForegroundColor Green
    Write-Host ''
    Info '下次更新只需: .\push-to-github.ps1 -User <用户名> -Token <新Token>'
  } else {
    Err ('推送失败 (exit code ' + $pushCode + ')')
    Info '常见原因: Token 权限不足 / 网络中断 / 远程已有提交'
    Info '若远程已有提交，可先执行: git pull --rebase origin main'
    throw 'push failed'
  }
} finally {
  # 无论成败都必须清理：Token 绝不能留在 .git/config 里
  try {
    $clean = 'https://github.com/' + $User + '/' + $Repo + '.git'
    $cur = (& $Git remote get-url origin 2>$null)
    if ($cur -and $cur -match 'ghp_|@github\.com') {
      if ($cur -ne $clean) {
        $lock = Join-Path $Root '.git\config.lock'
        if (Test-Path $lock) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
        & $Git remote set-url origin $clean 2>$null | Out-Null
      }
    }
    $now = (& $Git remote get-url origin 2>$null)
    if ($now -match 'ghp_') {
      Write-Host '  [警告] 未能自动清除 remote 中的 Token，请手动执行:' -ForegroundColor Yellow
      Write-Host ('    git remote set-url origin ' + $clean) -ForegroundColor DarkYellow
    } else {
      Write-Host '  [OK]   remote URL 中不含 Token' -ForegroundColor Green
    }
  } catch {
    Write-Host '  [警告] 清理 Token 时出错，请手动检查 .git/config' -ForegroundColor Yellow
  }
  Pop-Location
}
