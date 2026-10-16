# 部署验收清单

用于确认部署完整。全部通过说明环境正常。

---

## 一、静态检查

| # | 检查项 | 命令 | 预期 |
| --- | --- | --- | --- |
| 1 | PowerShell 版本 | `$PSVersionTable.PSVersion` | 5.1 或更高 |
| 2 | 管理员权限 | 无需 | 非管理员即可运行 |
| 3 | 脚本语法 | 见下 | 0 错误 |
| 4 | `.ps1` 编码 | 见下 | UTF-8 **带 BOM** |
| 5 | `.bat` 编码 | 见下 | **GBK**，行尾 **CRLF** |

```powershell
# 语法检查
Get-ChildItem .\scripts\*.ps1 | ForEach-Object {
  $e = $null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
  "{0}: {1}" -f $_.Name, $(if ($e.Count) { "$($e.Count) 错误" } else { 'OK' })
}

# BOM 检查（前 3 字节应为 EF BB BF）
Get-ChildItem .\scripts\*.ps1 | ForEach-Object {
  $b = [System.IO.File]::ReadAllBytes($_.FullName)[0..2]
  "{0}: BOM={1}" -f $_.Name, ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

# bat 行尾检查（纯 LF 必须为 0）
Get-ChildItem .\*.bat | ForEach-Object {
  $b = [System.IO.File]::ReadAllBytes($_.FullName)
  $lf = 0; for ($i = 0; $i -lt $b.Length; $i++) {
    if ($b[$i] -eq 0x0A -and ($i -eq 0 -or $b[$i-1] -ne 0x0D)) { $lf++ }
  }
  "{0}: 纯LF={1}" -f $_.Name, $lf
}
```

---

## 二、运行时检查

```powershell
cd scripts
.\ctl.ps1 -Action Check
```

| # | 检查项 | 预期输出 |
| --- | --- | --- |
| 6 | 内核存在 | `内核: 61,219,840 字节` |
| 7 | 内核版本 | `Mihomo Meta v1.19.32` |
| 8 | 规则数据 | `GeoIP: 就绪  GeoSite: 就绪` |
| 9 | 内核运行 | `[OK] 代理运行中 (127.0.0.1:7890)` |
| 10 | WARP 运行 | `[OK] WARP 隧道: 运行中 (127.0.0.1:1080)` |
| 11 | 系统代理 | `已开启`（启动后） |

---

## 三、网络检查

```powershell
.\diag.ps1
```

| # | 检查项 | 预期 |
| --- | --- | --- |
| 12 | DNS 投毒检测 | 能识别出 `www.google.com` 被投毒 |
| 13 | 直连基线 | Google 直连失败 / 百度直连成功 |
| 14 | 分流：百度 | `using DIRECT`，约 0.07 ~ 0.17 s |
| 15 | 分流：Google | `using PROXY[WARP-免费]`，HTTP 204 |
| 16 | 分流：X | `using PROXY[WARP-免费]`，HTTP 200 |
| 17 | 端口仅回环 | 1080 / 7890 / 9090 均绑定 `127.0.0.1` |

```powershell
# 端口绑定确认（应全部为 127.0.0.1，不应出现 0.0.0.0）
Get-NetTCPConnection -State Listen |
  Where-Object { $_.LocalPort -in 1080, 7890, 9090 } |
  Select-Object LocalAddress, LocalPort
```

---

## 四、浏览器检查

| # | 检查项 | 方法 | 预期 |
| --- | --- | --- | --- |
| 18 | 系统代理已写注册表 | `system-proxy.ps1 -Status` | `ProxyEnable = 1` |
| 19 | 绕过列表生效 | 同上 | 含 `*.cn`、`*.bilibili.com` 等 |
| 20 | 浏览器走代理 | Edge 访问 `edge://net-internals/#proxy` | 显示 `127.0.0.1:7890` |
| 21 | **浏览器已重启** | — | 若未重启，代理设置不生效 |
| 22 | 实际访问 | 打开 <https://www.google.com> | 出搜索结果 |

> 第 21 项是最容易漏的。浏览器只在启动时读取一次代理设置。

---

## 五、稳定性抽测（可选）

```powershell
# 连续探测 10 次，统计成功率
$ok = 0
1..10 | ForEach-Object {
  $r = curl.exe -s -o NUL -x http://127.0.0.1:7890 -w "%{http_code}" `
       --max-time 30 https://www.google.com/generate_204 2>$null
  if ($r -in '200', '204') { $ok++ }
  Start-Sleep -Milliseconds 500
}
"成功率: $ok / 10"
```

| # | 检查项 | 预期 |
| --- | --- | --- |
| 23 | Google 成功率 | ≥ 7 / 10（免费 WARP 约 10% ~ 30% 偶发失败）|

成功率明显低于 7/10 时，可尝试：

```powershell
.\ctl.ps1 -Action WarpStop
.\ctl.ps1 -Action WarpStart     # 重新建连，可能换到更好的边缘节点
```

---

## 六、故障定位速查

| 现象 | 最可能原因 | 处理 |
| --- | --- | --- |
| 全部网站打不开 | 系统代理开着但代理没运行 | 运行 `启动代理.bat`，或 `系统代理开关.bat` → `[2]` |
| 国内网站变慢 | 绕过列表未生效 | 关闭再开启系统代理 |
| Google 不通、百度正常 | 上游未就绪 / WARP 隧道断 | `.\ctl.ps1 -Action WarpStatus` |
| 状态显示节点延迟 `0 ms` | 健康检查超时 | 等 10 秒再看，或重启 |
| 中文显示乱码 | 终端代码页不是 936 | `chcp 936` |
| 脚本报语法错误 | `.ps1` 缺 BOM | 以 UTF-8 BOM 重新保存 |
| 批处理中文乱码 | 用了 UTF-8 或 LF 行尾 | 存为 GBK + CRLF |
