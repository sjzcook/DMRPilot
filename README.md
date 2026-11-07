# DMR Pilot —— 连接 BrandMeister 的 iOS App

Swift + SwiftUI 写的 BrandMeister 客户端，两条链路 + 一条查询腿：

1. **ODTP（默认，BrandMeister 手机端现在走的这条）**：UDP **54006**，协议是 Rewind / Open DMR Terminal。
   `KEEP_ALIVE → CHALLENGE → AUTHENTICATION → SUBSCRIPTION`，订阅是**显式命令**（`type=7` 组呼），
   收到确认就开始推语音；语音帧直接就是 27 字节 mode-33 AMBE，喂给解码器就行，不用拆 LC、不用反交织。
   实现在 `DMRPilot/Core/RewindCore.cpp`。
2. **Homebrew（TGIF / FreeDMR / 自建网关）**：UDP **62031**，以 MMDVM 热点身份完成 `RPTL → RPTK → RPTC`
   三段握手，用 `RPTPING/MSTPONG` 保活，收 `DMRD` 55 字节帧。这个协议**没有订阅指令**，
   要靠连上后发一次静音发射让服务器记事。握手机器在 `DMRPilot/Core/DMRCore.cpp`（去 Qt 之后的 DroidStar `dmr.cpp` 直译）。
3. **真的能出声**：两条链路最终都交出 3 个 9 字节 AMBE 帧，交给 **DroidStar 的 `mbe/halfrate` 解码器**
   （C++ 原文件，`Core/Vocoder/`）还原成 8 kHz PCM，用 `AVAudioEngine` 播出来。
   不是重写：同一份源码、同一组听感参数，DroidStar 的 iOS 版跑的就是它。
4. **REST 查询**：`api.brandmeister.network/v2` 的设备详情与全球通话组名称表。

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
│   ├── Core/                    # ★ 协议核心 + 声码器（C++，DroidStar / DigestPlay 原文件，GPL-3.0）
│   │   ├── DMRCore.h                # 纯 C 接口：Homebrew
│   │   ├── DMRCore.cpp              # 握手状态机 + 组帧 / 拆帧 / 编码链
│   │   ├── RewindCore.h             # 纯 C 接口：ODTP / Rewind
│   │   ├── RewindCore.cpp           # KEEP_ALIVE 登录 + 显式订阅 + 27 字节语音帧
│   │   ├── HRCore.h                 # 纯 C 接口：AMBE+2 半速率解码
│   │   ├── HRCore.cpp               # 建解码器 + DroidStar 的 12 个听感参数
│   │   ├── DMRDefines.h             # 同步字、静音 AMBE、突发类型
│   │   ├── crs129.cpp               # RS(12,9) 12,9,3 里德-所罗门
│   │   ├── cbptc19696.cpp           # BPTC(196,96) 交织 + 汉明
│   │   ├── cgolay2087.cpp           # Golay(20,8) slot type
│   │   ├── chamming.cpp             # Hamming(16,11) 嵌入 LC
│   │   ├── CRCenc.cpp               # 嵌入 LC 的 CRC-5
│   │   ├── SHA256.cpp               # RPTK / AUTHENTICATION 的挑战应答
│   │   └── Vocoder/                 # ★ DroidStar mbe/halfrate 的解码闭包（原文件，未重写）
│   │       ├── halfrate.h               # C 接口（本仓库补了 reset / 带纠错数的变体）
│   │       ├── decoder_api.cc           # hr_decoder_new / hr_decode_air
│   │       ├── decoder.cc               # 帧解码：语音 / 静音 / 音调 / 擦除
│   │       ├── decoder_synth.cc         # 谐波合成、噪声、脉冲
│   │       ├── decoder_options.cc       # 全部调音参数与默认值
│   │       ├── decoder_tables.cc        # 谐波类 / 相位抽头 / 键盘音表
│   │       ├── dequant.cc               # 码本预测反量化
│   │       ├── enhance.cc               # 共振峰增强
│   │       ├── fec.cc                   # Golay(23,12) / 交织 / 解扰
│   │       ├── frame.cc / frame_layout.cc  # 49 bit ↔ 9 个参数字段
│   │       ├── fastmath.cc / fft.cc     # 定点 log2/exp2 / 128·512 点 FFT
│   │       ├── golay.cc                 # Golay 表
│   │       ├── codebook.cc / codebook_set.cc / cosine.cc / api.cc
│   │       └── （编码器那半边没编进来：encoder.cc / enc_pitch_net.cc 等）
│   ├── DMRPilot-Bridging-Header.h   # SWIFT_OBJC_BRIDGING_HEADER
│   ├── HomebrewClient.swift     # 传输 + 定时器 + 两条链路的分发 + 界面状态
│   ├── RootView.swift           # TabView
│   ├── HotspotView.swift        # 状态卡 + 电平表 + 实时通话
│   ├── DirectoryView.swift      # 设备查询 + 通话组搜索
│   ├── SettingsView.swift       # 身份 / 服务器 / 行为
│   ├── HostDirectory.swift      # DMRHosts.txt 下载 / 解析 / 缓存
│   ├── HostPickerField.swift    # 服务器弹出选择器 + Hostname 搜索
│   ├── CallsignDirectory.swift  # DMR ID → 呼号（RadioID.net 查询 + 本地缓存）
│   ├── LogConsoleView.swift     # 十六进制协议日志
│   ├── Vocoder/                 # 只剩发送方向的 Swift 编码器（解码已改走 Core/Vocoder）
│   │   ├── HalfrateEncoder.swift    # 分析 + 码本量化（PTT 用）
│   │   ├── HalfrateCore.swift       # 常量、定点饱和、快速 log2/exp2/sqrt、FFT
│   │   ├── HalfrateFec.swift        # Golay(23,12) / 交织 / 解扰（发送方向编码）
│   │   ├── HalfrateDequant.swift    # 反量化（编码器的闭环校验要用）
│   │   ├── HalfrateTables.swift     # 从 C++ 生成的大表（13 万字节，勿手改）
│   │   └── DMRVoicePath.swift       # 27 字节 AMBE → hrd_decode_packet → PCM
│   ├── Audio/
│   │   ├── VoicePipeline.swift  # 每路通话一个解码器 + 播放调度
│   │   ├── PttMicrophone.swift  # 麦克风采集 → 8 kHz / 160 采样
│   │   └── VoicePlayer.swift    # AVAudioEngine 8 kHz 播放
│   └── Assets.xcassets          # AppIcon / AccentColor
├── Logo/                        # 图标设计稿与对比图
├── tools/
│   ├── gen_tables.py            # 从 DroidStar 源码抽取数值表生成 HalfrateTables.swift
│   ├── core_check.py            # Homebrew 发射路径的逐字节核对（对着 DroidStar 的 Python 复刻）
│   ├── dmr_ref.py               # DroidStar 的 TX 路径 Python 复刻，core_check 的参照
│   ├── rewind_check.py          # ODTP 拼包 + 拆包双向核对（对着 BrandMeister 规范）
│   ├── vocoder_check.py         # 声码器静态自检：文件齐全 / include 自洽 / 符号有定义
│   ├── enc_check.py             # 编码器「量化 → 反量化」闭环检查
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
5. 打开「设置」页：先选**协议**（默认 ODTP），再填 DMR ID、密码、（Homebrew 下才需要）呼号，然后点「保存并连接」。

> 如果工程打不开：新建一个 iOS App 工程（SwiftUI 模板），把 `DMRPilot/` 下**所有子目录**里的 `.swift` 都拖进去并勾选 target，效果一样。

### BrandMeister 侧要准备什么

| 项 | ODTP（默认） | Homebrew |
|---|---|---|
| **ID** | **7 位 DMR ID**，不带后缀 | **9 位热点 ID**（7 位 + 两位别名） |
| **密码** | SelfCare 里给这台终端设的密码 | SelfCare → 你的热点 → Hotspot Security |
| 服务器 / 端口 | `<地区>.master.brandmeister.network` : **54006** | 设置页下拉列表里选，自动带出域名与端口（62031） |

两种都**不是**登录 BrandMeister 网站用的账号密码。

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


### 按住说话（PTT）

位置：**热点页 → 通话组上方的圆形 PTT 按钮**。

- **按住**开始发射，**松手**停止。松手是一次真实的 DMR 发射流程：
  `Voice LC Header` → 若干语音突发（每 60 ms 一个，每个装 3 个 20 ms 的 AMBE 帧）→ 结束符。
- 只有「已连接 + 已填通话组」时按钮才可用；未连接时按住不会做任何事（日志里也不会刷警告）。
- 首次按下会申请麦克风权限。拒绝之后按钮会提示去「设置 → DMRPilot → 麦克风」，
  改完回来不用重连。
- 发射期间**暂停播放**收到的语音：半双工，而且麦克风会把扬声器声音再收进去，变成回声。

链路（全部在设备上完成，没有任何外部服务）：

```
麦克风 48 kHz ──AVAudioConverter──▶ 8 kHz / 16 bit / 单声道
      ──每 160 采样一帧（20 ms）──▶ AMBE+2 编码（HalfrateEncoder）
      ──3 帧 = 27 字节──▶ 33 字节 DMR 载荷（音频同步字 / 嵌入 LC / DMREMB）
      ──DMRD──▶ 服务器
```

编码器是**分析 + 码本量化**，不是照抄某个参考实现（解码器有 DroidStar 可以逐行搬，
编码器没有）：

1. 归一化自相关估基音 → 选最近的码本音高索引（对数域比较，带 5% 迟滞，
   避免逐帧跳动听起来像颤音）；
2. 对每个谐波做单频 DFT（Goertzel）拿幅度，同时量「两个谐波中间」的电平；
3. 谐波明显高出中间电平 → 该频带判为浊音，再和 32 个清浊码字比对（只用 0…17，
   18 以上是脉冲/双音模式，用在语音上对端会解成嘀嘀声）；
4. 谐波幅度的均值 → 增益码本（要减掉上一帧带过来的 0.5 倍增益）；
5. 减掉预测与均值后的残差 → 分频带做正向 DCT，用 `shapeLow`(3 系数) / `shapeHigh`(4 系数)
   / `detail` 码字逼近，最后**用解码端的 `shapeResidual` 实际重建一遍算误差**，
   在 4×4 个候选里取最小的。

有两个坑值得记下来，都是这次踩出来的：

- **正向 DCT 不是转置就算**。`inverseDct` 用的是 DCT-III 归一化（第 0 行系数 1、其余 2），
  列范数是 `n` 与 `2n`，直接拿转置当正变换会把系数整体放大十几倍，码本搜索全落到边缘项，
  声音会变成一片沙沙的噪声。
- **绝对电平不能硬编码**。码本里的增益是归一化量，跟 16 位满幅差一个未知常数；
  写死一个偏移（比如「除以 256」）很可能轻得像耳语或者一开口就削顶。
  现在改成启动时用解码器做一次**探针标定**：用已知参数解几帧、量出 RMS，
  反推「RMS → 平均 log2 幅度」的偏移量。这样编码器和解码器天然对齐，
  换掉解码器的调音参数也不会跑偏。

`tools/enc_check.py` 是这套量化的 Python 镜像，跑一遍能看到闭环误差：

```
$ python tools/enc_check.py
== 平缓滚降（浊音）：pitch=40 count=17 ==
  frame 0: gain=30 low=260 high=78 details=[11, 14, 13, 1] 最大误差 0.85 bit
  ...
  平均最大误差 0.52 bit
```

0.5 bit 以内属于这套码本的正常量化粒度（增益步长本身就有 0.35 bit）。

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

> **协议不同，订阅方式完全不同。** ODTP 有一条真正的订阅命令，服务器会回确认包；
> 下面是 Homebrew 的做法——它没有订阅指令，只能靠「发一次静音发射」让服务器自己记事。
> ODTP 下点「确定」会直接发 `SUBSCRIPTION`，日志里看得到 `→ 已订阅 TG xxx` 和 `← 鉴权通过` 之后的确认。

- **连接成功后 2 秒**自动向设置里的通话组订阅一次；**点「确定」切换组**时也来一次。
  两者都受「连接后自动呼叫通话组」开关控制，时隙在「呼叫时隙」里选（默认 TS2）。
  延迟 2 秒是故意的：DroidStar 靠人按键，天然比上线晚几秒；自动发就得自己留出
  master 把热点登记进时隙的时间，否则第一帧会被丢掉。
- 一次订阅 = **一个完整的 DMR 发射**，共 14 帧，约 0.75 秒：

  ```
  Voice LC Header  →  12 个语音突发（两个超帧）  →  Voice Terminator
  ```

  12 个突发是刻意选的长度：一个超帧（6 个突发，360 ms）有时太短，master 还没来得及把这个
  peer 登记完帧就发完了；12 个接近真人「按一下话筒说两个字」，实测最容易让动态订阅落地。
  突发里第 0、6 个带音频同步字，其余带**嵌入 LC** 分片 / `DMREMB`——全由 C++ 核心按
  `(计数 - 1) % 6` 算，Swift 侧只管每 60 ms 要一帧。
  这段结构和 DroidStar 的 `encode_data()` 逐字节一致（见下面「嵌入 LC」）。
- 为什么必须这么做：Homebrew 协议**没有订阅指令**，master 只推它认为已订阅的 TG。
  BrandMeister 把「有人在这个 TG 上发射」当成动态订阅，所以想让服务器改推某个组，
  只能自己发一次。DroidStar 的 README 原话就是
  **「You must TX with a talkgroup entered to link to that talkgroup」**。
- 怎么确认订阅成功：不看订阅本身，看**下来的帧**。订阅之后**每 15 秒**会打一行流量摘要：

  ```
  ← 近期流量 15s：46001(TS1)×12 ← 当前组、91(TS1)×86，共 98 帧
  ```

  有「← 当前组」= 订阅成功，只是这一刻可能刚好没人讲话；只有别的组 = 订阅落在别的组上
  （SelfCare 里的静态组），默认已跟随播放，不必再折腾。

  | 摘要里有什么 | 结论 |
  |---|---|
  | 有「← 当前组」 | 订阅成功，只是这一刻没人讲话（或之前那几秒刚好空白） |
  | 只有别的组 | 链路正常、订阅落在别的组上（Static TG）；默认已跟随播放，不必再折腾 |
  | `30 秒内没收到任何 DMRD` | 服务器根本没向这台热点推流量：回 SelfCare 看这个 TG 有没有对热点开放 / 有没有配静态 TG |
  | 一直 0 帧 | 订阅帧本身没被接受：先确认 DMR ID / 热点 ID / 密码三者属于同一台设备 |

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
  （`0x96` / `0x99`）。这几个算法是 MMDVMHost 的 `RS129.cpp` / `BPTC19696.cpp` /
  `Hamming.cpp` / `Golay2087.cpp` / `Sync.cpp` 原文件搬进 `DMRPilot/Core/`（GPL-3.0），
  一行没改，由 `DMRCore.cpp` 调用。
- **嵌入 LC**（`encode_embedded_data` / `get_embedded_data` / `get_emb_data`）：
  9 字节 LC 用 5 bit CRC（9 字节求和 mod 31）+ `Hamming(16,11)` 编成 128 bit，
  按 32 bit 一段分给突发 1…4，突发 5 只带 `DMREMB`。
  `DMREMB` 那 7 个信息位（色码 4 + LCSS 2）还要过一遍 **QR(16,7)** 加 9 位校验，
  表来自 DroidStar 的 `ENCODING_TABLE_1676`（128 项，已内联到 `DMRCore.cpp`）。
  没有这张表，`DMREMB` 就缺校验，对端会当「没有信令」，色码和 LC 分片全丢。
- **RS(12,9) 的反馈抽头必须是 `parity[2]`**。这里曾经写成 `parity[3]`、循环也从 `j = 3` 起，
  等于多算一级还把上一轮的余数又异或进去，三个校验字节全错。当时用「encode → decode 往返」
  验证过，看起来是对的——因为解码器也是照错的实现写的，两端一起错，往返当然通过。
  正确做法是和参考实现**逐字节比对 33 字节输出**。`tools/dmr_ref.py` 是 DroidStar
  `dmr.cpp` TX 路径的 Python 复刻（含 `full_lc_encode`、`encode_data`、嵌入 LC），
  `tools/core_check.py` 则把 `DMRCore.cpp` 的发射状态机（含超帧计数、静音叠同步字）照抄一遍，
  和它逐字节比对：语音头 / 6 个突发 / 第二轮首突发 / 结束符在 TG 46001、91、CC 0/1/15、
  TS1/TS2 几种组合下**全部一致**，最后还做一次「突发 → 拆帧」往返。
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

### 先选链路

| | ODTP / Rewind | Homebrew |
|---|---|---|
| 端口 | **54006** | **62031** |
| 谁用 | BrandMeister（官方手机端 / DroidStar iOS 都走这条） | TGIF、FreeDMR、HBlink、自建网关 |
| 登录身份 | **7 位 DMR ID**（不带后缀）+ 终端密码 | **9 位热点 ID**（7 位 + 两位别名）+ Hotspot Security 密码 |
| 订阅 | **显式 `SUBSCRIPTION` 命令**，服务器回确认 | **没有订阅指令**，靠发一次静音发射 |
| 语音载荷 | 27 字节 mode-33 AMBE，直接用 | 33 字节 DMRD 载荷，要 RS / BPTC / 交织 / 同步字 |
| 时隙 / 色码 | 没有这些概念 | 都要自己凑（色码服务器其实不看） |

设置页「协议」一栏就是切这个，端口会跟着自动改。**默认是 ODTP**，因为 BrandMeister 上它比 Homebrew 稳：
Homebrew 那套要靠「按一次话筒」让服务器记住组，漏一次就整段静音；ODTP 的订阅有确认包，说得清。

### ODTP / Rewind（BrandMeister 54006）

协议来源：[BrandMeister Wiki · Open DMR Terminal Protocol](https://wiki.brandmeister.network/index.php/Open_DMR_Terminal_Protocol)
与参考实现 [DigestPlay（ODMRTP 分支）](https://github.com/BrandMeister/DigestPlay/tree/ODMRTP)。
字段与常量以该分支的 `Rewind.h` 为准，实现在 `DMRPilot/Core/RewindCore.cpp`。

**包结构：18 字节头 + 载荷，全部小端**

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0…7 | 8 | 签名 `REWIND01` |
| 8…9 | 2 | 类型 `REWIND_TYPE_*` |
| 10…11 | 2 | 标志（实时数据必须带 `REAL_TIME_1 = 0x0001`） |
| 12…15 | 4 | 序号 |
| 16…17 | 2 | 载荷长度 |
| 18… | n | 载荷 |

**登录（没有独立的 login 包）**

```
App                                  Master
 |── KEEP_ALIVE (VersionData) ───────▶|   number=7 位 DMR ID, service=0x21(Open Terminal), 后接软件名
 |◀──────────────── CHALLENGE (盐) ───|
 |── AUTHENTICATION (18B 头 + 32B) ──▶|   SHA256(盐 ‖ 密码)
 |◀──── KEEP_ALIVE（空）──────────────|   鉴权成功才回；失败**什么都不回**，只能等超时
 |── KEEP_ALIVE（心跳，顺便触发确认）─▶|
 |── SUBSCRIPTION (type=7, number=TG)▶|
 |◀──── SUBSCRIPTION（空）────────────|   订阅成功
 |◀──── DMR_DATA_BASE+1 / AUDIO / +2 ─|   语音头 / 语音帧 / 结束符
```

几处容易踩的点，都写在核心注释里了：

- **AUTHENTICATION 自己也要套 Rewind 头**：这一点最容易漏 —— `SHA256` 只算出 32 字节摘要，
  还得再拼上 18 字节头（`REWIND01` + type `0x0003` + 序号 + length=32）才能发出去。
  只发裸摘要的话，服务器连签名都认不出，直接丢弃、什么都不回，界面就永远停在「鉴权中」。
  `tools/rewind_check.py` 里专门有一条 `回包不是裸摘要：18 字节头 + 32 字节` 钉这个。
- **鉴权确认不看载荷长度**：参考实现 `RewindClient.c` 收到 `REWIND_TYPE_KEEP_ALIVE` 就直接去订阅，
  完全不检查 `length`。有些 master 会在确认里带上 VersionData，按「必须为空」硬判同样会卡在「鉴权中」。
- **服务器连续发三次挑战盐 = 密码不对**：摘要没通过时服务器不会回错误码，只会重新挑战。
  核心会计数，第三次直接报 `RW_EVT_AUTH_REJECTED`，不再空转。
- **两个序号计数器**：常规包一个、实时包（`DATA_BASE` 到 `AUDIO_FRAME`）一个。实时包用哪个计数器
  由 `flags & REAL_TIME_1` 决定，不是随便挑一个。
- **Remote ID 是 7 位**：规范原文「That DMR ID must not include the two-digit suffix commonly used for hotspots」。
  填 9 位会算出错误的 SHA256，症状就是「一直没反应」——因为失败时服务器**不回包**（不是回错误码）。
- **鉴权成功后客户端还要再发一次心跳**：参考实现 `ConnectRewindClient` 回完 `AUTHENTICATION` 就
  `continue` 回到循环顶部，等于紧接着又发一个 `KEEP_ALIVE`。本 App 照做，能兜住那些要等下个心跳才确认的 master。
- **重复帧必须同序号**：语音头和结束符各发 2～3 次提高投递率，但要用**同一个序号**（服务器按序号去重），
  所以 `rw_core_tx_header_again()` 会把计数器退回一格再拼包，而不是生成一个新序号。
- **长发射要插心跳**：连发 83 个语音帧（约 5 秒）就插一个 `KEEP_ALIVE`，与 DigestPlay 的 `count % 83` 一致。

**收语音**

语音头是 12 字节 Full LC，和 Homebrew 那条的 LC 内容一致，只是**不带纠错编码**：

```
byte0  flco(6) | reserved(1) | protect(1)     flco 0 = 组呼，3 = 单呼
byte1  FID                                    0
byte2  服务选项
byte3…5  目的地址（3 字节大端）
byte6…8  源地址（3 字节大端）
byte9…11 CRC                                 DigestPlay 全填 0，服务器不校验
```

`REWIND_TYPE_DMR_AUDIO_FRAME` 的载荷就是 **27 字节 = 3 × 9 字节 mode-33 AMBE**，
也就是 DMR 一个突发里的三帧。所以 ODTP 的接收路径比 Homebrew 短一截：不用找同步字、
不用反交织、不用 RS 纠错，`result.codec[27]` 直接进 `DMRVoicePath`。

> 调试口诀：`tools/rewind_check.py` 会把「拼包」和「拆包」两边都对着规范逐字节跑一遍。
> 收不到语音时先看日志里有没有 `← 鉴权通过` / `→ 已订阅 TG xxx` / `← 服务器返回失败码`，
> 三条分别对应「密码错 / 组没权限 / 根本没连上」。

### 握手（Homebrew）

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
  参考实现 DroidStar 也只走标准流程，核心同样只发 40 字节版本（明文版本只给老 HBlink 用，这里不再尝试）。
- **RPTC 默认就发**，与参考实现 DroidStar 完全一致。它的 `DMR::process_udp` 是三段状态机：
  `CONNECTING → DMR_AUTH → DMR_CONF → setup_connection()`，只有收到**第三个** `RPTACK`
  （RPTC 的应答）才切到 `CONNECTED_RW`，在那之前收到的 `DMRD` 一律不处理。
  > 注意 DroidStar 的 RPTC 是**逐字节拼**的（`out.append('R'); …`），
  > 直接用 `grep RPTC` 搜是搜不到的——之前就是因为这个才误判成「它不发配置包」。

  帧本身是定长 302 字节：`RPTC(4) + id(4, 二进制) + 294`，字段表见
  [BrandMeister Homebrew 规范](https://wiki.brandmeister.network/index.php/Homebrew_repeater_protocol/Spec)，
  数字字段要零补齐（`%02u` → `"01"`），尾部必须用空格 `0x20` 而不是 NUL 补齐。
  设置里可以关掉这个包，关掉后只走 `RPTL → RPTK` 两段——**非标准流程**，只给那些压根不认
  RPTC 的自建网关 / HBLink 用；BrandMeister 上请保持打开。
- **`MSTNAK` / `MSTCL` 一律按「服务器拒绝或关闭了这个会话」处理**，不再猜阶段：
  5 秒后重登，连续两次还不行就停下来说明原因（核对 9 位热点 ID、检查是否有别的设备用同一个 ID）。
  最常见的原因其实是**登录 ID 不存在**（例如别名叫 `00`）：master 照样接受 `RPTK`，
  到配置阶段才把整个会话关掉，所以日志里会看到「已鉴权 → 立刻 MSTCL」。
- **收帧只在 `online` 状态处理**（DroidStar 的 `status == CONNECTED_RW` 判断）：
  没走完握手时收到的 `DMRD` 只计数不播放，避免「界面显示未连接却在放音」。
- 超时：15 秒收不到任何服务器数据包视为掉线，按设置里的开关决定是否 6 秒后自动重连；
  配置阶段超时则提示去关掉「上报配置包 RPTC」再连一次。

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
- **接收侧 53 与 55 都收**（`len >= 53`）。参考实现 DroidStar 是 `buf.size() == 55` 硬判，
  在 BrandMeister 上够用；但 HBlink3 和不少自建网关发的是 53 字节，
  按 55 硬判会让这些服务器「握手成功、一帧语音都收不到」——这个坑踩过一次。
  两种长度的载荷都从第 20 字节开始、都是 33 字节，解出来的 LC 与语音完全一致。
- **发送侧固定 55 字节**，与 MMDVMHost 出站一致。

标志位第 15 字节：

- bit7 `0x80` → 时隙 2（否则时隙 1）
- bit6 `0x40` → 单呼（否则组呼）
- bit5 `0x20` → 数据同步（此时低 4 位是数据类型：`1` 语音头、`2` 语音结束、`3` CSBK）
- bit4 `0x10` → 语音同步帧
- 否则低 4 位是语音突发序号 `0..5`

`DMRCore` 的 `parse_dmr_head` 统一按 4 字节 streamId / 偏移 20 解析，并把 src / dst / peer / slot / 是否单呼 / 数据类型全部填进 `dmr_result_t` 交给 Swift。

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

### 心跳

只走 **`RPTPING` + 4 字节 ID（11 字节帧）**，服务器回 `MSTPONG`。这是 BrandMeister 传统链路，
也是参考实现 DroidStar 的做法。

以前设置里还有个「新版心跳 `DMRP`」开关（MMDVMHost 2024+ 的 55 字节心跳帧），
现在**已删除**：DroidStar 自己从不发 `DMRP`，BrandMeister 也不需要，留着只会让人以为
「连不上是因为心跳版本不对」。这里的 55 字节说的是心跳帧长度，和上面 DMRD 的长度没有关系。

---

## 常见问题

**ODTP（54006）连不上：一直停在「发送登录请求…」或「鉴权中…」**

ODTP 的失败表现和 Homebrew 完全不同——**鉴权失败时服务器一个包都不回**（规范如此），
所以只能靠超时看出来。按日志停在哪一步判断：

| 日志最后一行 | 含义 | 处理 |
|---|---|---|
| `→ KEEP_ALIVE 登录` 之后再无任何 `←` | 服务器没理这个连接 | 地址要是 `<地区>.master.brandmeister.network`，端口 **54006**；确认这个网络没封 UDP |
| `← 收到挑战盐，→ AUTHENTICATION（50 字节…）` 后没有下文 | 服务器没回鉴权确认 | 先看括号里的字节数：**50 = 18 字节头 + 32 字节摘要**才对；如果日志里是 32，说明包没套头（旧版本 bug）。字节数对就说明摘要没通过 → 密码错 |
| 反复出现 `← 收到挑战盐`（连续三次） | 摘要一直没通过 = **密码错** | 核对 SelfCare 里这台终端的密码；注意这里要的是**7 位 DMR ID**，不是 9 位热点 ID |
| `← 服务器要求重定向到 x.x.x.x:port` | master 让你换一台 | 按它给的地址改「设置 → 服务器」 |
| `← 鉴权通过` 但没有订阅确认 | 订阅没被接受 | 看有没有 `← 服务器返回失败码`；那个组可能没对这台终端开放 |
| `← 服务器返回失败码 N` | 订阅被拒 / 会话不被允许 | 换一个组试；或先到 SelfCare 确认这个 ID 有权收这个组 |
| `← 服务器：...` | 服务器的文本报告，通常写得很直白 | 按文字处理 |

另外两个坑：

- **不要填 9 位热点 ID**。规范写明 `RewindVersionData.number` 是「密码对应的那个 DMR ID，
  不能带热点常用的两位后缀」。填 9 位算出来的 SHA256 一定不对，而且失败时没有错误码，只表现为超时。
- **同一个 ID 不能同时登两台设备**（手机 + 盒子）。先登的那条会被后登的顶掉，日志里表现为连接不断被关。

**`MSTNAK` / 一直登录超时（Homebrew）**
1. 日志里那条 `← MSTNAK / MSTCL` 会带上**阶段**（`state.label`，如「发送登录请求…」「鉴权中…」「上报热点配置…」），
   按阶段判断：
   - 登录阶段就被拒 —— ID 不认。没在 SelfCare 注册、或 9 位 ID 填错
     （把设置页显示的「登录热点 ID」和 SelfCare 里的号逐位对一遍）。
   - 鉴权阶段被拒 —— 密码不对。密码是 SelfCare → Hotspot Security 里那个，不是网站登录密码；
     粘贴时带进空格、或带 iOS 智能引号都会失败（客户端会去掉首尾空白、把弯引号换成 ASCII，但密码本身就错就没辙）。
   - 上报配置阶段被关 —— master 主动关掉会话，多半是这个 9 位 ID 不存在 / 被停用，
     或还被上一次会话占着。等半分钟再连，并到 SelfCare → My Hotspots 核对号码。
   - 在线期间被关 —— 通常是同一个 ID 被另一台设备抢登。
2. DMR ID 是不是被别的设备占用了？同一个 ID 同时只允许一条连接，先把手机端 MMDVM / 电脑上的 MMDVMHost 断掉。
3. 网络封了 UDP：换 Wi-Fi / 蜂窝试；企业网、部分公共热点会拦非标准 UDP。
4. 「服务器」别带 `https://`，只填域名。
5. 日志里搜 `RPTK`：核心只发标准的 40 字节挑战应答版本，不会再发明文，所以看到 `RPTK` 后紧跟 `MSTNAK`
   就是凭据问题（密码错 / ID 与密码不属于同一台设备）。

**显示「已登录」，但 BrandMeister 后台 My Hotspots 里看不到设备**

这是「登录 ID 不对」的典型表现：master 只在 `RPTK` 阶段校验密码，密码对了就往下走，
到配置阶段发现这个 9 位 ID 不存在，才会回 `MSTCL` 把会话关掉。按顺序排除：

| 现象（看日志） | 原因 | 处理 |
|---|---|---|
| 日志里 `登录 ID 4601234（没填 ESSID，多数服务器不认）` | BrandMeister 的热点是 **9 位** ID | 设置 → 服务器 → ESSID 后缀填 `01` |
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

DMR 每 20 ms 传 49 bit 的 AMBE+2 参数（2450 bit/s 语音 + 1150 bit/s 前向纠错），
还原成 PCM 需要半速率声码器。拆帧在 C++ 协议核心里做（它本来就要解 LC），
解码则是 **DroidStar 的 `mbe/halfrate` 原文件**（`DMRPilot/Core/Vocoder/`），
经 `Core/HRCore.h` 的 `hrd_*` 接口调用 —— 不是重写，是同一份源码：

```
DMRD 55 字节
   └─ 33 字节载荷                    DMRCore.cpp（C++）
        └─ result.codec[27]          重排成 3 × 9 字节空中帧
             └─ hrd_decode_packet    HRCore.cpp（C++，套 DroidStar 的 12 个听感参数）
                  └─ hr_decode_air   Vocoder/decoder_api.cc
                       ├─ fec_decode_frame   Golay(23,12) + 解交织 + 解扰
                       └─ Decoder::decode_bits  反量化 → 谐波合成 → 增强 → 限幅
                            └─ 3 × 160 = 480 个 8 kHz PCM 采样
                                 └─ VoicePlayer  AVAudioEngine 升采样后播放
```

ODTP / Rewind 那条链路更短：`0x0920` 的载荷本身就是这 27 字节，直接进 `hrd_decode_packet`。

| 层 | 文件 | 做什么 |
|---|---|---|
| 拆帧 | `Core/DMRCore.cpp` | 216 个语音比特散在载荷 `0..13` 与 `20..32`，第 13 字节低半字节是嵌入式信令，要用第 19 字节低半字节替换；拆完的 27 字节随事件一起交给 Swift |
| 桥接 | `Core/HRCore.cpp` | 建解码器、套 12 个听感参数、一次吃完 27 字节、把纠错比特数带出来 |
| 纠错 | `Vocoder/fec.cc` | `channelPosition(i) = 4i - 71·(i/18)` 的 DMR 交织、Golay(23,12) 纠 3 位、23 位伪随机解扰 |
| 反量化 | `Vocoder/dequant.cc` | 9 个参数字段（宽度 `{7,5,5,9,7,5,4,4,3}`），码本预测 ρ=0.65 |
| 合成 | `Vocoder/decoder_synth.cc` | 相位跟踪的正弦谐波、FFT 噪声、脉冲串、160 采样重叠相加 |
| 输出 | `Vocoder/decoder.cc` | 共振峰增强、高通、帧限幅、软限幅，最后饱和成 `Int16` |

**为什么用原文件而不是继续用 Swift 移植**：`HalfrateDecoder/Dequant/Synth/Fec` 那套
（约 1700 行）虽然也是从同一份源码搬的，但浮点常量、码本索引、相位累加只要错一位，
听感就从「正常」变成「机器人」或「白噪声」，而这台机器没有 iOS 工具链，无法比对输出。
原文件编进来就没有这层风险 —— DroidStar 的 iOS 版跑的正是它。

> 参数这层也别漏：`ambe2.cc` 里有一组对着 DVSI 声码棒拟合出来的 12 个选项
> （输出增益 2.07、高频倾斜 0.5、共振峰增强 0.61…），`hr_decoder_new()` **不会**自动套用，
> 必须自己逐条 `hr_decoder_set`。这些在 `HRCore.cpp` 的 `kDecoderTuning` 里，
> 和 DroidStar 的 `kHalfrateDecoderTuning` 一字不差。少这 12 行，声音会明显偏薄。

### 关于每一路通话

`VoicePipeline` 给每个 `src-dst-slot` 单独持有一个解码器。halfrate 是强状态的：
码本预测器、相位跟踪、增强滤波器都跨帧递推，两路共用一个解码器会互相污染。
没有收到语音头就撞进通话中间的情况也照常处理（自动补一次 `begin`）。

同一时刻只有一路真正出声（后到的接管）——两路同时播放只会互相盖住。

### 授权说明（请务必读完）

- `DMRPilot/Core/` 下的协议核心是 [DroidStar](https://github.com/nostar/DroidStar) 的
  `dmr.cpp` 去 Qt 之后的直译，编码链的算法文件（`crs129` / `cbptc19696` / `cgolay2087` /
  `chamming` / `CRCenc` / `SHA256`）是 MMDVMHost 的原文件，两者都以 **GPL-3.0-or-later** 发布。
  因此 `Core/` 同样受 GPL-3.0 约束：**分发二进制时必须提供完整源码**。
- `Core/RewindCore.cpp` 是照着 [BrandMeister DigestPlay（ODMRTP 分支）](https://github.com/BrandMeister/DigestPlay/tree/ODMRTP)
  （作者 Artem Prilutskiy / R3ABM）的 `Rewind.h` / `RewindClient.c` 重写的，同样是 **GPL-3.0-or-later**。
- `Core/Vocoder/` 下那 17 个 `.cc` / 14 个 `.h` 是 [DroidStar](https://github.com/nostar/DroidStar)
  的 `mbe/halfrate` 子系统**原文件**（原作者 David Rowe / N0MJS 等），以 **GPL-3.0-or-later** 发布。
  本仓库只改了三处，都在文件里注明：删掉 `decoder_synth.cc` 里一行没用的 `#include <QtGlobal>`；
  给 `halfrate.h` / `decoder_api.cc` 补了 `hr_decoder_reset` 和带纠错数的 `hr_decode_air_errors`。
  其余一行未动，包括所有十六进制浮点常量。
- `Vocoder/` 下剩下的 Swift 文件是**发送方向**的编码器（PTT），同样移植自 `mbe/`，同样受 GPL-3.0 约束。
- 两处叠加的结果：**整个工程事实上是 GPL-3.0**。若要放进 App Store，GPL-3.0 与 Apple 的
  分发条款存在已知冲突，需自行评估法务风险。
- AMBE+2 本身是 DVSI 的**专利技术**。开源实现（mbelib / halfrate）的专利状态在法律上
  并没有被明确豁免，商业分发有风险。个人实验、自用、开源分发（遵守 GPL）风险相对可控。
- App 只是「能听」，音质是软件声码器的水平：安静环境下可懂度不错，弱信号时会有金属声和
  断续——halfrate 的擦除隐藏会在丢包时重复上一帧、静音、再渐入舒适噪声。这与硬件 AMBE-3000
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
- C++ 核心的**发射路径已做逐字节验证**：`tools/core_check.py` 把 `DMRCore.cpp` 的状态机照抄成 Python，
  与 `tools/dmr_ref.py`（DroidStar TX 路径的复刻）在 TG 46001 / 91、CC 0/1/15、TS1/TS2 下比对
  语音头 / 6 个突发 / 第二轮首突发 / 结束符，全部一致，并做了「突发 → 拆帧」往返。
- ODTP 那一层做了**收发双向**核对：`tools/rewind_check.py` 按 BrandMeister 规范检查 18 字节头、
  小端序、VersionData、订阅内容、语音头重发（同序号）、以及「服务器 → 客户端」的 CHALLENGE / 空 KEEP_ALIVE /
  语音头偏移 / 27 字节语音帧，全部一致。
- 声码器按 DroidStar 的 `mbe/` 逐函数移植，常量用十六进制浮点原样搬。
- 但**本机没有 Swift / Clang 工具链，全部代码未经真机编译验证**。首次编译若有零星报错
  （多为 SDK 版本差异导致的 API 签名，或桥接头路径），按提示改一处即可，不影响整体结构。
- 声码器正确性建议这样验：找一段已知内容的 DMR 录音，把 33 字节载荷喂给
  `dmr_core_receive`（拿 `result.codec`）再交给 `DMRVoiceDecoder.decode(codec:)`，
  输出写进 WAV（8 kHz / 16 bit / 单声道）后与 DroidStar 的输出逐采样比对。
