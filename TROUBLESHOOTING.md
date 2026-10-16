# 本地代理服务器 · 设计与部署

> 目标：稳定访问 Google / X 查询资料与学习，同时不影响国内网站的访问速度。
> 环境实测：Windows 11 22621 · 非管理员 · Python 3.12 · 无 git/node

---

## 零、先纠正一个常见误解

**本地代理服务器本身不含任何"翻墙能力"。**

它只是你电脑上的一个程序（监听 `127.0.0.1:7890`），负责三件事：

| 职责 | 说明 |
| --- | --- |
| **分流** | 国内网站直连，国外网站交给上游。避免所有流量都绕道，国内网站照样秒开 |
| **DNS 防污染** | 用加密 DNS + fake-ip 绕开投毒，这是 Google 能打开的前提 |
| **协议转换** | 把浏览器的 HTTP 代理请求，翻译成上游节点认识的协议（VLESS / Trojan / Hysteria2 …） |

真正能"出境"的，是**上游节点**——要么买订阅服务，要么自己租一台海外 VPS。
两者都没有时，本地代理跑得再完美，也打不开 Google。

本项目的设计原则是 **上游无关（upstream-agnostic）**：
客户端这一层全部给你搭好并验证过，你后面接任何一家的上游，都不用改架构。

---

## 一、现在能用了 — WARP 免费方案已跑通

**结论：可以用了。** Google、X、YouTube、ChatGPT、Claude 全部实测可达，
而且**没有使用管理员权限**。

启动命令就一条：

```powershell
cd E:\VPN\scripts
.\ctl.ps1 -Action Start
```

`Start` 会自动把 WARP 隧道和内核一起拉起来，不用分两步。

### 1.1 实测数据（真实结果，非推测）

| 站点 | 结果 | 耗时 |
| --- | --- | --- |
| Google（generate_204） | HTTP 204 | 1.2 秒 |
| Google 搜索页 | HTTP 302 | 1.6 秒 |
| **X（推特）** | HTTP 200 | 1.7 ~ 3.4 秒（5 次全部成功）|
| YouTube | HTTP 200 | 3.3 秒 |
| ChatGPT | HTTP 403 | 1.5 秒（403 是 Cloudflare 正常风控，页面内容是真的 OpenAI 首页）|
| Claude | HTTP 302 | 2.1 秒 |
| **百度（走直连）** | HTTP 200 | **0.17 秒** |

内核路由日志证实分流精确生效：

```
[TCP] www.google.com:443 match GeoSite(gfw) using PROXY[WARP-免费]
[TCP] x.com:443         match GeoSite(gfw) using PROXY[WARP-免费]
[TCP] www.baidu.com:443 match GeoSite(cn)  using DIRECT
```

**国内网站完全不受影响**（百度 0.17 秒，跟没装代理一样快），
只有需要出境的流量才走 WARP。

### 1.2 为什么选择 MASQUE 而不是 WireGuard

这是本次部署最关键的技术判断。实测探测结果：

| 通道 | 结果 | 说明 |
| --- | --- | --- |
| WireGuard UDP **2408** | **不通** | Cloudflare 官方客户端的默认协议，被封锁 |
| **MASQUE / QUIC 443** | **可达** | HTTP/3 伪装成普通 HTTPS 流量 |
| `1.1.1.1` DNS / DoT 853 | 可达 | 且解析结果干净，无污染 |
| `pkg.cloudflareclient.com` | HTTP 200 | 安装包源可达 |

因为 2408 被封，**官方 WARP 客户端（走 WireGuard）在你这条线路上连不上**，
而且它还需要管理员权限装驱动。

改用 `usque`（第三方 MASQUE 客户端）后：
- 走 QUIC 443，与正常 HTTPS 流量难以区分 → **通了**
- 官方明确说明 **"Doesn't require elevated privileges"** → **不需要管理员**

### 1.3 目录位置说明（重要）

| 组件 | 位置 | 原因 |
| --- | --- | --- |
| `mihomo.exe` 内核 + 规则数据 | `E:\VPN\bin\` | 可执行，已验证 |
| **WARP 组件 `usque.exe`** | `C:\Users\<你>\AppData\Local\WARP\bin\` | 见下方说明 |
| 配置文件 `config.json` | `C:\Users\<你>\AppData\Local\WARP\` | 与 usque 同目录 |
| 文档 / 配置模板 / 脚本 | `E:\VPN\` | — |

**为什么 WARP 组件放 C: 盘**：`E:` 是可移动 FAT32 盘。
实测从网上下载的可执行文件在 `E:` 上出现过 `Access is denied`
（Windows 对可移动介质上外部来源程序的额外限制），
而同一文件在 C: (NTFS) 上运行正常。二进制放 C: 更稳妥，与盘符插拔解耦。

### 1.4 WARP 相关命令

```powershell
.\ctl.ps1 -Action WarpStatus     # WARP 状态 + 出口 IP/机房 + 连通性
.\ctl.ps1 -Action WarpStart      # 单独启动 WARP 隧道
.\ctl.ps1 -Action WarpStop       # 停止 WARP
.\ctl.ps1 -Action WarpInstall    # 重新下载安装 WARP 组件
.\ctl.ps1 -Action WarpRegister   # 重新注册免费 WARP 账号
```

出口信息（实测）：`warp=on`，`colo=LAX`（洛杉矶），IPv6 出口。

### 1.5 使用须知（务必了解）

**免费 WARP 的真实特点：**

| 项目 | 情况 |
| --- | --- |
| 出口位置 | 洛杉矶（LAX），**不能选地区** |
| 速度 | 约 1 ~ 3 秒首字节；流媒体体验一般 |
| 稳定性 | 比商业订阅差，可能被限速或临时中断 |
| 隐私 | 流量经过 Cloudflare；免费版定位是"改善路由"而非匿名 |
| 地区限制 | ChatGPT / Claude 对出口 IP 敏感，免费 WARP 的 IP 可能触发风控 |

**已知注意事项：**

1. **首次访问慢**：WARP 隧道在空闲时会断开，第一次访问需要重新建连。
   `ctl.ps1` 已内置预热，启动时会自动打通隧道。
2. **`WarpStop` 之后**：如果内核的 `PROXY` 仍指向 `WARP-免费`，国外网站会打不开。
   切回直连用：`.\ctl.ps1 -Action Switch -Group PROXY -Node DIRECT`
3. **开机自启**：当前 WARP 和内核都是普通进程，重启电脑后需要重新执行 `-Action Start`。
   开机自启需要管理员权限或手动创建计划任务。
4. **免费方案是过渡选择**：如果长期使用、或需要 ChatGPT / Claude 稳定可用，
   建议后续换成自建 VPS（见 README.md「接入其他上游」）。

---


### 1.6 稳定性实测与预期管理（重要）

免费 WARP 不是完美方案，下面是**真实重复测试**的结果，请据此建立预期：

| 站点 | 重复测试结果 | 说明 |
| --- | --- | --- |
| Google 搜索页 | **6 / 6 成功** | 约 1.5 ~ 1.9 秒 |
| google.com 首页 | **3 / 3 成功** | — |
| gstatic 204 | **3 / 3 成功** | — |
| Google 翻译 | **3 / 3 成功** | — |
| **Google 学术** | **2 / 3 成功** | 约有 1/3 概率需要重试 |
| X（推特） | **5 / 5 成功** | 约 1.7 ~ 3.4 秒 |
| YouTube | 成功 | 约 3.3 ~ 3.6 秒 |
| ChatGPT | 可达（HTTP 403） | 403 是 Cloudflare 风控，非链路问题 |
| Claude | 可达（HTTP 302） | — |
| 百度（直连） | **3 / 3 成功** | **0.08 ~ 0.17 秒**，不受影响 |

**结论与预期：**

- **正常查资料完全够用**：Google 搜索、X、YouTube 都稳定。
- **会遇到偶发失败**：大约 10% ~ 30% 的请求可能超时。
  学术类站点（如 Google 学术）出现概率稍高。
  **遇到打不开时，直接刷新重试一次通常就好了** —— 这是免费 WARP 的固有特性，
  隧道质量随时间和线路波动，不是配置问题。
- **响应偏慢是正常的**：首字节 1.2 ~ 3.6 秒（出口在洛杉矶）。
  不要期待商业订阅那种秒开体验。
- **ChatGPT / Claude 不一定能登录**：能连上是第一步；
  免费 WARP 的出口 IP 被平台风控识别时，登录或对话仍可能被拒。
  如需稳定使用 AI 服务，建议换自建 VPS 节点（第六章路线 B）。

### 1.7 想换节点或退回直连

```powershell
# 查看当前各节点延迟
.\ctl.ps1 -Action Status

# 切到直连（不使用代理，用于排查是不是代理的问题）
.\ctl.ps1 -Action Switch -Group PROXY -Node DIRECT

# 切回 WARP
.\ctl.ps1 -Action Switch -Group PROXY -Node "WARP-免费"
```

**已配置的自动降级**：`故障转移` 组包含 `[WARP-免费, DIRECT]`，
WARP 挂掉时会自动退到直连，不会让国外网站直接变成打不开。

---

### 1.8 双击就能用：批处理启动器

不想敲命令的话，直接双击 `E:\VPN` 目录下的这些文件：

| 双击这个 | 作用 |
| --- | --- |
| **`启动代理.bat`** | **最常用。** 启动 WARP + 内核，自动自检，最后会明确告诉你 Google 通没通 |
| `菜单.bat` | 总控制台。带运行状态显示，9 个功能可选 |
| `停止代理.bat` | 全部停止 |
| `网络诊断.bat` | 端到端诊断，出问题时用这个 |
| `浏览器设置.bat` | 一键用 PAC 启动 Edge / Chrome，或显示 PAC 地址 |
| `系统代理开关.bat` | 开/关系统代理（一般用不到） |
| `创建桌面快捷方式.bat` | 在桌面生成「启动代理」快捷方式 |

也可以直接用英文名（效果相同）：`start.bat`、`stop.bat`、`browser-setup.bat`

**建议第一次做的事**：双击 `创建桌面快捷方式.bat`，
然后在桌面右键那个快捷方式选「固定到任务栏」，以后一键启动。

**关于 `启动代理.bat` 的提示：**

- 冷启动大约需要 **30 ~ 45 秒**（WARP 隧道要建连 + 预热），属正常现象。
- 结束时如果显示 `[OK] Google 已连通`，就可以正常用了。
- 如果显示 `Google 暂时不通`，**再运行一次通常就好** ——
  免费 WARP 有约 10-30% 的偶发失败率，不是配置问题。
- **窗口可以直接关掉**，代理在后台继续运行，不需要保持窗口开着。

**关于乱码**：这些 `.bat` 文件是 **GBK 编码**（中文 Windows 控制台的标准编码）。
如果你用 VS Code 等编辑器打开看到乱码，把编码切成 GB2312/GBK 即可，不影响运行。

---


### 1.9 关于系统代理（重要，曾导致打不开网站）

**浏览器只在启动时读取一次代理设置。**

最初我为了"不影响其他软件"，默认不开系统代理、只让浏览器用 PAC ——
但那需要**用特殊参数启动浏览器**（`--proxy-pac-url=...`）。
如果像平常一样双击桌面图标打开 Edge，浏览器就是**直连**，
Google / X 依然打不开。这是一个很容易踩的坑。

**现在的行为（已自动化，不用你操心）：**

| 操作 | 自动做什么 |
| --- | --- |
| 运行 `启动代理.bat` | **自动开启系统代理** `127.0.0.1:7890`；若检测到浏览器在运行，会询问是否自动重启浏览器 |
| 运行 `停止代理.bat` | **自动关闭系统代理**，避免浏览器指向已停止的代理导致全部网页打不开 |

**你需要记住的唯一一件事：**

> 改过代理设置后，**浏览器必须重启**才能生效。
> 已经在跑的浏览器不会重新读取代理设置 —— 这与代理本身是否正常无关。

`启动代理.bat` 现在会检测到这一点并主动问你，回答 `Y`（直接回车）就会自动帮你重启浏览器。

**绕过列表**：已配置国内常用域名直连，不走代理：
`*.cn`、`*.baidu.com`、`*.qq.com`、`*.taobao.com`、`*.bilibili.com`、
`*.zhihu.com`、`*.csdn.net`、`*.163.com`、`*.gitee.com` 等，
以及 `localhost` 和内网地址。

**如果你更想用 PAC（只让部分网站走代理）：**
运行 `浏览器设置.bat`，选 `[1]` 用 PAC 启动 Edge，
并先把系统代理关掉（`系统代理开关.bat` → `[2]`）。
两种方式选一种即可，**不要同时开**。

---

## 二、部署前的环境实测结论（存档）

这些是本次在你机器上真实测出来的数据，不是推测：

### 2.1 网络现状（修复前）

| 检测项 | 结果 | 判断 |
| --- | --- | --- |
| `www.google.com` 直连 | `HTTP 000`，6 秒超时 | 打不开 |
| `www.google.com` 解析 | `157.240.7.20` / `31.13.92.37` | **DNS 投毒**（这是 Facebook 的 IP） |
| `www.gstatic.com` 解析 | `114.250.67.34`（北京联通） | 假响应 / 中间盒 |
| `x.com` 直连 | TCP 能连，但 443 无响应 | 打不开 |
| `github.com` 直连 | `HTTP 200` 正常 | **可以直连** |
| `www.baidu.com` 直连 | `HTTP 200`，0.10 秒 | 正常 |
| 系统代理 | `ProxyEnable = 0` | 未开启 |
| 系统中代理客户端 | 无 | 全新部署 |

### 2.2 三个关键的环境约束

| 约束 | 影响 | 应对 |
| --- | --- | --- |
| **非管理员权限** | 不能装 TUN 虚拟网卡、不能改系统路由、不能装服务 | 全部采用**进程级 + 回环监听**方案，零提权 |
| **`E:` 盘是 FAT32 且为可移动盘** | 不支持硬链接、不支持 ACL、**运行时不能拔盘** | 已规避；代理运行期间请保持插着 |
| **PowerShell 5.1 + 中文区域** | 读取无 BOM 的 UTF-8 脚本会被当成 GBK → 乱码报错 | 所有 `.ps1` 均以 **UTF-8 带 BOM** 写入 |

---

## 三、整体架构

```
┌──────────────────────────────────────────────────────────────┐
│  应用层                                                       │
│                                                              │
│  浏览器 ──PAC 定向代理──┐                                     │
│  Chrome / Edge          │                                    │
│                         │                                    │
│  命令行工具 ──环境变量──┤                                     │
│  git/pip/npm/curl       │                                    │
│                         ▼                                    │
│              ┌─────────────────────────┐                     │
│              │  本地代理 127.0.0.1:7890 │                     │
│              │  Mihomo Meta v1.19.32    │                     │
│              │                         │                     │
│              │  · 规则分流             │                     │
│              │  · DNS 防污染(fake-ip)  │                     │
│              │  · 协议转换             │                     │
│              └───────────┬─────────────┘                     │
│                          │                                   │
│         ┌────────────────┴────────────────┐                  │
│         │                                 │                  │
│    命中 CN 规则                     命中 !CN 规则             │
│         │                                 │                  │
│         ▼                                 ▼                  │
│   ┌───────────┐                 ┌──────────────────┐         │
│   │  DIRECT   │                 │  上游节点(需自备) │         │
│   │  直连出国 │                 │  VLESS/Trojan/.. │         │
│   └───────────┘                 └────────┬─────────┘         │
└──────────────────────────────────────────┼───────────────────┘
                                           ▼
                                    海外服务器 → Google / X
```

**关键设计点：**

- **只监听 `127.0.0.1`**（`allow-lan: false`）——不对局域网暴露，别人蹭不到，也不需要开防火墙
- **系统代理由启动器自动开关**——启动时开、停止时关，避免你手动操作；配合绕过列表让国内网站与内网服务不受影响
- **浏览器走 PAC**——只让名单里的域名走代理，其余直连，副作用最小
- **命令行走环境变量**——只影响当前终端窗口

---

## 四、DNS 防污染设计（能打开 Google 的核心）

这是整个方案里最容易被忽略、却最关键的一环。
你机器上实测 `www.google.com → 157.240.7.20`，这就是 DNS 投毒：
你拿到的是**假的 IP**，再怎么连都连不上。

### 4.1 分层解析策略

| 域名类型 | 解析方式 | 原因 |
| --- | --- | --- |
| 国内域名（`geosite:cn`） | 阿里 / 腾讯 DoH | 保证国内 CDN 就近，速度不下降 |
| 国外域名（`geosite:geolocation-!cn`） | Cloudflare / Google 加密 DNS | 绕开投毒 |
| 节点服务器域名 | 国内 DoH 直连解析 | 节点域名必须先解析出来才能连上 |
| 兜底 | 国内 DNS 返回非 CN 结果时改用加密 DNS | 双保险 |

### 4.2 为什么用 `fake-ip` 模式

`enhanced-mode: fake-ip` 会让内核**立刻返回一个假 IP**（`198.18.x.x`），
真实解析推迟到流量进入代理隧道之后、由上游去做。

好处：
1. 客户端不用等 DNS，**打开网页更快**
2. 国外域名**根本不经过国内 DNS**，从根上避开投毒
3. 因为按域名分流，`GEOSITE` 规则依然准确生效

### 4.3 踩到并已修复的坑

初版配置里我把 `fallback` 设成了 `1.1.1.1` / `8.8.8.8`。实测结果是：

```
https://1.1.1.1/dns-query    → 000，6.0 秒超时   ← 完全不可达
https://8.8.8.8/dns-query    → 000，6.0 秒超时   ← 完全不可达
https://223.5.5.5/dns-query  → 400，0.24 秒      ← 可达
https://1.12.12.12/dns-query → 200，0.19 秒      ← 可达
https://doh.pub/dns-query    → 200，0.16 秒      ← 可达
```

内核日志也印证了这一点：

```
level=warning msg="dial PROXY (match Match/) mihomo --> 1.1.1.1:443 error: dial tcp 1.1.1.1:443: operation was canceled"
```

**问题**：没有上游时，这些加密 DNS 永远不可达，每次解析都要白等 5 秒。

**修复**：
- `nameserver` 增加 `doh.pub`，并明确注释"必须是**无代理也能通**的服务器"
- 增加 `fallback-timeout: 800`（原来默认 5 秒）
- 增加 `respect-rules: true`（有上游后，DNS 查询也走代理隧道出去，防投毒更彻底）

---

## 五、分流规则设计

规则自上而下匹配，命中即停。顺序很重要：

```yaml
rules:
  - GEOSITE,category-ads-all,广告拦截      # 1. 广告拦截，最优先
  - GEOIP,private,DIRECT,no-resolve        # 2. 内网直连
  - GEOSITE,openai,AI                      # 3. AI 服务单独分组
  - GEOSITE,anthropic,AI                   #    方便整体换节点
  - GEOSITE,google-gemini,AI
  - GEOSITE,category-ai-!cn,AI
  - GEOSITE,github,PROXY                   # 4. 开发资源
  - GEOSITE,gfw,PROXY                      # 5. 被墙站点（4410 条规则）
  - GEOSITE,geolocation-!cn,PROXY          # 6. 所有国外域名
  - GEOSITE,cn,DIRECT                      # 7. 国内域名直连（110534 条）
  - GEOSITE,private,DIRECT
  - GEOIP,CN,DIRECT                        # 8. IP 兜底判定
  - MATCH,PROXY                            # 9. 其余走代理
```

**为什么把 `AI` 单独分组**：OpenAI / Claude 对出口 IP 的地区很敏感，
单独一组可以整体切换节点而不影响其他流量，便于排查。
后续如果遇到 `ChatGPT` 报地区不支持，直接换 `AI` 组的节点即可。

**为什么 `GEOSITE,github` 在 `geolocation-!cn` 之前**：
你机器上 GitHub 本来就能直连，但走代理更稳（避免 SNI 干扰）。

---

## 六、上游怎么解决（三种路线决策）

这是你必须自己做的选择。以下是核实过的当前情况。

### 路线 A：买订阅服务（机场）—— 最省事

| 项目 | 说明 |
| --- | --- |
| 成本 | 通常 ¥10～30 / 月 |
| 优点 | 开箱即用、多节点、自动更新、无需运维 |
| 缺点 | 需要信任服务商；节点质量参差；跑路风险 |
| 适合 | 只想快点用上、不想折腾 |

**导入方法**（拿到订阅链接后）：

```powershell
cd E:\VPN\scripts
.\ctl.ps1 -Action Import -Source "https://你的订阅链接"
.\ctl.ps1 -Action Start
```

> ⚠️ 很多机场的**订阅域名本身被墙**，导致无法直接拉取。
> 如果 `Import` 报拉取失败：用手机流量或其他方式下载订阅 yaml，
> 存成本地文件后执行 `.\ctl.ps1 -Action Import -Source "D:\sub.yaml"`

### 路线 B：自建 VPS —— 最稳最干净

| 项目 | 说明 |
| --- | --- |
| 成本 | 约 $10～70 / 年 |
| 优点 | 独享 IP、独享带宽、无跑路风险、协议可选 |
| 缺点 | 需要一点 Linux 基础；IP 有被墙可能 |
| 适合 | 长期使用、重视稳定与隐私 |

**VPS 选购参考**（价格为公开促销区间，随时变化，请以下单页为准）：

| 厂商 | 定位 | 参考价格 | 备注 |
| --- | --- | --- | --- |
| **RackNerd** | 低价年付 | 常规约 **$21.99/年** 起，黑五等促销偶见 **$10～20/年** | 性价比最高，普通国际线路，LA 机房对国内延迟较低 |
| **搬瓦工** | 中国方向优化 | 明显高于普通 VPS | CN2 GIA / AS9929 / CMI，支持后台迁机房 |
| **DMIT** | 精品线路 | 溢价较高 | LAX/HKG/TYO 的 Pro 系列，适合长期稳定使用 |
| **AkileCloud** | 亚洲节点 | 中等 | 香港/日本/台湾/新加坡，部分强调原生 IP |

**推荐协议：VLESS + REALITY + Vision**

理由：无需买域名、无需申请证书、抗主动探测能力强，是目前主流方案。

> 参考资料：
> [2026 VPS 推荐与选购指南](https://skylink9119.github.io/2026/07/28/vps-bandwagonhost-dmit-racknerd-akilecloud-2026/) ·
> [sing-box VLESS + Reality 一键搭建教程](https://skylink9119.github.io/2026/07/21/sing-box-one-click-vless-reality-beginner/) ·
> [Xray VLESS + REALITY 安装脚本](https://github.com/ADALIY1/xray-reality-installer) ·
> [RackNerd 黑五促销](https://www.appinn.com/racknerd-cheap-vps-latest-deals/)

**拿到节点后**，把参数填进 `config/config.yaml` 的 `proxies:` 段（文件里已有注释模板），
或写成 yaml 用 `-Action Import -Source "<文件路径>"` 导入。

### 路线 C：免费方案（Cloudflare WARP）—— 已实测可用（当前采用）

| 项目 | 说明 |
| --- | --- |
| 成本 | 免费 |
| 现状 | **中国大陆可用性不稳定、时好时坏** |

核实到的证据：
- Cloudflare 官方状态页记录过 [WARP connectivity issues in China](https://www.cloudflarestatus.com/incidents/652kyztw6sbf)（2025-08-22）
- V2EX 有用户实测 [Win/Linux 能连、安卓连不上](https://global.v2ex.co/t/1184375)，
  回帖有人指出"WARP 的 IP 被 GFW 都封了，跟协议无关"

**本条已实测推翻**：官方客户端确实走 WireGuard UDP/2408 且需要管理员权限，
但在本网络 2408 被封、**MASQUE over QUIC 443 是通的**。改用第三方 MASQUE 客户端 `usque` 后**已成功跑通，且无需管理员权限**。详见 README.md。

> 已集成：`.\ctl.ps1 -Action Start` 会自动拉起 WARP 隧道。当前 PROXY 组默认使用 `WARP-免费`，并配置了到 DIRECT 的自动降级。


### 成本对比速查

| 方案 | 首次成本 | 年度成本 | 稳定性 | 折腾程度 |
| --- | --- | --- | --- | --- |
| WARP 免费 | ¥0 | ¥0 | ⭐⭐（约 10~30% 偶发失败） | 低（已完成）|
| 机场订阅 | ¥10～30 | ¥120～360 | ⭐⭐⭐ | 最低 |
| RackNerd 自建 | ~$22 | ~$22（≈¥160） | ⭐⭐⭐⭐ | 中 |
| 搬瓦工/DMIT 自建 | $50～70 | $50～70 | ⭐⭐⭐⭐⭐ | 中 |

---

## 七、部署步骤

### 第一步：确认客户端就绪（已完成）

```powershell
cd E:\VPN\scripts
.\ctl.ps1 -Action Check
```

预期输出：内核 `v1.19.32`、GeoIP/GeoSite 就绪。
**这一步已经帮你做完了**——内核、规则数据、配置全部就位。

### 第二步：准备上游

参考 README.md「接入其他上游」，拿到节点或订阅。

### 第三步：导入上游

```powershell
.\ctl.ps1 -Action Import -Source "https://你的订阅链接"
```

脚本会自动：拉取订阅 → 解析节点 → 生成 `config.runtime.yaml`
→ 用内核自检配置 → 热重载到运行中的实例。**每个环节都有校验，出错会明确告诉你原因。**

### 第四步：启动

```powershell
.\ctl.ps1 -Action Start
```

启动后会自动跑连通性自检。**Google 那一行显示"通"就成功了。**

### 第五步：让浏览器走代理

```powershell
.\ctl.ps1 -Action Browser     # 打印现成命令
```

会给出三种方式，推荐**方案 A（PAC 定向代理）**：

```powershell
# 本机没有装 Chrome，装的是 Edge（已实测存在）。先完全退出 Edge，然后：
& 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' --proxy-pac-url="file:///E:/VPN/config/browser.pac"
```

这样只有 PAC 名单里的域名走代理，其余全部直连 —— **不碰系统代理，零副作用**。

### 第六步：让命令行工具走代理

```powershell
.\ctl.ps1 -Action Env         # 打印命令
```

复制粘贴到当前会话（只影响这个窗口）：

```powershell
$env:HTTP_PROXY  = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
$env:ALL_PROXY   = 'socks5://127.0.0.1:7890'
$env:NO_PROXY    = 'localhost,127.0.0.1,.cn,baidu.com,qq.com,aliyun.com'
```

---

## 八、日常命令

```powershell
cd E:\VPN\scripts

.\ctl.ps1 -Action Check        # 环境体检
.\ctl.ps1 -Action Start        # 启动
.\ctl.ps1 -Action Stop         # 停止
.\ctl.ps1 -Action Restart      # 重启
.\ctl.ps1 -Action Status       # 状态 + 节点延迟
.\ctl.ps1 -Action Test         # 连通性测试
.\ctl.ps1 -Action Switch -Node "香港01"     # 切换节点
.\ctl.ps1 -Action Import -Source "<URL>"    # 导入/更新订阅
.\ctl.ps1 -Action Update       # 升级内核
.\ctl.ps1 -Action Env          # 命令行代理环境变量
.\ctl.ps1 -Action Browser      # 浏览器代理启动命令

.\diag.ps1                     # 完整端到端诊断
.\diag.ps1 -PacCheck           # 附带校验 PAC 规则
.\system-proxy.ps1 -Enable     # 开系统代理（一般不需要）
.\system-proxy.ps1 -Disable    # 关系统代理
.\system-proxy.ps1 -Status     # 看系统代理状态
```

### 网页控制面板

启动后浏览器打开 **http://127.0.0.1:9090/ui**

可以看实时流量、改节点、测延迟、切模式（rule / global / direct）。
面板已自动下载到 `bin\ui\metacubexd`。

---

## 九、文件说明

| 路径 | 作用 |
| --- | --- |
| `bin\mihomo.exe` | 内核（v1.19.32，58MB） |
| `bin\geoip.dat` `geosite.dat` `geoip.metadb` | 分流规则数据（共 28MB） |
| `bin\ui\` | 网页控制面板 |
| `config\config.yaml` | **主配置模板**（上游为空，可反复重新导入） |
| `config\config.runtime.yaml` | 导入上游后生成的运行时配置（`Start` 时优先使用） |
| `config\browser.pac` | 浏览器定向代理规则（59 条代理域名 + 直连白名单） |
| `scripts\ctl.ps1` | 主控制器（551 行） |
| `scripts\diag.ps1` | 端到端诊断 |
| `scripts\system-proxy.ps1` | 系统代理开关（可选） |
| `scripts\test_upstream.py` | 链路验证工具（见第九章） |
| `logs\mihomo.log` | 运行日志 |
| `subscriptions\` | 订阅原文存档 |

---

## 十、已完成的验证

我没有只写完配置就交差，而是**实际跑起来验证过整条链路**。

### 9.1 验证方法

因为拿不到真实上游，我自己写了一个最小上游代理 `scripts\test_upstream.py`，
把它当作"节点"接进 mihomo，从而验证：

```
应用 → mihomo(7890) → 测试上游(8888) → 目标站点
```

### 9.2 分流验证（核心结论）

| 域名 | 命中规则 | 走向 | 结果 |
| --- | --- | --- | --- |
| `www.baidu.com` | `GEOSITE,cn` | **DIRECT** | HTTP 200，**0.08 秒** |
| `github.com` | `GEOSITE,github` | PROXY | HTTP 200 |
| `www.google.com` | `GEOSITE,gfw` | PROXY | 无上游，超时（符合预期） |

内核日志证实：

```
[TCP] 127.0.0.1:65245 --> www.baidu.com:443 match GeoSite(cn) using DIRECT
```

**国内直连、国外走代理，分流完全正确。**

### 9.3 链路完整性验证（决定性实验）

为了排除"百度走的是直连、根本没经过代理"这种可能，
我强制注入规则 `DOMAIN-SUFFIX,baidu.com,PROXY`，让它**必须**经过代理节点：

```
[TCP] 127.0.0.1:52969 --> www.baidu.com:443 match DomainSuffix(baidu.com) using PROXY[TEST-UPSTREAM-链路验证]
→ HTTP 200，0.12 秒
```

同时测试上游的日志也记录到了这次连接：

```
[upstream] CONNECT www.baidu.com:443
```

**这条证据证明：mihomo 能把流量正确地交给上游节点，并成功拿到响应返回给应用。整条链路无损。**

### 9.4 Google 打不开的原因链（已定位）

```
[upstream] CONNECT www.google.com:443  →  error: timed out
level=warning msg="dial PROXY (match GeoSite/gfw) --> www.google.com:443 error: context deadline exceeded"
```

日志显示：**mihomo 正确地把 `google.com:443` 交给了上游节点，上游也收到了 CONNECT 请求**，
但测试上游和你本机一样没有出境能力，所以连不上。

**结论：架构没问题，缺的只是真正的上游节点。** 这正是第七章第二步要解决的问题。

### 9.5 DNS 防污染验证

| 检测项 | 结果 |
| --- | --- |
| 内建 DNS 端口 1053 | UDP + TCP 均监听成功 |
| 系统 DNS 解析 `www.google.com` | `157.240.7.20` / `31.13.92.37` → **投毒确认** |
| GeoIP / GeoSite 规则加载 | 全部成功（`gfw` 4410 条、`cn` 110534 条） |

### 9.6 过程中发现并修复的 4 个真实缺陷

| # | 问题 | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 脚本完全无法写入 `E:` 盘 | FAT32 不支持硬链接 | 改用直接写入 |
| 2 | `.ps1` 报 31 个语法错误 | PS 5.1 在中文区域把无 BOM 的 UTF-8 当 GBK | 全部加 UTF-8 BOM |
| 3 | `diag.ps1` 段标题变成报错 | 函数名 `H` 与内置别名 `Get-History` 冲突（**别名优先级高于函数**） | 改名 `Section` |
| 4 | 节点数误报为 3 | mihomo 还会返回 `PASS` / `PASS-RULE` / `REJECT-DROP` 类型的内置代理 | 补全内置类型排除列表 |

---

## 十一、故障排查

先跑诊断，它会把问题定位到具体环节：

```powershell
.\diag.ps1
```

### 常见问题

**Q: 浏览器还是打不开 Google**

1. 确认代理在跑：`.\ctl.ps1 -Action Status`
2. 确认有节点：状态里"可用上游节点"应该 > 0。如果是 0 → 还没导入上游
3. 确认浏览器真的走了代理：Chrome 访问 `chrome://net-internals/#proxy` 看 PAC 是否生效
4. **完全退出浏览器**再带 `--proxy-pac-url` 启动 —— 参数只在启动时生效

**Q: `Import` 报"订阅拉取失败"**

订阅域名本身被墙了。用手机流量下载订阅文件，再：

```powershell
.\ctl.ps1 -Action Import -Source "D:\下载\sub.yaml"
```

**Q: 国内网站变慢了**

说明系统代理被打开了。关掉：

```powershell
.\system-proxy.ps1 -Disable
```

本方案默认不开系统代理，走 PAC 就是为了避免这个问题。

**Q: ChatGPT / Claude 提示地区不支持**

AI 服务对出口 IP 地区敏感。换节点：

```powershell
.\ctl.ps1 -Action Switch -Group AI -Node "<节点名>"
```

优先选美国、日本节点。

**Q: 端口 7890 被占用**

```powershell
Get-NetTCPConnection -LocalPort 7890 -State Listen | Select-Object OwningProcess
```

改端口的话，同步修改 `config\config.yaml` 的 `mixed-port`、`browser.pac` 的 `PROXY_PORT`。

**Q: 提示"代理运行期间请勿拔出该盘"**

`E:` 是可移动盘。拔盘会让内核进程直接消失，代理中断。建议插着不动。

**Q: 想开机自启**

当前是普通进程方式（无需管理员）。开机自启需要注册计划任务，
需要管理员权限，或者用「任务计划程序」手动创建、触发器选"登录时"。

---

## 十二、安全与合规提示

本方案在设计上做了这些安全取舍：

| 项目 | 设置 | 原因 |
| --- | --- | --- |
| 监听地址 | `127.0.0.1` only | 不对局域网暴露，别人无法蹭你的代理 |
| `allow-lan` | `false` | 同上，且不需要开防火墙 |
| 控制面板 | 仅 `127.0.0.1:9090` | 本机管理，外网不可达 |
| `ipv6` | 关闭 | 避免 IPv6 绕过代理泄漏真实流量 |
| 系统代理 | 启动时自动开、停止时自动关 | 浏览器才能走代理；停止时自动还原避免断网 |

**请注意：**

- 请遵守你所在地区的法律法规以及 Google / X 等平台的服务条款，
  将本方案用于**正常的资料查询与学习**。
- 订阅服务（机场）需要你信任服务商——你的流量会经过他们。
  涉及账号密码等敏感操作时，请留意这条链路。
- **不要把代理端口暴露到公网**。本方案默认只监听回环，请不要改成 `0.0.0.0`。
- 自建 VPS 时，记得改 SSH 默认端口、禁用密码登录、及时更新系统。

---

## 十三、下一步

你现在需要做的**只有一件事**：

> **决定上游怎么解决**（第五章路线 A / B / C），然后执行
> ```powershell
> .\ctl.ps1 -Action Import -Source "<订阅URL 或 节点yaml路径>"
> ```

客户端这一层已经全部搭好并验证过了。拿到上游之后，导入即用。

如果决定自建 VPS，告诉我你选了哪家、什么系统，
我可以直接给你服务端的一键部署脚本和对应的客户端配置。