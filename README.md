# DMR Pilot —— 连接 BrandMeister 的 iOS App

Swift + SwiftUI 写的 BrandMeister 客户端，三条腿：

1. **真协议连接**：以 MMDVM / Homebrew 热点身份登录 BrandMeister Master，完成 `RPTL → RPTK → RPTC` 握手，用 `RPTPING/MSTPONG`（或新版 `DMRP`）保持心跳，然后持续接收 `DMRD` 语音数据帧，本地聚合成实时通话列表。
2. **真的能出声**：`DMRD` 里的 33 字节载荷送进**纯 Swift 实现的 AMBE+2 半速率解码器**，还原成 8 kHz PCM 用 `AVAudioEngine` 播出来。整个声码器（FEC、反量化、谐波合成、增强、限幅）没有一个 C/C++ 文件，也不依赖第三方二进制。
3. **REST 查询**：`api.brandmeister.network/v2` 的设备详情与全球通话组名称表。

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
│   ├── HotspotView.swift        # 状态卡 + 电平表 + 实时通话
│   ├── DirectoryView.swift      # 设备查询 + 通话组搜索
│   ├── SettingsView.swift       # 身份 / 服务器 / 行为
│   ├── LogConsoleView.swift     # 十六进制协议日志
│   ├── Vocoder/                 # AMBE+2 半速率解码器（纯 Swift）
│   │   ├── HalfrateDecoder.swift    # 帧解码 + 丢帧隐藏 + 输出级
│   │   ├── HalfrateCore.swift       # 常量、定点饱和、快速 log2/exp2/sqrt、FFT
│   │   ├── HalfrateFec.swift        # Golay(23,12) / 交织 / 解扰
│   │   ├── HalfrateDequant.swift    # 码本预测反量化
│   │   ├── HalfrateSynth.swift      # 谐波合成 / 噪声 / 脉冲
│   │   ├── HalfrateOptions.swift    # 全部调音参数的默认值
│   │   ├── HalfrateTables.swift     # 从 C++ 生成的大表（13 万字节，勿手改）
│   │   └── DMRVoicePath.swift       # DMRD 载荷 → 3 个空中帧 → PCM
│   ├── Audio/
│   │   ├── VoicePipeline.swift  # 每路通话一个解码器 + 播放调度
│   │   └── VoicePlayer.swift    # AVAudioEngine 8 kHz 播放
│   └── Assets.xcassets
├── tools/
│   └── gen_tables.py            # 从 DroidStar 源码抽取数值表生成 HalfrateTables.swift
└── README.md
```

---

## 跑起来

1. macOS 上装 **Xcode 16 或更新**（部署目标 iOS 16.0，Xcode 16 的 SDK 直接可编译）。
2. 双击 `DMRPilot.xcodeproj`。
3. 选中 `DMRPilot` target → *Signing & Capabilities* → 勾 **Automatically manage signing**，选自己的 Team。Bundle ID 已设为 `com.sjzcook.dmrpilot`，若你的开发者账号下这个名字被占用，改成 `com.sjzcook.dmrpilot.你的后缀` 即可。
4. 选真机或模拟器运行。模拟器可以验证 REST 查询；**UDP 热点连接建议真机**（模拟器共享宿主网络，收包行为不稳定）。
5. 打开「设置」页填三项：DMR ID、Hotspot 密码、（可选）呼号，然后点「保存并连接」。

> 如果工程打不开：新建一个 iOS App 工程（SwiftUI 模板），把 `DMRPilot/` 下**所有子目录**里的 `.swift` 都拖进去并勾选 target，效果一样。

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

**收到了 `DMRD` 但听不到声音**
1. 「热点」页的「语音播放」开关是不是关着？关着时仍会解码（统计和电平照常走），只是不出声。
2. 手机侧静音键拨了？`AVAudioSession` 用的是 `.playback`，静音开关不影响，但音量键会。
3. 「纠错比特」一直大于 12，说明 Golay 每帧都在纠错到极限，信号质量太差，解出来是噪声。
4. 电平表在跳但听不到：`已解码` 包数在涨说明解码确实在跑，检查系统输出是不是切到了蓝牙耳机。

**通话列表在动，但只有杂音**
多半是别人的通话用了你没订阅的时隙——能收到帧但载荷不完整。看日志里的 `TS1` / `TS2` 是否是你订阅的那个。

---

## 语音是怎么解出来的

DMR 每 20 ms 传 33 bit 的 AMBE+2 参数（2450 bit/s 语音 + 1150 bit/s 前向纠错），
还原成 PCM 需要半速率声码器。这个 App 里是**纯 Swift 移植**，整条链路分五层：

```
DMRD 53/55 字节
   └─ 33 字节载荷
        └─ DMRVoicePath.unpackFrames        重排成 3 × 9 字节空中帧
             └─ HRFec.decodeAirFrame        解交织 → Golay(23,12) → 解扰
                  └─ HRDecoder.decode       反量化 → 谐波合成 → 增强 → 限幅
                       └─ 3 × 160 = 480 个 8 kHz PCM 采样
                            └─ VoicePlayer  AVAudioEngine 升采样后播放
```

| 层 | 文件 | 做什么 |
|---|---|---|
| 拆帧 | `DMRVoicePath` | 216 个语音比特散在载荷 `0..13` 与 `20..32`，第 13 字节低半字节是嵌入式信令，要用第 19 字节低半字节替换 |
| 纠错 | `HRFec` | `channelPosition(i) = 4i - 71·(i/18)` 的 DMR 交织、Golay(23,12) 纠 3 位、23 位伪随机解扰 |
| 反量化 | `HRDequant` | 9 个参数字段（宽度 `{7,5,5,9,7,5,4,4,3}`），码本预测 ρ=0.65 |
| 合成 | `HRSynth` | 相位跟踪的正弦谐波、128/512 点 FFT 噪声、脉冲串、160 采样重叠相加 |
| 输出 | `HRDecoder` | 共振峰增强、高通、帧限幅、软限幅，最后饱和成 `Int16` |

数值必须逐位一致，所以所有浮点常量都按 C++ 里的十六进制浮点原样写过来
（例如 `0x1.186f18p-2` 必须写成 `0.273861289024353`，不能写成 `0.2734`），
大表则用 `tools/gen_tables.py` 从源码解析后生成，不手抄。

### 关于每一路通话

`VoicePipeline` 给每个 `src-dst-slot` 单独持有一个解码器。halfrate 是强状态的：
码本预测器、相位跟踪、增强滤波器都跨帧递推，两路共用一个解码器会互相污染。
没有收到语音头就撞进通话中间的情况也照常处理（自动补一次 `begin`）。

同一时刻只有一路真正出声（后到的接管）——两路同时播放只会互相盖住。

### 授权说明（请务必读完）

- 本目录 `Vocoder/` 下的解码器**移植自 [DroidStar](https://github.com/nostar/DroidStar) 的 `mbe/` 子系统**
  （原作者 David Rowe / N0MJS 等），该子系统以 **GPL-3.0-or-later** 发布。
  因此 `Vocoder/` 下的这些 Swift 文件同样受 GPL-3.0 约束：**分发二进制时必须提供完整源码**。
  若要放进 App Store，GPL-3.0 与 Apple 的分发条款存在已知冲突，需自行评估法务风险。
- AMBE+2 本身是 DVSI 的**专利技术**。开源实现（mbelib / halfrate）的专利状态在法律上
  并没有被明确豁免，商业分发有风险。个人实验、自用、开源分发（遵守 GPL）风险相对可控。
- App 只是「能听」，音质是软件声码器的水平：安静环境下可懂度不错，弱信号时会有金属声和
  断续——`HRDecoder` 的丢帧隐藏会在丢包时重复上一帧或渐入舒适噪声。这与硬件 AMBE-3000
  芯片的效果有差距，属正常现象。

---

## 可以继续加的功能

- Static / Dynamic Talkgroup 管理（需要 master 的 `RPTO` 选项帧，各 master 支持度不一）
- Talker Alias 解析（`DMRA` 帧，能把源 ID 显示成呼号）
- 按通话组/时隙过滤、离线缓存通话组名称表（现在是内存缓存，重启要重拉）
- 后台保活（`UIBackgroundModes` + `NWPathMonitor`，注意 App Store 审核对长期后台 UDP 比较敏感）
- 语音录音 / 回放（PCM 已经在手里，写个 `AVAudioFile` 就行）
- 把解码挪到独立串行队列（现在是主线程同步解码，25 包/秒时约 1–3 ms/包）

---

## 关于实测状态

- REST 端点已实测：`/v2/talkgroup` 返回 `{"91":"World-wide", ...}`；`/v2/device/262301` 返回完整设备 JSON（字段见 `Models.swift` 注释）。v1.0 已下线，全部走 v2。
- 协议层按 MMDVMHost / HBlink3 的公开实现对齐；声码器按 DroidStar 的 `mbe/` 逐函数移植，常量用十六进制浮点原样搬。
- 但**本机没有 Swift 工具链，全部代码未经真机编译验证**。首次编译若有零星报错（多为 SDK 版本差异导致的 API 签名），按提示改一处即可，不影响整体结构。
- 声码器正确性建议这样验：找一段已知内容的 DMR 录音，把 `DMRD` 载荷喂给 `DMRVoiceDecoder.decode(packet:)`，输出写进 WAV（8 kHz / 16 bit / 单声道）后与 DroidStar 的输出逐采样比对。
