# DMR Pilot —— 连接 BrandMeister 的 iOS App

Swift + SwiftUI 写的 BrandMeister 客户端，两条腿：

1. **真协议连接**：以 MMDVM / Homebrew 热点身份登录 BrandMeister Master，完成 `RPTL → RPTK → RPTC` 握手，用 `RPTPING/MSTPONG`（或新版 `DMRP`）保持心跳，然后持续接收 `DMRD` 语音数据帧，本地聚合成实时通话列表。
2. **REST 查询**：`api.brandmeister.network/v2` 的设备详情与全球通话组名称表。

> 语音不解码。DMR 空口是 AMBE+2 编码，解码器受 DVSI 专利限制，Swift 里没有合法实现。
> 所以这个 App 做到的是「真正在线 + 看清谁在呼叫哪个时隙」，而不是音频转发。详见文末。

---

## 目录结构

```
DMRApp/
├── DMRPilot.xcodeproj/          # 直接双击打开
│   └── project.pbxproj
├── DMRPilot/
│   ├── DMRPilotApp.swift        # @main
│   ├── AppState.swift           # 设置持久化 / 通话组缓存 / 我的设备
│   ├── Models.swift             # BmDevice / Settings / LiveCall / LogEntry
│   ├── BrandMeisterAPI.swift    # v2 REST 客户端
│   ├── HomebrewFrames.swift     # 协议帧编解码
│   ├── HomebrewClient.swift     # UDP / WebSocket 传输 + 登录状态机 + 心跳
│   ├── RootView.swift           # TabView
│   ├── HotspotView.swift        # 状态卡 + 实时通话
│   ├── DirectoryView.swift      # 设备查询 + 通话组搜索
│   ├── SettingsView.swift       # 身份 / 服务器 / 行为
│   ├── LogConsoleView.swift     # 十六进制协议日志
│   └── Assets.xcassets
└── README.md
```

---

## 跑起来

1. macOS 上装 **Xcode 16 或更新**（部署目标 iOS 16.0，Xcode 16 的 SDK 直接可编译）。
2. 双击 `DMRPilot.xcodeproj`。
3. 选中 `DMRPilot` target → *Signing & Capabilities* → 勾 **Automatically manage signing**，选自己的 Team，把 `PRODUCT_BUNDLE_IDENTIFIER` 改成你自己的（例如 `com.yourname.dmrpilot`）。
4. 选真机或模拟器运行。模拟器可以验证 REST 查询；**UDP 热点连接建议真机**（模拟器共享宿主网络，收包行为不稳定）。
5. 打开「设置」页填三项：DMR ID、Hotspot 密码、（可选）呼号，然后点「保存并连接」。

> 如果工程打不开：新建一个 iOS App 工程（SwiftUI 模板），把 `DMRPilot/` 下全部 `.swift` 拖进去并勾选 target，效果一样。

### BrandMeister 侧要准备什么

| 项 | 在哪拿 |
|---|---|
| **DMR ID**（热点自己的编号，不是你的个人 ID） | 自助页 SelfCare 创建 Hotspot 后分配 |
| **Hotspot Security 密码** | SelfCare → 你的热点 → Hotspot Security（不是网站账号密码） |
| 服务器 / 端口 | 默认 `api.brandmeister.network:62031`，不用改 |

在 SelfCare 里把热点设成 **Static Talkgroup** 或打开 Dynamic，否则你只会收到「没人说话」的心跳——这是最常见的新手坑。

---

## 协议实现说明

### 握手

```
App                          Master
 |── RPTL  (+id)  ─────────────▶|   8 字节
 |◀────────────  RPTACK (+id) ──|  10 字节
 |── RPTK  (+id + 20B 密码) ───▶|  28 字节
 |◀────────────  RPTACK ────────|
 |── RPTC  (302B 配置块) ──────▶|
 |◀────────────  RPTACK ────────|   ← 部分 master 不回这一帧，收到 DMRD 也算在线
 |── RPTPING (+id) ────────────▶|   每 5 秒
 |◀────────────  MSTPONG ───────|
 |◀────────────  DMRD ...  ─────|   语音/信令数据帧
```

- 登录失败：master 回 `MSTNAK`，App 直接停在「连接失败」并提示检查密码——不做无意义重试。
- 超时：15 秒收不到任何服务器数据包视为掉线，按设置里的开关决定是否 6 秒后自动重连。

### DMRD 帧布局（两种都兼容）

| 偏移 | 经典 53 字节 | 新版 55 字节（MMDVMHost 2024+） |
|---|---|---|
| 0–3 | `DMRD` | `DMRD` |
| 4 | 序列号 | 序列号 |
| 5–7 | 源 ID（3 字节） | 同 |
| 8–10 | 目的 ID / 通话组 | 同 |
| 11–14 | 热点/中继 ID | 同 |
| 15 | 标志位 | 同 |
| 16–17 / 16–19 | Stream ID（2 字节） | Stream ID（4 字节） |
| 18 / 20 | AMBE 载荷（33 字节） | 同 |
| 51,52 / 53,54 | BER, RSSI | 同 |

标志位第 15 字节：

- bit7 `0x80` → 时隙 2（否则时隙 1）
- bit6 `0x40` → 单呼（否则组呼）
- bit5 `0x20` → 数据同步（此时低 4 位是数据类型：`1` 语音头、`2` 语音结束、`3` CSBK）
- bit4 `0x10` → 语音同步帧
- 否则低 4 位是语音突发序号 `0..5`

`HomebrewFrames.parseDmr` 按长度自适应（`>= 55` 走新版偏移），所以接自建 HBLink、MMDVMHost 老版本、BrandMeister 都不会错位。

### 心跳两套

设置里「新版心跳 DMRP」：

- **关（默认）**：`RPTPING` + 4 字节 ID，配 53 字节帧 —— BrandMeister 传统链路
- **开**：`DMRP` + 4 字节 ID，配 55 字节帧 —— MMDVMHost 新版

服务器不认哪个，日志里会连续超时，切一下就知道。

---

## 常见问题

**`MSTNAK` / 一直登录超时**
1. 密码是不是网站账号密码？要的是 SelfCare → Hotspot Security 里那个。
2. DMR ID 是不是被别的设备占用了？同一个 ID 同时只允许一条连接，先把手机端 MMDVM 之类断掉。
3. 网络封了 UDP：换 Wi-Fi / 蜂窝试；企业网、部分公共热点会拦非标准 UDP。
4. 「服务器」别带 `https://`，只填域名。

**连上了但一直没通话**
热点没订阅通话组。SelfCare 里加 Static TG，或者在电台上用 Dynamic TG 呼叫一次。

**日志里看到 `DMRD` 但列表不动**
通话是别人用别的时隙/别的 TG —— 检查 `dst` 是不是你订阅的组。`TS2` 的数据帧在只订阅 TS1 的热点上不会来。

**收不到语音（重要）**
见下节，这是设计上的边界，不是 bug。

---

## 为什么不做语音

DMR 每 20 ms 传 33 bit 的 AMBE+2 参数，必须用 DVSI 的 AMBE-3000 芯片或授权软件声码器才能还原成 PCM。开源界只有 `mbelib` 这类实现，专利与授权状态不明确，放进 App Store 上架风险很大。

所以 `HomebrewClient` 只解析到「信令层 + 帧统计」，并在文件末尾留了 `AmbeDecoder` 协议占位：将来如果接入合规声码器（硬件模块或取得授权），实现 `decode(bits:) -> [Int16]?` 后用 `AVAudioEngine` 播放即可，上层不用动。

---

## 可以继续加的功能

- Static / Dynamic Talkgroup 管理（需要 master 的 `RPTO` 选项帧，各 master 支持度不一）
- Talker Alias 解析（`DMRA` 帧，能把源 ID 显示成呼号）
- 按通话组/时隙过滤、离线缓存通话组名称表（现在是内存缓存，重启要重拉）
- 后台保活（`UIBackgroundModes` + `NWPathMonitor`，注意 App Store 审核对长期后台 UDP 比较敏感）
- 语音热词/字幕（同样卡在 AMBE 解码）

---

## 关于实测状态

- REST 端点已实测：`/v2/talkgroup` 返回 `{"91":"World-wide", ...}`；`/v2/device/262301` 返回完整设备 JSON（字段见 `Models.swift` 注释）。v1.0 已下线，全部走 v2。
- 协议层按 MMDVMHost / HBlink3 的公开实现对齐，但**本机没有 Swift 工具链，代码未经真机编译验证**。首次编译若有零星报错（多为 SDK 版本差异导致的 API 签名），按提示改一处即可，不影响整体结构。
