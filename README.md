# DMR Pilot —— 连接 BrandMeister 的 iOS App

Swift + SwiftUI 写的 BrandMeister 客户端，三条腿：

1. **真协议连接**：以 MMDVM / Homebrew 热点身份登录 BrandMeister Master，完成 `RPTL → RPTK` 握手，用 `RPTPING/MSTPONG`（或新版 `DMRP`）保持心跳，然后持续接收 `DMRD` 语音数据帧，本地聚合成实时通话列表。
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

- **BrandMeister 的热点是 9 位 ID：7 位 Radio ID 后面追加两位别名。** 官方 openSPOT 说明的
  原话就是「填 7 位 Radio ID，需要第二台热点就在后面追加两位」。所以 DMR ID `4601234` + 别名 `01`
  → `460123401`，别名 `02` → `460123402`，换算就是 `DMR ID × 100 + 后缀`。
- **不想算就直接填 9 位**：设置 → 服务器 →「自定义热点 ID」，把 SelfCare → My Hotspots 里
  显示的那串数字原样贴进去，它优先于后缀换算。这是最不容易出错的方式。
- `0`（默认）：不上报后缀，直接用 7 位 DMR ID 登录。多数 BrandMeister master **不认**这种登录——
  密码校验可能照样通过，但后台「My Hotspots」里不会出现这台设备，也不会给它推任何语音。
  除非你确实是在连自建 HBLink / 私服，否则**至少填 `01`**。
- `1…99`：按上面的规则拼成 9 位 ID。选中后设置页会多出一行「登录热点 ID」实时显示结果，
  日志里会打 `登录 ID 460123401（DMR ID 4601234 + SSID 01）`。
- 这个 9 位 ID 必须和 SelfCare → My Hotspots 里显示的完全一致。**差一位的典型症状**：
  App 显示「已登录」、后台却看不到设备、收不到任何语音。
  （早期版本照抄 DroidStar 的 `×(100) + (后缀 − 1)`，填 `01` 得到 `…400`——一个 SelfCare 里
  不存在的别名。master 收得下密码，却在配置阶段直接回 `MSTCL` 把会话关掉，
  表现就是「刚连上就被服务器断开」。）
- `RPTL` / `RPTK` / `RPTC` / `RPTPING` 四个帧里的 4 字节 ID 用的都是这个热点 ID，
  这也是 master 认设备、判断「同一 ID 重复登录」的依据。
- DMR ID 必须填 7 位。填成 9 位热点 ID 再乘 100 会溢出 32 位，master 只会回 `MSTNAK`，
  所以客户端在发出 `RPTL` 之前就直接拦下来报错，不会白等超时。
- 反过来，如果某个热点在 SelfCare 里就是按 9 位 ID 注册的（少见），把 ESSID 留 0、DMR ID 直接填 9 位即可。


### 通话组（TG）筛选

位置：**热点页 → 通话组**（在「语音」上方那一块）。

- 输入号码点「确定」= 向这个组**订阅**一次（见下一节）；清空输入再点「确定」
  （或直接点「恢复收听全部通话组」）= 听全部。改完立刻生效，不用重连。
- 接收侧跟参考实现 DroidStar 一致：**服务器推什么就解什么**，不拿目的地址跟选中的 TG 比。
  BrandMeister 推的是「这台热点被订阅的组」，其中还包括 SelfCare 里配的 Static TG，
  跟你在 App 里选的很可能不是同一个。以前这里按 TG 硬丢帧，只要两者不一致就会表现成
  「订阅没建立、什么都不响」——其实语音一直在下来。热点页会多显示一行
  「服务器实际下发 TG xxxx」，就是这个原因。
- 想只听选中的那一个组：设置 → 行为 → 关掉「跟随服务器下发的通话组」，退化成严格过滤，
  这时页面才会出现「已跳过其它通话组 N 帧」。

在 SelfCare 里把热点设成 **Static Talkgroup** 或打开 Dynamic，否则你只会收到「没人说话」的心跳——这是最常见的新手坑。

### 订阅（激活动态 TG）

位置：设置 → 行为（开关与时隙）、热点页 → 通话组（点「确定」触发）。

- **连接成功后 2 秒**自动向设置里的通话组订阅一次；**点「确定」切换组**时也来一次。
  两者都受「连接后自动呼叫通话组」开关控制，时隙在「呼叫时隙」里选（默认 TS2）。
  延迟 2 秒是故意的：DroidStar 靠人按键，天然比上线晚几秒；自动发就得自己留出
  master 把热点登记进时隙的时间，否则第一帧会被丢掉。
- 一次订阅 = **一个完整的 DMR 发射**，共 8 帧，约 0.5 秒：

  ```
  Voice LC Header  →  6 个语音突发（一个完整超帧）  →  Voice Terminator
  ```

  6 个突发里第 0 个带音频同步字，第 1…4 个带**嵌入 LC** 分片，第 5 个只有 EMB。
  这段结构和 DroidStar 的 `encode_data()` 逐字节一致（见下面「嵌入 LC」）。
- 为什么必须这么做：Homebrew 协议**没有订阅指令**，master 只推它认为已订阅的 TG。
  BrandMeister 把「有人在这个 TG 上发射」当成动态订阅，所以想让服务器改推某个组，
  只能自己发一次。DroidStar 的 README 原话就是
  **「You must TX with a talkgroup entered to link to that talkgroup」**。
- 怎么确认订阅成功：订阅之后收到语音，日志会打
  `✅ TG 46001 的语音已下发，动态订阅生效`。
  如果下来的不是这个组，会明确写成
  `✅ 链路已收到语音，但服务器推的是 TG 46050（TS2），不是 46001 —— 可能 SelfCare 里挂的是静态组`。
- 补发策略跟 DroidStar 一样克制：**10 秒内一帧都没收到**才补一次（共 2 次），
  只要有任何 DMRD 帧下来就说明链路和订阅都活着，不再往别人的通话里插噪音。
  之后**每 15 秒**打一行流量摘要，这是排查这一步最有用的信息：

  ```
  ← 近期流量 15s：46001(TS1)×12 ← 当前组、91(TS1)×86，共 98 帧
  ```

  | 摘要里有什么 | 结论 |
  |---|---|
  | 有「← 当前组」 | 订阅成功，只是这一刻没人讲话（或之前那几秒刚好空白） |
  | 只有别的组 | 链路正常、订阅落在别的组上（Static TG）；默认已跟随播放，不必再折腾 |
  | `30 秒内没收到任何 DMRD 帧` | 服务器根本没向这台热点推流量：回 SelfCare 看这个 TG 有没有对热点开放 / 有没有配静态 TG |
  | 补发 2 次都没有任何帧 | 订阅帧本身没被接受：先确认 DMR ID / 热点 ID / 密码三者属于同一台设备 |

  切换「呼叫时隙」之后 App 会自动重新订阅一次（不用再点「确定」），否则时隙只在发送那一刻生效，改了等于没改。
- BM 的动态订阅静默一段时间（约 10 分钟）会被释放，释放后这个组就不再推下来。
  App 内置**自动续订**：连接期间只要当前组连续没有语音，超过「续订间隔」
  （设置 → 行为，5 / 8 / 10 分钟，默认 8）就自动补一次，日志里会写
  `TG 46001 已静默 8 分钟，自动续订动态订阅`。
  - 续订的是「服务器实际在推的那个组」（`serverTalkgroup`），不是设置里选的那个——
    续错组等于白发。
  - 基准时间不是定时器，而是「这个组最近一次有语音」——真有人在说话就一直不会续订。
  - 关掉「连接后自动呼叫通话组」时续订也一并停用（App 不该背着你发射）。
  - 续订同样会被「有人正在通话」挡下，等这一句说完再补。
- 语音头不是拼字符串，要三层编码：

  ```
  LC(9 字节) ──RS(12,9)──▶ 12 字节 ──BPTC(196,96)──▶ 33 字节 payload
  ```

  外加 slot type 的 `Golay(20,8)`、6 字节**数据同步字（MS 那一组：`0D 5D 7F 77 FD 75 70`）**、
  以及头/结束符各自异或的 CRC 常数
  （`0x96` / `0x99`）。实现逐行移植自 MMDVMHost 的 `RS129.cpp` / `BPTC19696.cpp` /
  `Hamming.cpp` / `Golay2087.cpp` / `Sync.cpp`，代码在 `DMRPilot/DMRCallFrames.swift`。
- **嵌入 LC**（`encode_embedded_data` / `get_embedded_data` / `get_emb_data`）：
  9 字节 LC 用 5 bit CRC（9 字节求和 mod 31）+ `Hamming(16,11)` 编成 128 bit，
  按 32 bit 一段分给突发 1…4，突发 5 只带 `DMREMB`。
  `DMREMB` 那 7 个信息位（色码 4 + LCSS 2）还要过一遍 **QR(16,7)** 加 9 位校验，
  表来自 DroidStar 的 `ENCODING_TABLE_1676`（128 项，已内联到 Swift）。
  没有这张表，`DMREMB` 就缺校验，对端会当「没有信令」，色码和 LC 分片全丢。
- **RS(12,9) 的反馈抽头必须是 `parity[2]`**。这里曾经写成 `parity[3]`、循环也从 `j = 3` 起，
  等于多算一级还把上一轮的余数又异或进去，三个校验字节全错。当时用「encode → decode 往返」
  验证过，看起来是对的——因为解码器也是照错的实现写的，两端一起错，往返当然通过。
  正确做法是和参考实现**逐字节比对 33 字节输出**。`tools/dmr_ref.py` 是 DroidStar
  `dmr.cpp` TX 路径的 Python 复刻（含 `full_lc_encode`、`encode_data`、嵌入 LC），
  `tools/dmr_check.py` 会把 Swift 里那套算法照抄一遍再和它比对：
  语音头 / 结束符 / 6 个突发在 TG 46001、91、CC 0/1/15 几种组合下**全部逐字节一致**。
- **同步字必须用 MS（移动台）那一组**：热点是 simplex，MMDVM 里 `duplex = false`，
  DroidStar 的 `addDMRDataSync(..., 0)` 走的也是 MS 分支。用成基站那组（`0D FF 57 D7 …`）
  等于告诉对端「这是中继台发的」，对端按 BS 解调会拿到坏 LC，这次发射在别人耳朵里根本不存在。
  语音突发同理，`DMR_SILENCE_DATA` 里不带同步字，必须按 `SYNC_MASK` 补
  `MS_SOURCED_AUDIO_SYNC`（`07 F7 D5 DD 57 DF D0`），否则对端认不出这是语音帧。
- **只有每个超帧的第 0 个突发带音频同步字**：`n = 计数 % 6`，`n == 0` 时第 13…19 字节
  写 `MS_SOURCED_AUDIO_SYNC`、`flags` 低 4 位 `0x10`；`n = 1…5` 时同样这 7 个字节放
  嵌入信令（LC 分片 + `DMREMB`），`flags` 低 4 位就是 `n`。
  全都写同步字是错的——对端会在不该出现同步的位置读到同步，整段解调失败。
- 有人正在通话时**不会**插播：插一个语音头进去会把这一句打断，所以这时跳过并写一行日志。
- 同一个组 3 秒内重复点「确定」会被节流拦住；换别的组立刻能发。
- 发射帧的源地址是 **7 位 DMR ID**（`settings.dmrId`），不是 9 位热点 ID：
  `DMRD` 的 src 字段只有 3 字节（最大 16777215），塞 `dmrId × 100 + 后缀` 会溢出成一个
  别人的 DMR ID。BrandMeister 按 peer 校验发射者身份，溢出后整帧会被丢弃，
  现象就是「订阅显示已发出，但这个组永远没有语音下来」。热点 ID 只放在 4 字节的 peer 字段里。
- 发出去的 `DMRD` 是 **55 字节标准帧**（与 MMDVMHost `CDMRNetwork::write` 逐字节一致）：
  streamId 占 **4 字节**（偏移 16–19）、载荷从 **偏移 20** 开始、尾部 BER / RSSI 各 1 字节。
  这里曾经写成「53 字节、streamId 2 字节、载荷从 18 开始」，整包错位 2 字节——
  master 按偏移 20 取载荷，读到的 LC 是坏的，语音头解析失败，动态订阅也就建不起来。


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
 |── RPTC  (302B 配置块) ──────▶|   默认就发（与 DroidStar 一致）
 |◀────────────  RPTACK/MSTACK ─|   第三个 RPTACK 才算 CONNECTED_RW，之后才收 DMRD
 |── RPTPING (+id) ────────────▶|   每 5 秒
 |◀────────────  MSTPONG ───────|
 |◀────────────  DMRD ...  ─────|   语音/信令数据帧
```

- **RPTK 必须做挑战应答**：密码不能直接发，要 `SHA256(RPTACK 里那 4 字节盐 ‖ 密码 UTF-8)`，共 40 字节。
  发明文 20 字节（旧版 28 字节帧）BrandMeister 一律回 `MSTNAK`——这是最容易踩的坑。
  老 HBlink / 部分自建网关只认明文，所以标准鉴权被拒后客户端会自动用明文再试一次，日志里会写明「兼容模式」。
- **RPTC 默认就发**，与参考实现 DroidStar 完全一致。它的 `DMR::process_udp` 是三段状态机：
  `CONNECTING → DMR_AUTH → DMR_CONF → setup_connection()`，只有收到**第三个** `RPTACK`
  （RPTC 的应答）才切到 `CONNECTED_RW`，在那之前收到的 `DMRD` 一律不处理。
  > 注意 DroidStar 的 RPTC 是**逐字节拼**的（`out.append('R'); …`），
  > 直接用 `grep RPTC` 搜是搜不到的——之前就是因为这个才误判成「它不发配置包」。

  帧本身是定长 302 字节：`RPTC(4) + id(4, 二进制) + 294`，字段表见
  [BrandMeister Homebrew 规范](https://wiki.brandmeister.network/index.php/Homebrew_repeater_protocol/Spec)，
  数字字段要零补齐（`%02u` → `"01"`），尾部必须用空格 `0x20` 而不是 NUL 补齐。
  万一服务器拒收（回 `MSTCL` 直接关会话），客户端会记下「本次不再发」，2 秒后按两段握手重连，
  不需要用户自己去关开关。
- `MSTNAK` 在这套协议里有两种含义，客户端靠「探针」区分：发一个 `RPTPING`，
  回 `MSTPONG` 说明链路是活的（只是不收 RPTC），直接上线；回 `MSTNAK` 说明会话已被清，
  按规范整轮重登（重发同一个包没用），最多两次。
- 登录失败：`MSTNAK` 按阶段给出不同提示 —— RPTL 阶段被拒是「ID 不认」（没注册 / 被占用 / ESSID 算错），
  RPTK 阶段被拒才是「密码不对」，RPTC 阶段被拒是配置包不被接受。
- 在线后被 `MSTNAK` 清会话：自动重登，连续 3 次就停下并提示「该 ID 正被另一条连接占用」，
  避免两台设备抢同一个 ID 时无限重连。
- **`MSTCL`（master 主动关会话）按阶段处理**，不再是「判失败 + 6 秒重连」的死循环：
  配置阶段被关 → 判定 RPTC 不被接受，本次自动改为不发配置包、2 秒后重连；
  在线被关 → 3 秒后重登，连续 2 次就停下并提示「这个 ID 正被另一台设备使用」；
  登录阶段被关 → 8 秒后重试（给服务器时间释放上一个会话），2 次后停下并提示核对 9 位 ID。
  最常见的原因其实是**登录 ID 不存在**（例如别名填成了 `00`）：master 照样接受 `RPTK`，
  到配置阶段才把整个会话关掉，所以日志里会看到「已鉴权 → 立刻 MSTCL」。
- **收帧只在 `online` 状态处理**（DroidStar 的 `status == CONNECTED_RW` 判断）：
  没走完握手时收到的 `DMRD` 只计数不播放，避免「界面显示未连接却在放音」。
- 超时：15 秒收不到任何服务器数据包视为掉线，按设置里的开关决定是否 6 秒后自动重连。

### DMRD 帧布局

| 偏移 | 长度 | 内容 |
|---|---|---|
| 0–3 | 4 | `DMRD` |
| 4 | 1 | 序列号 |
| 5–7 | 3 | 源 ID |
| 8–10 | 3 | 目的 ID / 通话组 |
| 11–14 | 4 | 热点 / 中继 ID（peer） |
| 15 | 1 | 标志位 |
| **16–19** | **4** | **Stream ID** |
| **20–52** | **33** | **AMBE / LC 载荷** |
| 53 | 1 | BER（可省） |
| 54 | 1 | RSSI（可省） |

- **53 字节版本只是省掉了 BER / RSSI 两个尾巴**，streamId 仍是 4 字节、载荷仍从 20 开始。
  以前按长度分「窄帧 / 宽帧」两套偏移是错的：HBlink3 读的是 `_data[16:20]` 与 `_data[20:53]`，
  参考实现（`BMClient.handleDMRD`）也是 `bytes[20..<53]`，两边都印证这一点。
- MMDVMHost 出站固定发 55 字节，本 App 跟随它。

标志位第 15 字节：

- bit7 `0x80` → 时隙 2（否则时隙 1）
- bit6 `0x40` → 单呼（否则组呼）
- bit5 `0x20` → 数据同步（此时低 4 位是数据类型：`1` 语音头、`2` 语音结束、`3` CSBK）
- bit4 `0x10` → 语音同步帧
- 否则低 4 位是语音突发序号 `0..5`

`HomebrewFrames.parseDmr` 统一按 4 字节 streamId / 偏移 20 解析，53 与 55 字节都能吃下。

### 色码（CC）要不要填

**连接不需要色码，接收也不需要。** 这是 Homebrew 协议本身决定的，跟「有没有配对」没有关系：

| 环节 | 有没有色码 |
|---|---|
| `RPTL` / `RPTK` / `RPTACK` / `RPTPING` / `DMRP` | **没有**，这些帧里根本没有 CC 字段 |
| `DMRD` 帧头（0–19 字节） | **没有**，只有源 / 目的 / peer / flags / streamId |
| 接收判定 | **没有**，DroidStar 的 `process_udp()` 只判 `长度 55 && "DMRD" && flags & 0x20 && status == CONNECTED_RW` |
| `RPTC` 配置包 | 有一个 `%02u` 字段，MMDVM 与 DroidStar 都**写死 `1`**，只是设备资料，不参与鉴权 |
| 我们发出的 33 字节载荷 | slot type 高 4 位（语音头 / 结束符）、嵌入信令 `DMREMB` 高 4 位 |

也就是说，CC 只是「空口上这一句语音属于哪个色码」，主要写给**收听方的电台**看：
对方的电台设了 CC 过滤，CC 不一致就会把这段语音当噪音静音掉。BrandMeister 侧既不校验、
也不按 CC 分发，所以它不会导致 `MSTNAK` / `MSTCL`，跟掉线、收不到语音都没有关系。

- 默认 `1`：BrandMeister 上绝大多数中继和热点用 CC1，跟着用就行。
- 只有明确知道目标中继用别的色码时才改（设置 → 行为 → 色码 CC，0…15）。
- 改完会像改时隙一样**自动重新订阅一次**，因为 CC 只体现在发出去的那几帧里。
- 参考实现 DroidStar 更能说明问题：它界面上有 CC 下拉，但那个值只喂给 MMDVM 硬件（`serialmodem.cpp`），
  网络路径里 `m_txcc` 从头到尾没被用过，`m_modeinfo.cc` 也没赋值——它对 BrandMeister 的 CC 完全不敏感。

### 心跳两套

设置里「新版心跳 DMRP」：

- **关（默认）**：`RPTPING` + 4 字节 ID（11 字节帧）—— BrandMeister 传统链路
- **开**：`DMRP` + 4 字节 ID（55 字节帧）—— MMDVMHost 新版

这里的 55 字节说的是**心跳帧**，和上面 DMRD 的长度没有关系。

服务器不认哪个，日志里会连续超时，切一下就知道。

---

## 常见问题

**`MSTNAK` / 一直登录超时**
1. 先看提示语分到哪一阶段：
   - 「不认这个热点 ID」——`RPTL` 就被拒。ID 没在 SelfCare 注册，或 9 位 ID 填错
     （把设置页显示的「登录热点 ID」和 SelfCare 里的号逐位对一遍）。
   - 「密码不对」——`RPTK` 被拒。密码是 SelfCare → Hotspot Security 里那个，不是网站登录密码；
     粘贴时带进空格、或带 iOS 智能引号都会失败（客户端会去掉首尾空白、把弯引号换成 ASCII，但密码本身就错就没辙）。
   - 「服务器主动断开连接（MSTCL）」——master 关掉了会话。看日志里括号中的**阶段**：
     配置阶段就是 `RPTC` 不被接受（客户端会自动改成不发并重连，不用手动管）；
     登录阶段多半是这个 9 位 ID 还被上一次会话占着，或它在 BM 上不存在 / 被停用——
     等半分钟再连，并到 SelfCare → My Hotspots 核对号码；
     在线期间则通常是同一个 ID 被另一台设备抢登。
2. DMR ID 是不是被别的设备占用了？同一个 ID 同时只允许一条连接，先把手机端 MMDVM / 电脑上的 MMDVMHost 断掉。
3. 网络封了 UDP：换 Wi-Fi / 蜂窝试；企业网、部分公共热点会拦非标准 UDP。
4. 「服务器」别带 `https://`，只填域名。
5. 日志里搜 `RPTK`：标准鉴权失败后客户端会自动用「兼容模式」明文再试一次，两次都 NAK 就确实是凭据问题。

**显示「已登录」，但 BrandMeister 后台 My Hotspots 里看不到设备**

这是「登录 ID 不对」的典型表现：master 只在 `RPTK` 阶段校验密码，密码对了就往下走，
到配置阶段发现这个 9 位 ID 不存在，才会回 `MSTCL` 把会话关掉。按顺序排除：

| 现象（看日志） | 原因 | 处理 |
|---|---|---|
| 有 `没填 ESSID：将以 7 位 DMR ID … 登录` | BrandMeister 的热点是 **9 位** ID | 设置 → 服务器 → ESSID 后缀填 `01` |
| `登录 ID 460123400`，SelfCare 里是 `460123401` | 老版本照抄 DroidStar 的「后缀 − 1」 | 升级到修正版；仍对不上就把 9 位数字填进「自定义热点 ID」 |
| 鉴权通过后立刻 `MSTCL` | 别名不存在 / 那台设备没在 SelfCare 注册 | 同上，用「自定义热点 ID」直接填 SelfCare 里显示的号码 |
| `BM 设备库查不到 460123401` | 这个 ID 在 BM 上没有设备 | 核对 SelfCare → My Hotspots，或在 Hotspot Security 重设密码后再连 |
| `BM 设备库核对：460123401 = 你的呼号` | ID 是对的，设备在线 | 后台刷新一下；语音要靠下面那条「订阅通话组」 |

**连上了但一直没通话**
热点没订阅通话组。SelfCare 里直接给这个热点配 Static TG（最可靠，TS1/TS2 各可以放一组），
或者在 App 里点「确定」向目标组订阅一次触发动态订阅（15 分钟无活动会被释放，App 会自动续订）。

**日志里看到 `DMRD` 但列表不动**
现在默认「跟随服务器下发的通话组」，收到就播，所以列表不动基本只剩一个原因：解码器初始化失败（看「语音」里的错误计数）。
如果关掉了「跟随」，那才需要检查 `dst` 是不是你选中的组——`TS2` 的数据帧在只订阅 TS1 的热点上不会来。

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
