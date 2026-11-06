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
│   ├── HostDirectory.swift      # DMRHosts.txt 下载 / 解析 / 缓存
│   ├── HostPickerField.swift    # 服务器弹出选择器 + Hostname 搜索
│   ├── CallsignDirectory.swift  # DMR ID → 呼号（RadioID.net 查询 + 本地缓存）
│   ├── DMRCallFrames.swift      # 语音头/结束符编码（RS + BPTC + Golay）+ DMRD 出站帧
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
│   └── Assets.xcassets          # AppIcon / AccentColor
├── Logo/                        # 图标设计稿与对比图
├── tools/
│   ├── gen_tables.py            # 从 DroidStar 源码抽取数值表生成 HalfrateTables.swift
│   └── gen_icon.py              # 用代码精确绘制 App icon
└── README.md
```

---

## 图标

`AppIcon-1024.png` 不是画的，是 `tools/gen_icon.py` 用代码算出来的：4 倍超采样后
LANCZOS 缩小，所以弧线和斜边在任何尺寸下都不发虚，也没有任何水印或版权问题。

设计取**手持台（HT）**的剪影：扬声器槽、屏幕里的通话波形、天线尖上两道信号弧。
之所以不用「竖杆 + 对称电波」，是因为那个构图和 WiFi 图标几乎同构，用户一眼会认错；
也试过八木天线和桁架塔，但在 60 pt 尺度下八木读成"梯子"、桁架糊成一团，都放弃了。

配色是深海军蓝底 `#0E1A2C`，符号纯白，波形用青→蓝渐变强调"这是数字语音不是模拟"。

要改配色或几何，直接调 `gen_icon.py` 顶部的常量再跑一次即可：

```bash
python tools/gen_icon.py
```

`Logo/compare.png` 里是四个候选（`ht` / `ht_plain` / `tower` / `slots`），
当前选用 `ht`。

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
| 服务器 / 端口 | 设置页下拉列表里选，自动带出域名与端口 |

### 服务器列表

设置页的服务器不再是手填文本框，而是从 Pi-Star 格式的服务器表里选：

- 数据源 `https://ds.vu3lvo.com/DMRHosts.txt`（镜像 `https://ds.vu3lvo.com/backup/DMRHosts.txt`），
  首次进入设置页自动下载并缓存到 `Caches/DMRHosts.txt`，之后启动直接读缓存，点「更新」才会重拉。
- 点服务器那一行会**弹出选择器**（半屏 / 全屏 sheet）：搜索框固定在列表上方，按域名（顺带匹配表里的名字）过滤；
  默认只列 BrandMeister 条目（42 台），切到「全部」能看到 XLX、DMR+、FreeDMR 等 1200 多条；
  右上角刷新按钮强制重下，选中即关闭并回填。
- 选中一台后自动写入 `host` / `port`，`hostName` 只用来回显选中态；选「自定义服务器」则露出域名输入框，
  自建 HBLink / 私服走这条路。
- 解析规则与参考实现一致：跳过 `DMRGateway` / `DMR2YSF` / `DMR2NXDN` 三条本机网关记录，
  第 3 列域名、第 4 列表内密码（`none` 视为空）、第 5 列端口；下载到 HTML 错误页时直接丢弃，不会污染缓存。

### ESSID 后缀

同一个 DMR ID 下要挂多个热点（或多台设备共用一个 ID），靠 ESSID 后缀区分。
位置：**设置 → 服务器 → ESSID 后缀**。

- `0`（默认）：不上报后缀，直接用 DMR ID 登录，行为和以前完全一样。
- `1…99`：上报 ID = `DMR ID × 100 + (后缀 − 1)`。例如 DMR ID `4601234` + 后缀 `01` → 热点 ID `460123400`，
  后缀 `02` → `460123401`（对应 MMDVM 里「ESSID 01/02」的说法）。
- 选中后缀后，设置页会多出一行「上报热点 ID」实时显示换算结果；「热点」页顶部的指标也会从 `DMR ID`
  改成 `热点 ID`，日志里会打一行 `热点 ID 460123400（DMR ID 4601234 + ESSID 后缀 1）`。
- `RPTL` / `RPTK` / `RPTC` / `RPTPING` 四个帧里的 4 字节 ID 用的都是这个热点 ID，
  这也是 master 认设备、判断「同一 ID 重复登录」的依据。
- DMR ID 必须填 7 位。填成 9 位热点 ID 再乘 100 会溢出 32 位，master 只会回 `MSTNAK`，
  所以客户端在发出 `RPTL` 之前就直接拦下来报错，不会白等超时。
- 反过来，如果某个热点在 SelfCare 里就是按 9 位 ID 注册的（少见），把 ESSID 留 0、DMR ID 直接填 9 位即可。


### 通话组（TG）筛选

位置：**热点页 → 通话组**（在「语音」上方那一块）。

- 输入号码点「确定」，App 只解码、播放、记账这个 TG 的语音；清空输入再点「确定」
  （或直接点「恢复收听全部通话组」）= 听全部。改完立刻生效，不用重连。
- 单呼不看过滤器：只要 `dst` 是本站点 ID，照样会响——私人呼叫不该被“只听某组”挡掉。
- 页面会显示「已跳过其它通话组 N 帧」：N 一直涨说明服务器在推、只是组对不上；
  N 不动而「收帧」在涨，说明服务器压根没推语音，回去查 SelfCare 的 Static TG。
- 点「确定」时除了改本地过滤，还会**向这个组发一次呼叫**（见下一节）——
  本地过滤只是「别的组不播」，要让服务器真的把语音推下来，得让它认为这个组被订阅了。

在 SelfCare 里把热点设成 **Static Talkgroup** 或打开 Dynamic，否则你只会收到「没人说话」的心跳——这是最常见的新手坑。

### 自动呼叫（激活动态 TG）

位置：设置 → 行为（开关与时隙）、热点页 → 通话组（点「确定」触发）。

- **连接成功后**自动向设置里的通话组发一次呼叫；**点「确定」切换组**时也发一次。
  两者都受「连接后自动呼叫通话组」开关控制，时隙在「呼叫时隙」里选（默认 TS2）。
- 一次呼叫 = 三帧：`Voice LC Header` → 一个静音语音突发 → `Voice Terminator`，间隔 120 ms，
  总共约 240 ms，听起来是一次极短的 PTT。
- 为什么必须这么做：Homebrew 协议**没有订阅指令**，master 只推它认为已订阅的 TG。
  BrandMeister 把「有人在这个 TG 上发射」当成动态订阅，所以想让服务器改推某个组，只能发一次呼叫。
  参考实现（DroidStar）在 Homebrew 下没有这个能力，它的主动订阅只在 ODTP（UDP 54006）上才有。
- 语音头不是拼字符串，要三层编码：

  ```
  LC(9 字节) ──RS(12,9)──▶ 12 字节 ──BPTC(196,96)──▶ 33 字节 payload
  ```

  外加 slot type 的 `Golay(20,8)`、6 字节数据同步字、以及头/结束符各自异或的 CRC 常数
  （`0x96` / `0x99`）。实现逐行移植自 MMDVMHost 的 `RS129.cpp` / `BPTC19696.cpp` /
  `Hamming.cpp` / `Golay2087.cpp` / `Sync.cpp`，代码在 `DMRPilot/DMRCallFrames.swift`。
- 有人正在通话时**不会**插播：插一个语音头进去会把这一句打断，所以这时跳过并写一行日志。
- 同一个组 3 秒内重复点「确定」会被节流拦住；换别的组立刻能发。
- 发出去的 `DMRD` 是**53 字节经典帧**（streamId 2 字节、payload 在偏移 18），
  HBlink 与 BrandMeister 都认，比新版 55 字节兼容性更好。


### 当前讲话人

位置：**热点页 → 通话组 下面**（「语音播放」上方）。显示这一句是谁在说：呼号、通话组、时隙、已说的时长，
右边是「讲话中 / 已结束」和一格实时电平。

- 呼号不是协议里带的。Homebrew 的 `DMRD` 帧头只有 3 字节源 ID 和 3 字节目的 ID，
  DMR 的 LC（呼号信息）不下发，所以只能外部补：
  1. RadioID.net 的 DMR 用户库 `database.radioid.net/api/dmr/user/?id=4601234`
  2. 查不到再退到 BrandMeister 设备库 `api.brandmeister.network/v2/device/{id}`（中继台、热点在这有呼号）
- 第一次听到某个人时会先显示数字 ID，查到后自动换成呼号；结果缓存在
  `Caches/callsigns.json`，之后完全离线也能显示。
- 查询是串行的、间隔 250 ms（RadioID 会限流）；同一个 ID 查不到时 10 分钟内不再重试。
- 查不到就一直显示数字 ID，这通常意味着该 ID 没在 RadioID 入库，或者它是网关 / 中继台。
- 「讲话中」的判定是「3 秒内还有语音帧」，因为部分 master 不推语音结束符；
  收到结束符则立刻变成「已结束」，并固定显示这一句说了多久。

---

## 协议实现说明

### 握手

```
App                          Master
 |── RPTL  (+id)  ─────────────▶|   8 字节
 |◀────────────  RPTACK (+盐) ──|  10 字节，后 4 字节是挑战盐
 |── RPTK  (+id + SHA256(盐‖密码)) ─▶|  40 字节
 |◀────────────  RPTACK ────────|
 |┈┈ RPTC  (302B 配置块) ┈┈┈┈▶|   ← 可选，默认不发（见下）
 |◀────────────  MSTACK ────────|     只有发了 RPTC 才会有
 |── RPTPING (+id) ────────────▶|   每 5 秒
 |◀────────────  MSTPONG ───────|
 |◀────────────  DMRD ...  ─────|   语音/信令数据帧
```

- **RPTK 必须做挑战应答**：密码不能直接发，要 `SHA256(RPTACK 里那 4 字节盐 ‖ 密码 UTF-8)`，共 40 字节。
  发明文 20 字节（旧版 28 字节帧）BrandMeister 一律回 `MSTNAK`——这是最容易踩的坑。
  老 HBlink / 部分自建网关只认明文，所以标准鉴权被拒后客户端会自动用明文再试一次，日志里会写明「兼容模式」。
- **RPTC 是可选的，默认不发**。当前 MMDVMHost 主线（`DMRNetwork.cpp`）已经彻底删掉了这个包，
  BrandMeister 照样正常工作——语音走的是 `DMRD`，配置包只喂给网页上的设备资料。部分 master
  收到它反而回 `MSTNAK`，把整轮登录判成失败。需要给老 HBLink 登记资料时，在
  **设置 → 服务器 → 上报配置包 RPTC** 打开。
  真发的时候它是定长 302 字节：`RPTC(4) + id(4, 二进制) + 294`，字段表见
  [BrandMeister Homebrew 规范](https://wiki.brandmeister.network/index.php/Homebrew_repeater_protocol/Spec)，
  数字字段要零补齐（`%02u` → `"01"`），尾部必须用空格 `0x20` 而不是 NUL 补齐。
- `MSTNAK` 在这套协议里有两种含义，客户端靠「探针」区分：发一个 `RPTPING`，
  回 `MSTPONG` 说明链路是活的（只是不收 RPTC），直接上线；回 `MSTNAK` 说明会话已被清，
  按规范整轮重登（重发同一个包没用），最多两次。
- 登录失败：`MSTNAK` 按阶段给出不同提示 —— RPTL 阶段被拒是「ID 不认」（没注册 / 被占用 / ESSID 算错），
  RPTK 阶段被拒才是「密码不对」，RPTC 阶段被拒是配置包不被接受。
- 在线后被 `MSTNAK` 清会话：自动重登，连续 3 次就停下并提示「该 ID 正被另一条连接占用」，
  避免两台设备抢同一个 ID 时无限重连。
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
1. 先看提示语分到哪一阶段：
   - 「不认这个热点 ID」——`RPTL` 就被拒。ID 没在 SelfCare 注册、9 位 ID 填错、或 **ESSID 后缀算错**
     （上报 ID = DMR ID × 100 + 后缀 − 1，把设置页显示的「上报热点 ID」和 SelfCare 里的号对一遍）。
   - 「密码不对」——`RPTK` 被拒。密码是 SelfCare → Hotspot Security 里那个，不是网站登录密码；
     粘贴时带进空格、或带 iOS 智能引号都会失败（客户端会去掉首尾空白、把弯引号换成 ASCII，但密码本身就错就没辙）。
   - 「上报配置被拒 / 配置包被拒」——`RPTC` 被拒。能走到这一步说明 ID 与密码都通过了。
     这个包本身是可选的：**设置 → 服务器 → 上报配置包 RPTC** 关掉就能连（默认就是关的）。
     打开的人多半是在连自建 HBLink 或要求登记资料的老 master，那种情况下再核对呼号是否填了、
     是否与 SelfCare 里登记的一致。
2. DMR ID 是不是被别的设备占用了？同一个 ID 同时只允许一条连接，先把手机端 MMDVM / 电脑上的 MMDVMHost 断掉。
3. 网络封了 UDP：换 Wi-Fi / 蜂窝试；企业网、部分公共热点会拦非标准 UDP。
4. 「服务器」别带 `https://`，只填域名。
5. 日志里搜 `RPTK`：标准鉴权失败后客户端会自动用「兼容模式」明文再试一次，两次都 NAK 就确实是凭据问题。

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
