# 本地代理服务器 for Windows

> 在**没有管理员权限**的 Windows 上，用免费 Cloudflare WARP 搭一套带智能分流的本地代理，
> 用来访问 Google / X / YouTube 查资料学习，同时**不影响国内网站的访问速度**。

![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)
![Admin](https://img.shields.io/badge/admin-not%20required-success)
![Kernel](https://img.shields.io/badge/kernel-Mihomo%20Meta-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## 这个项目解决什么问题

国内直连 Google 会失败，而且往往不只是"IP 被墙"，还有 **DNS 投毒**。
本机实测：

```
www.google.com  直连  -> HTTP 000（6 秒超时）
www.google.com  解析  -> 157.240.7.20   ← 这是 Facebook 的 IP，典型的 DNS 投毒
x.com           直连  -> TCP 可连，但 443 握手拿不到响应
github.com      直连  -> HTTP 200（可以直连）
```

所以只挂一个代理还不够，必须同时解决 **DNS 污染** 和 **流量分流**：

- 不分流 → 所有流量绕道美国，国内网站从 0.1 秒变成 3 秒
- 不防污染 DNS → 拿到假 IP，怎么连都连不上

本项目把这两件事一起做掉，并且做到 **零管理员权限**。

---

## 核心亮点

**1. 完全不需要管理员权限**

这是本项目最有技术含量的部分。三条路线逐层排除：

| 方案 | 结果 | 原因 |
| --- | --- | --- |
| TUN 虚拟网卡 | ✗ 需要提权 | 要装驱动、改路由 |
| WARP 官方客户端 | ✗ 双重不可行 | 走 WireGuard **UDP 2408（实测被封）**，且需管理员装驱动 |
| **MASQUE over QUIC 443** | **✓ 可行** | 伪装成 HTTPS/HTTP3 流量，官方说明无需提权 |

实测端口探测结果决定了选型：

```
WireGuard  UDP 2408                          -> 不通（被封）
MASQUE     QUIC 443                          -> 可达  ← 走这条
1.1.1.1    DNS 53 / DoT 853                  -> 可达，且无污染
pkg.cloudflareclient.com                     -> HTTP 200
```

因此改用第三方 MASQUE 客户端 [usque](https://github.com/Diniboy1123/usque)
作为上游，由 [Mihomo Meta](https://github.com/MetaCubeX/mihomo) 负责分流。

**2. 智能分流：国内直连，国外走代理**

| 域名 | 命中规则 | 走向 | 实测耗时 |
| --- | --- | --- | --- |
| `www.baidu.com` | `GEOSITE,cn` | DIRECT | **0.07 s** |
| `www.google.com` | `GEOSITE,gfw` | PROXY | 1.5 s |
| `x.com` | `GEOSITE,gfw` | PROXY | 2.6 s |

内核日志可验证：

```
[TCP] www.baidu.com:443  match GeoSite(cn)     using DIRECT
[TCP] www.google.com:443 match GeoSite(gfw)    using PROXY[WARP-免费]
```

**3. DNS 防污染**

- `fake-ip` 模式：立即返回假 IP，真实解析交给上游，国外域名**根本不经过国内 DNS**
- 分层解析：国内域名走国内 DoH（保证 CDN 就近），国外域名走加密 DNS
- 兜底超时 800 ms，避免污染域名每次解析卡 5 秒

**4. 一条命令 / 一次双击就能用**

启动器会自动开启系统代理、检测浏览器是否需要重启、预热隧道、自检连通性。

---

## 快速开始

```powershell
git clone https://github.com/<你的用户名>/<仓库名>.git
cd <仓库名>

# 方式一：双击
#   启动代理.bat

# 方式二：命令行
cd scripts
.\ctl.ps1 -Action Start
```

首次运行 `ctl.ps1` 会自动下载内核（约 58 MB）与规则数据（约 28 MB）。
WARP 组件需要单独初始化一次：

```powershell
.\ctl.ps1 -Action WarpInstall     # 下载 usque
.\ctl.ps1 -Action WarpRegister    # 注册免费 WARP 账号
.\ctl.ps1 -Action Start
```

启动成功后自检会输出：

```
Google         HTTP 204       1.65s  通
X (推特)        HTTP 200       2.33s  通
GitHub         HTTP 200       4.47s  通
百度 (直连)      HTTP 200       0.17s  通
```

> **浏览器必须重启才能生效。** 已在运行的浏览器不会重新读取代理设置 ——
> 这和代理本身是否正常无关。`启动代理.bat` 会检测到并主动询问是否帮你重启。

---

## 目录结构

```
.
├── bin/                        # 内核与规则数据（.gitignore，首次运行自动下载）
│   ├── mihomo.exe
│   ├── geoip.dat / geosite.dat / geoip.metadb
│   └── ui/                     # Web 控制面板 metacubexd
├── config/
│   ├── config.yaml             # 主配置（DNS 防污染 + 分流规则 + 上游占位）
│   ├── config.runtime.yaml     # 运行时配置（含上游，由 Import 生成）
│   └── browser.pac             # 浏览器定向代理规则（可选方案）
├── scripts/
│   ├── ctl.ps1                 # 主控制器
│   ├── diag.ps1                # 端到端诊断
│   ├── system-proxy.ps1        # 系统代理开关
│   └── test_upstream.py        # 链路验证用最小上游（见「验证」）
├── 启动代理.bat                 # 双击启动（最常用）
├── 停止代理.bat
├── 菜单.bat                    # 总控制台
├── 网络诊断.bat
├── 浏览器设置.bat
├── 系统代理开关.bat
├── 创建桌面快捷方式.bat
├── start.bat / stop.bat / browser-setup.bat   # 英文别名
├── README.md
├── QUICKSTART.md
└── CHECKLIST.md
```

`bin/` 与 `logs/` 已在 `.gitignore` 中排除，克隆后首次运行会自动下载，无需手动准备。

---

## 常用命令

```powershell
cd scripts

.\ctl.ps1 -Action Check          # 环境体检
.\ctl.ps1 -Action Start          # 启动（自动拉起 WARP + 内核）
.\ctl.ps1 -Action Stop           # 停止
.\ctl.ps1 -Action Restart        # 重启
.\ctl.ps1 -Action Status         # 状态 + 节点延迟
.\ctl.ps1 -Action Test           # 连通性测试
.\ctl.ps1 -Action Switch -Node "WARP-免费"

.\ctl.ps1 -Action WarpStatus     # WARP 状态 + 出口 IP/机房
.\ctl.ps1 -Action WarpStart      # 单独启动 WARP
.\ctl.ps1 -Action WarpStop
.\ctl.ps1 -Action WarpInstall
.\ctl.ps1 -Action WarpRegister

.\ctl.ps1 -Action Import -Source "<订阅URL>"   # 换成商业订阅或自建节点
.\ctl.ps1 -Action Env            # 命令行工具代理环境变量
.\ctl.ps1 -Action Browser        # 浏览器代理配置指引
.\ctl.ps1 -Action Update         # 升级内核

.\diag.ps1                       # 端到端诊断
.\diag.ps1 -PacCheck             # 附带校验 PAC 规则
```

主控制器已接入 **mihomo External Controller API**：读写均显式按 UTF-8 处理
（PowerShell 5.1 在中文区域默认用 ANSI 解码 JSON，会破坏中文节点名）。

Web 面板：<http://127.0.0.1:9090/ui>

---

## 架构

```
应用层
 ├─ 浏览器 ──系统代理 / PAC──┐
 └─ 命令行 ──环境变量────────┤
                            ▼
              ┌─────────────────────────────┐
              │  本地代理 127.0.0.1:7890     │
              │  Mihomo Meta（仅回环监听）    │
              │  · 规则分流                  │
              │  · DNS 防污染 (fake-ip)      │
              │  · 协议转换                  │
              └───────────┬─────────────────┘
                          │
          ┌───────────────┴────────────────┐
     命中 CN 规则                    命中 !CN 规则
          │                                │
          ▼                                ▼
    ┌──────────┐              ┌────────────────────┐
    │  DIRECT  │              │  上游 127.0.0.1:1080│
    │  直连出境 │              │  usque MASQUE/QUIC  │
    └──────────┘              └─────────┬──────────┘
                                        ▼
                              Cloudflare WARP → Google / X
```

**安全设计**

| 项目 | 设置 | 原因 |
| --- | --- | --- |
| 监听地址 | `127.0.0.1` only | 不对局域网暴露，他人无法蹭用 |
| `allow-lan` | `false` | 同上，且无需开防火墙 |
| 控制面板 | 仅 `127.0.0.1:9090` | 外网不可达 |
| `ipv6` | 关闭 | 避免 IPv6 绕过代理泄漏真实流量 |
| 系统代理 | 启动时开 / 停止时关 | 保证浏览器可用，停止时自动还原避免断网 |

---

## 接入其他上游

本项目设计为 **上游无关**。默认用免费 WARP，但换成商业订阅或自建 VPS 无需改架构：

```powershell
.\ctl.ps1 -Action Import -Source "https://你的订阅链接"
# 或本地文件
.\ctl.ps1 -Action Import -Source "D:\sub.yaml"
```

脚本会自动拉取订阅、解析节点、生成 `config.runtime.yaml`、用内核自检、
再热重载到运行中的实例（`PUT /configs?force=true`），每一步都有校验。

自建 VPS 的成本参考：RackNerd 低价年付约 $22/年，
搬瓦工 / DMIT 走 CN2 GIA 等优化线路但价格更高。
推荐协议 **VLESS + REALITY + Vision**（无需域名与证书）。

---

## 已知限制

**免费 WARP 不是完美方案**，以下是重复实测数据，请据此建立预期：

| 站点 | 重复测试 | 说明 |
| --- | --- | --- |
| Google 搜索页 | 6 / 6 成功 | 1.5 ~ 1.9 s |
| X（推特） | 5 / 5 成功 | 1.7 ~ 3.4 s |
| Google 学术 | 2 / 3 成功 | 约有 1/3 概率需重试 |
| ChatGPT | 可达（403） | 403 为 Cloudflare 风控，非链路问题 |
| 百度（直连） | 3 / 3 成功 | 0.07 ~ 0.17 s |

- **约 10% ~ 30% 的请求可能超时**，刷新重试通常即可，属 WARP 隧道本身波动。
- **出口固定在洛杉矶（LAX）**，无法选地区；响应 1 ~ 3 秒，不适合追求秒开。
- **ChatGPT / Claude 不一定能登录**：能连上是第一步，出口 IP 被平台风控识别时仍可能被拒。
- **冷启动约 35 ~ 45 秒**：WARP 隧道需建连 + 预热，属正常现象。

如需长期稳定或稳定使用 AI 服务，建议换成自建 VPS 节点。

---

## 开发过程中修掉的真实缺陷

这些是实测踩出来的，记录下来供参考：

| # | 现象 | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 打不开网站，代理却测试正常 | 系统代理默认关闭，浏览器只在启动时读一次代理设置 | 启动器自动开关系统代理 + 检测浏览器重启 |
| 2 | 脚本报 31 个语法错误 | PowerShell 5.1 在中文区域把无 BOM 的 UTF-8 当 GBK | 所有 `.ps1` 写入 UTF-8 BOM |
| 3 | 批处理中文全变"锟斤拷" | 文件行尾是纯 LF，`cmd.exe` 要求 CRLF 导致解析错位 | 统一 CRLF + GBK 编码 |
| 4 | 自检全部超时 | WARP 隧道 idle 时才建连，自检跑在预热之前 | 启动流程加入预热探针 |
| 5 | 节点延迟恒为 `0 ms` | 健康检查 5 秒超时对 WARP 太紧 | 放宽到 10 秒，正确显示 356 ms |
| 6 | 中文节点名显示乱码 | `Invoke-RestMethod` 在中文 PS 5.1 下用 ANSI 解码 JSON | 改为读原始字节按 UTF-8 解码 |
| 7 | 误报"Google 不通" | 单次瞬时失败被当成故障 | 4 次重试 + 2 秒退避，连续失败才告警 |
| 8 | `diag.ps1` 段标题变报错 | 函数名 `H` 与内置别名 `Get-History` 冲突（**别名优先级高于函数**） | 改名 `Section` |
| 9 | 节点数误报为 3 | mihomo 还会返回 `PASS`/`PASS-RULE`/`REJECT-DROP` 内置代理 | 补全内置类型排除列表 |
| 10 | 文件完全无法写入 `E:` 盘 | FAT32 不支持硬链接，工具用原子重命名 | 改为直接写入；可执行文件移到 NTFS |

---

## 端到端验证

项目不只写了配置，链路经过实际验证。

由于无法获取真实上游，仓库提供一个最小上游代理
`scripts/test_upstream.py`，把它当作"节点"接入以验证全链路：

```
应用 → mihomo(7890) → 测试上游(8888) → 目标站点
```

**决定性实验**：注入规则 `DOMAIN-SUFFIX,baidu.com,PROXY` 强制百度走代理链路，
排除"百度走的是直连、根本没经过代理"的可能：

```
[TCP] www.baidu.com:443 match DomainSuffix(baidu.com) using PROXY[TEST-UPSTREAM-链路验证]
→ HTTP 200，0.12 s
[upstream] CONNECT www.baidu.com:443        ← 上游确实收到
```

同时 `google.com` 的失败日志定位到真正原因：

```
[upstream] CONNECT www.google.com:443  →  error: timed out
```

**请求已正确送达上游，只是测试上游本身没有出境能力** ——
证明分流与代理链路无误，缺的只是真实上游节点。

---

## 环境要求

- Windows 10 / 11
- PowerShell 5.1 或更高
- 无需管理员权限
- 约 100 MB 磁盘空间（内核 + 规则数据 + 面板）
- 建议使用 NTFS 分区；若放在 FAT32 可移动盘上，**运行期间请勿拔出**

## 技术栈

| 组件 | 版本 | 作用 |
| --- | --- | --- |
| [Mihomo Meta](https://github.com/MetaCubeX/mihomo) | v1.19.32 | 代理内核：分流、DNS、协议转换 |
| [usque](https://github.com/Diniboy1123/usque) | v4.2.1 | MASQUE 客户端，提供免提权 WARP 隧道 |
| [metacubexd](https://github.com/MetaCubeX/metacubexd) | latest | Web 控制面板 |
| meta-rules-dat | latest | GeoIP / GeoSite 分流规则数据 |

---

## 声明

- 本项目仅供**技术学习与正常资料查阅**使用。请遵守所在地区法律法规及目标平台服务条款。
- 使用免费 WARP 时流量经过 Cloudflare，请勿用于传输敏感信息。
- **请勿将代理端口暴露到公网**。本项目默认仅监听回环地址。
- 本项目不提供任何节点或订阅，使用者需自行准备上游。

## License

[MIT](LICENSE)
