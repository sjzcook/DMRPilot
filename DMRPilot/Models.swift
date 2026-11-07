//
//  Models.swift
//  DMRPilot
//
//  BrandMeister v2 REST 模型 + App 内部模型
//

import Foundation

// MARK: - BrandMeister v2 API 模型

/// `GET https://api.brandmeister.network/v2/device/{id}`
///
/// 实测返回示例（ID 262301）：
/// ```json
/// {"id":262301,"callsign":"DB0OBO","linkname":null,"hardware":"","firmware":"",
///  "tx":"0.0000","rx":"0.0000","colorcode":1,"status":3,"lastKnownMaster":9999,
///  "lat":0,"lng":0,"city":null,"website":null,"pep":0,"agl":0,
///  "priorityDescription":null,"description":null,
///  "created_at":"2022-07-19T15:59:12.000000Z","updated_at":"2022-08-19T08:39:52.000000Z",
///  "last_seen":"2022-07-19 17:57:55","permissions":[],"statusText":"Both Slots Linked"}
/// ```
/// 所有字段都按可选处理，服务器加字段/改类型也不会解析失败。
struct BmDevice: Codable, Identifiable, Hashable {
    let id: Int
    var callsign: String?
    var linkname: String?
    var hardware: String?
    var firmware: String?
    var tx: String?
    var rx: String?
    var colorcode: Int?
    var status: Int?
    var lastKnownMaster: Int?
    var lat: Double?
    var lng: Double?
    var city: String?
    var website: String?
    var desc: String?
    var lastSeen: String?
    var statusText: String?

    enum CodingKeys: String, CodingKey {
        case id, callsign, linkname, hardware, firmware, tx, rx, colorcode, status
        case lastKnownMaster, lat, lng, city, website
        case desc = "description"
        case lastSeen = "last_seen"
        case statusText
    }

    var coordinateText: String? {
        guard let lat, let lng, lat != 0 || lng != 0 else { return nil }
        return String(format: "%.5f, %.5f", lat, lng)
    }
}

// MARK: - 传输方式

enum HbTransport: String, Codable, CaseIterable, Identifiable {
    case udp
    case websocket

    var id: String { rawValue }

    var title: String {
        switch self {
        case .udp: return "UDP（标准）"
        case .websocket: return "WebSocket"
        }
    }

    var short: String {
        switch self {
        case .udp: return "UDP"
        case .websocket: return "WSS"
        }
    }
}

// MARK: - 设置

/// 连接 DMR 服务器用的协议。两者**互不相通**，端口和登录方式都不一样：
///
/// - `odtp`：BrandMeister 的 Open DMR Terminal Protocol（Rewind），UDP **54006**。
///   订阅是显式命令，登录用 7 位 DMR ID + SelfCare 密码，没有时隙 / 色码。
///   DroidStar 的 iOS 版在 BrandMeister 上默认走这条。
/// - `homebrew`：MMDVM / HBlink 的 Homebrew 协议，UDP **62031**。
///   登录用 9 位热点 ID，订阅靠「发一次真实发射」。TGIF / FreeDMR / 自建网关走这条。
enum LinkProtocol: String, Codable, CaseIterable, Identifiable {
    case odtp
    case homebrew

    var id: String { rawValue }

    var title: String {
        switch self {
        case .odtp: return "ODTP（BrandMeister）"
        case .homebrew: return "Homebrew（MMDVM / HBlink）"
        }
    }

    var short: String {
        switch self {
        case .odtp: return "ODTP"
        case .homebrew: return "Homebrew"
        }
    }

    /// 该协议的默认端口。
    var defaultPort: Int {
        switch self {
        case .odtp: return 54006
        case .homebrew: return 62031
        }
    }

    /// 这个协议用哪种身份：ODTP 是 7 位 DMR ID，Homebrew 是 9 位热点 ID。
    var identityHint: String {
        switch self {
        case .odtp: return "DMR ID（7 位）+ SelfCare 密码"
        case .homebrew: return "热点 ID（9 位）+ Hotspot Security 密码"
        }
    }
}

// MARK: - 首页模式选择

/// 首页标题右侧按钮的可选项（DMR / YSF）。rawValue 就是按钮上显示的文案。
/// 存在 Settings 里持久化；当前只影响显示，不发协议指令——将来接 YSF 从这里接线。
enum HomeMode: String, Codable, CaseIterable, Identifiable {
    case dmr = "DMR"
    case ysf = "YSF"

    var id: String { rawValue }

    /// 对应的服务器列表类型：记忆的服务器槽、选择器加载的列表都按它分。
    var hostKind: HostKind {
        switch self {
        case .dmr: return .dmr
        case .ysf: return .ysf
        }
    }
}

// MARK: - 外观主题

/// App 的整体配色。存在设置里，改完立刻生效（`RootView` 上用 `preferredColorScheme`）。
///
/// 只影响**界面**，跟语音、协议、日志都无关——所以改动不需要重连。
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    /// 跟随系统的浅色 / 深色设置（默认）。
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "日间模式"
        case .dark: return "夜间模式"
        }
    }
}

// MARK: - 呼叫类型（组呼 / 单呼）

/// 首页 PTT 这一次要发给谁。
///
/// 协议上两者只差一个 FLCO：组呼发 0（目的地址是通话组号），单呼发 3
/// （目的地址是对方 7 位 DMR ID）。语音编码、时隙、纠错链完全一样，
/// 所以这里只是一个「目的地址怎么来」的开关，不涉及任何协议分叉。
///
/// 枚举名没用 `case private`（Swift 关键字），取值也不写 `private`，
/// 免得在 `Settings.callMode == .private` 这种地方被迫加反引号。
enum CallMode: String, Codable, CaseIterable, Identifiable {
    /// 发到通话组（默认，等于老版本行为）。
    case group
    /// 发到某个人的 DMR ID。
    case privateCall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .group: return "组呼"
        case .privateCall: return "单呼"
        }
    }
}

// MARK: - 服务器选择记忆

/// 某一类服务器（DMR / YSF）上次选中的那一台。
///
/// 首页右上角切换模式时，记住的选择会跟「当前生效」的 host / hostName / port 互换，
/// 所以切回某一类时还能看到上次在那一类里挑的服务器。
struct HostSelection: Codable, Equatable {
    var name: String = ""
    var host: String = ""
    var port: Int = 0

    /// 还没为这一类选过服务器。
    var isEmpty: Bool { host.isEmpty }
}

struct Settings: Codable, Equatable {
    /// 热点自身的 DMR ID（不是你的个人呼号 ID）
    var dmrId: Int = 0
    /// 呼号，写进 RPTC 配置块的前 8 字节。不能留空——
    /// BrandMeister 收到一整包没有呼号的配置会回 MSTNAK，看上去像「热点没注册」。
    var callsign: String = ""
    /// ESSID 后缀 0…99。0 = 不上报后缀，直接用 DMR ID 当热点 ID；
    /// 1…99 时按 BrandMeister 的规则换算成 9 位热点 ID，见 `hotspotId`。
    var essid: Int = 0
    /// 直接指定 9 位热点 ID（SelfCare → My Hotspots 里显示的那串数字）。
    /// 非 0 时优先于 ESSID 换算，用来绕开「别名到底从 0 还是 1 开始」这种猜谜。
    var hotspotIdOverride: Int = 0
    /// BrandMeister 自助页 → Hotspot Security 里设置的密码
    var password: String = ""
    /// 从 DMRHosts.txt 选中的服务器名字（如 BM_4602_China）；空字符串表示自定义域名。
    /// 只用于回显下拉框选中态，连接时真正用的是 host / port。
    var hostName: String = ""
    /// 默认给一台 BrandMeister master。**不能**用 `api.brandmeister.network`——
    /// 那是 REST 接口的域名，54006 上没有任何服务。ODTP 的地址形如
    /// `<地区>.master.brandmeister.network`（中国区 4601 / 4602）。
    var host: String = "4601.master.brandmeister.network"
    /// 默认跟着默认协议走（ODTP = 54006）。
    var port: Int = 54006
    /// 按类型记住上次选的服务器，切换首页模式时用来回显。
    /// `host / hostName / port` 始终是「当前生效」的那台，连接读的是它们。
    var dmrHost: HostSelection = HostSelection()
    var ysfHost: HostSelection = HostSelection()
    var transport: HbTransport = .udp
    /// 服务器说哪种协议。默认 ODTP —— 目标是 BrandMeister，而且它的订阅是显式命令，
    /// 不像 Homebrew 那样需要「发一次静音发射」去碰运气。
    var linkProtocol: LinkProtocol = .odtp
    /// WebSocket 路径，仅在 transport == .websocket 时生效
    var wsPath: String = "/ws"
    /// 登录成功后是否上报 `RPTC` 配置包（302 字节：呼号 / 频率 / 位置 / 软件名）。
    ///
    /// 默认**打开**，与参考实现 DroidStar 一致：它的 `DMR::process_udp` 是三段状态机
    ///
    ///     RPTL → RPTACK(盐) → RPTK → RPTACK → RPTC → RPTACK → setup_connection()
    ///
    /// 只有走完第三段（RPTC 的应答）才切到 `CONNECTED_RW`，那之前收到的 `DMRD`
    /// 一律不处理。注意 DroidStar 的 RPTC 是逐字节拼的（`out.append('R')…`），
    /// 所以按字符串搜 "RPTC" 是搜不到的。
    ///
    /// 关掉之后只剩两段（`RPTL → RPTK → CONNECTED`），属于**非标准流程**：
    /// 只给那些压根不认 RPTC 的自建网关 / HBLink 用。BrandMeister 上请保持打开。
    var sendConfig: Bool = true
    var autoReconnect: Bool = true

    /// 要收听的通话组（TG），0 表示全部。
    ///
    /// Homebrew 是「服务器推什么就收什么」的协议，这个值首先是**订阅目标**：
    /// 连上后（或切换组时）向它发一次 PTT，让 BrandMeister 把它记成动态订阅。
    /// 至于本地要不要按它过滤，见 `followServerTalkgroups`。
    var talkgroup: Int = 0

    /// 首页 PTT 用组呼还是单呼。默认组呼，和以前完全一样。
    ///
    /// 只影响**发射**：接收侧仍然是「服务器推什么就播什么」，
    /// 单呼不像通话组那样需要订阅。
    var callMode: CallMode = .group

    /// 单呼对方的 DMR ID（也就是 DMRD 里的目的地址）。0 = 还没填。
    ///
    /// 目的地址是 24 位，所以合法范围是 `privateIdRange`。
    var privateId: Int = 0

    /// 单呼目的地址的合法范围（DMR 目的地址是 24 位无符号）。
    static let privateIdRange: ClosedRange<Int> = 1...16_777_215

    /// 这次 PTT 要发的目的地址：组呼取通话组号，单呼取对方 ID。
    var pttDestination: Int {
        callMode == .privateCall ? privateId : talkgroup
    }

    /// 这次 PTT 是不是单呼（决定 FLCO 填 0 还是 3）。
    var isPrivateCall: Bool {
        callMode == .privateCall
    }

    /// 目的地址在提示语里的写法：组呼 `TG 46001`，单呼 `单呼 4600002`。
    ///
    /// `destination` 可以不传（默认用当前设置的那个）；传的话用来显示
    /// 「已经开始发射的那一次」——发射过程中用户可能又换了模式。
    func destinationText(_ destination: Int? = nil) -> String {
        let value = destination ?? pttDestination
        return isPrivateCall ? "单呼 \(value)" : "TG \(value)"
    }

    /// 服务器推什么就播什么（对齐参考实现 DroidStar 的接收侧）。
    ///
    /// DroidStar 的 `process_udp()` 只判「55 字节 + DMRD + 已连接」，从不拿目的地址
    /// 跟本地选的 TG 比 —— 推什么就解什么。BrandMeister 推下来的是「这台热点被订阅的
    /// 组」，其中还包括 SelfCare 里配的静态组，很可能跟选中的 TG 不是同一个。
    /// 按 TG 硬丢帧就会表现成「订阅没建立、什么都不响」，其实语音一直在下来。
    ///
    /// 默认跟随；关掉就退化成严格过滤，只听 `talkgroup` 那一个组。
    var followServerTalkgroups: Bool = true

    /// 订阅发射用的时隙。BrandMeister 上大部分中文 TG 挂在 TS2，个别老组在 TS1。
    var callSlot: Int = 2

    /// 色码（Color Code，0…15），只影响**我们发出去的语音帧**，不影响连接与接收。
    ///
    /// Homebrew 的握手（`RPTL` / `RPTK` / `RPTACK` / `RPTPING` / `DMRD` 头）里
    /// 根本没有色码字段——参考实现 DroidStar 从头到尾没有拿它做过校验：
    /// `process_udp()` 只判断 `buf.size() == 55 && "DMRD" && flags & 0x20 && status == CONNECTED_RW`。
    /// 它只出现在两个地方：
    ///
    /// 1. `RPTC` 配置包的第 4 个字段（`%02u`，MMDVM / DroidStar 都写死 `1`），
    ///    对 master 而言只是「这台设备的资料」，不参与鉴权、也不做流量过滤；
    /// 2. 我们发出去的 33 字节语音载荷里——语音头/结束符的 slot type 高 4 位，
    ///    以及每个超帧第 1…5 个突发的嵌入信令 `DMREMB` 高 4 位。
    ///
    /// 所以它只在「别人用固定 CC 的电台听我们」时才有意义：对端设了 CC 过滤、
    /// 而我们的 CC 不同，就会把我们当成噪音静音掉。BrandMeister 上绝大多数中继
    /// 与热点用 CC1，保持默认 1 即可。
    var colorCode: Int = 1
    /// 连上之后自动向当前 TG 订阅一次，让服务器把它标成动态订阅。
    ///
    /// Homebrew 没有订阅指令，只能靠「按一次 PTT」让 master 认这个组——
    /// 就是参考实现 DroidStar 里人手动按话筒那一下。不发的话只能收到
    /// SelfCare 里配成 Static TG 的那些。
    var autoCallOnConnect: Bool = true

    /// 动态订阅静默一段时间后自动再订阅一次。
    ///
    /// BrandMeister 的动态 TG 长时间没有活动会被释放，释放后再想听就得重新
    /// 发一次。打开这个选项，连接期间只要该组静默超过
    /// `talkgroupRenewMinutes` 分钟就自动续上一次。
    var autoRenewTalkgroup: Bool = true

    /// 续订间隔（分钟）。BM 大约 10 分钟释放动态 TG，默认 8 分钟留出余量。
    var talkgroupRenewMinutes: Int = 8

    // MARK: 外观

    /// 首页右上角模式按钮的当前选择。持久化，默认 DMR。
    /// 决定服务器选择器加载哪份列表（DMR / YSF），并回显该类型上次选的服务器；
    /// YSF 的协议逻辑还没接，连接行为仍走 DMR 那套。
    var homeMode: HomeMode = .dmr

    /// 主题：跟随系统 / 强制日间 / 强制夜间。只影响界面，不影响连接。
    var theme: AppTheme = .system

    // MARK: 语音

    /// 是否解码并播放收到的 DMR 语音
    var audioEnabled: Bool = true
    /// 播放音量 0…1
    var audioVolume: Double = 0.9
    /// 麦克风增益（dB）。只影响发射，0 表示原样送编码器，正数放大、负数衰减。
    ///
    /// 存在这里而不是 `AVAudioSession`：iPhone 的输入增益没有公开接口，
    /// 所以是在采集后的 8 kHz Int16 采样上做数字放大（见 `PttMicrophone`）。
    var micGainDb: Double = 0

    /// 麦克风增益滑杆的范围（dB）。24 dB 约 16 倍幅度，再往上削波只会更糊。
    static let micGainRange: ClosedRange<Double> = -12...24

    var isIdentityReady: Bool { dmrId > 0 && !sanitizedPassword.isEmpty }

    /// RPTC 里真正发出去的呼号。
    ///
    /// 只保留字母、数字和斜杠（BG7ABC/7 这类移动呼号合法），统一大写，最多 8 位
    /// —— 配置块里呼号字段就是 8 字节，多出来的会被截断，中文字符更会变成乱码。
    var normalizedCallsign: String {
        let allowed = callsign
            .uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") }
        return String(allowed.prefix(8))
    }

    /// YSF 用的呼号：10 个字符宽（YSF 包头里的呼号字段就是 10 字节），
    /// 比 RPTC 的 8 字节宽松，并允许 `-`（有些反射器用 BG7ABC-7 这种 SSID 写法）。
    var ysfCallsign: String {
        let allowed = callsign
            .uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "/") }
        return String(allowed.prefix(10))
    }

    /// 真正参与 SHA256 的密码。
    /// 去掉粘贴带进来的首尾空白，并把 iOS 智能标点换成 ASCII——
    /// 弯引号（’ “ ”）和 ASCII 引号是两个不同字节，差一个就 MSTNAK。
    var sanitizedPassword: String {
        password
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    // MARK: ESSID

    /// 有效后缀 1…99；0 或越界视为不启用。
    var essidSuffix: Int? {
        (1...99).contains(essid) ? essid : nil
    }

    /// 实际登录用的热点 ID。
    ///
    /// BrandMeister 官方文档（openSPOT 配置页）说得很直白：填 **7 位 Radio ID**，
    /// 需要第二台热点就**在后面追加两位别名**，例如 `4601234` + `01` → `460123401`。
    /// 也就是 `DMR ID × 100 + 别名`。
    ///
    /// 这里曾经照抄过 DroidStar 的 `×(100) + (别名 − 1)`（填 01 得 `…400`，别名 00）。
    /// DroidStar 的 ESSID 下拉是 “None/00/01/…/99” 且自己又减了 1，那是它的界面怪癖；
    /// 照抄的结果是登录了一个 SelfCare 里不存在的别名，master 收得下密码、
    /// 却在配置阶段回 `MSTCL` 把会话关掉——看上去就是「刚连上就被服务器断开」。
    ///
    /// 另外留了一个 `hotspotIdOverride`：直接把 SelfCare → My Hotspots 里显示的
    /// 9 位数字填进来，就完全不用猜换算规则了。
    var hotspotId: Int {
        if hotspotIdOverride >= 10_000_000 { return hotspotIdOverride }
        guard let suffix = essidSuffix, dmrId > 0, dmrId <= 42_949_672 else { return dmrId }
        return dmrId * 100 + suffix
    }

    /// 带 SSID 的 9 位热点 ID，用于界面与日志（没有后缀时就是 DMR ID）。
    var hotspotIdText: String { String(hotspotId) }

    /// 是否真的带着 ESSID 后缀登录（用于日志与界面提示）。
    var usesEssid: Bool { essidSuffix != nil }

    // MARK: 服务器选择记忆

    /// 把当前 host / hostName / port 存进某一类型的槽（用户在列表里选了一台、
    /// 或者手填域名回车之后调用）。
    mutating func rememberCurrentHost(as kind: HostKind) {
        let selection = HostSelection(name: hostName, host: host, port: port)
        switch kind {
        case .dmr: dmrHost = selection
        case .ysf: ysfHost = selection
        }
    }

    /// 某一类型上次选的服务器；还没选过时 `isEmpty` 为 true。
    func rememberedHost(for kind: HostKind) -> HostSelection {
        kind == .ysf ? ysfHost : dmrHost
    }

    /// 把某个槽回填成「当前生效」的服务器（切换模式时用）。
    mutating func applyHost(_ selection: HostSelection) {
        guard !selection.isEmpty else { return }
        hostName = selection.name
        host = selection.host
        port = selection.port
    }
}

extension Settings {

    /// 手写解码而非合成：合成版遇到“老版本存下来的 JSON 里没有新字段”会直接抛错，
    /// 用户升级一次 App 就把 DMR ID 和密码全丢了。这里每个字段都退回默认值。
    init(from decoder: Decoder) throws {
        let defaults = Settings()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        dmrId = try container.decodeIfPresent(Int.self, forKey: .dmrId) ?? defaults.dmrId
        callsign = try container.decodeIfPresent(String.self, forKey: .callsign) ?? defaults.callsign
        essid = try container.decodeIfPresent(Int.self, forKey: .essid) ?? defaults.essid
        hotspotIdOverride = try container.decodeIfPresent(Int.self, forKey: .hotspotIdOverride) ?? defaults.hotspotIdOverride
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? defaults.password
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName) ?? defaults.hostName
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        // 设置页已经把「协议」和「端口」两项去掉了：App 只走 ODTP。
        // 老存档里如果是 Homebrew 的 62031，这里改回 54006 —— 否则会拿着 Homebrew
        // 的端口去连一台只说 Rewind 的 master，界面上还找不到地方改。
        // 但 YSF 反射器的端口（42000 / 42200 …）必须原样保留，不能一律改写。
        linkProtocol = .odtp
        let savedPort = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        port = savedPort == 62031 ? LinkProtocol.odtp.defaultPort : savedPort
        // 按类型记住的服务器：老存档没有，退回空槽（第一次切换模式时再写入）。
        dmrHost = (try? container.decodeIfPresent(HostSelection.self, forKey: .dmrHost)) ?? defaults.dmrHost
        ysfHost = (try? container.decodeIfPresent(HostSelection.self, forKey: .ysfHost)) ?? defaults.ysfHost
        transport = try container.decodeIfPresent(HbTransport.self, forKey: .transport) ?? defaults.transport
        wsPath = try container.decodeIfPresent(String.self, forKey: .wsPath) ?? defaults.wsPath
        sendConfig = try container.decodeIfPresent(Bool.self, forKey: .sendConfig) ?? defaults.sendConfig
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? defaults.autoReconnect
        talkgroup = try container.decodeIfPresent(Int.self, forKey: .talkgroup) ?? defaults.talkgroup
        // 老存档没有这两个键：退回「组呼 + 空目的地址」，行为和以前一模一样。
        callMode = (try? container.decodeIfPresent(CallMode.self, forKey: .callMode)) ?? defaults.callMode
        let privateIdValue = try container.decodeIfPresent(Int.self, forKey: .privateId) ?? defaults.privateId
        // 越界（手改过 plist、或者 ID 被写成 9 位热点号）就当没填，
        // 否则会发出一个 24 位溢出的目的地址，服务器按别人的 ID 转发了。
        privateId = Settings.privateIdRange.contains(privateIdValue) ? privateIdValue : 0
        followServerTalkgroups = try container.decodeIfPresent(Bool.self, forKey: .followServerTalkgroups) ?? defaults.followServerTalkgroups
        callSlot = try container.decodeIfPresent(Int.self, forKey: .callSlot) ?? defaults.callSlot
        colorCode = min(15, max(0, try container.decodeIfPresent(Int.self, forKey: .colorCode) ?? defaults.colorCode))
        autoCallOnConnect = try container.decodeIfPresent(Bool.self, forKey: .autoCallOnConnect) ?? defaults.autoCallOnConnect
        autoRenewTalkgroup = try container.decodeIfPresent(Bool.self, forKey: .autoRenewTalkgroup) ?? defaults.autoRenewTalkgroup
        talkgroupRenewMinutes = try container.decodeIfPresent(Int.self, forKey: .talkgroupRenewMinutes) ?? defaults.talkgroupRenewMinutes
        // 老存档没有这个键，退回默认主题，视觉上不会突然变样。
        // 这里多包一层 `try?`：枚举存的是原始值字符串，万一将来某个档位被删掉，
        // 认不出的值也只退回默认主题，不会把整份设置（DMR ID / 密码）一起丢掉。
        theme = (try? container.decodeIfPresent(AppTheme.self, forKey: .theme)) ?? defaults.theme
        // 首页模式同理：老存档没有就退回 DMR；认不出的值也退回 DMR。
        homeMode = (try? container.decodeIfPresent(HomeMode.self, forKey: .homeMode)) ?? defaults.homeMode
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? defaults.audioEnabled
        audioVolume = try container.decodeIfPresent(Double.self, forKey: .audioVolume) ?? defaults.audioVolume
        // 老存档没有这个键，退回 0 dB（和以前完全一样）；顺便把越界值夹回滑杆范围，
        // 免得手改过 plist 之后一发射就爆音。
        let gain = try container.decodeIfPresent(Double.self, forKey: .micGainDb) ?? defaults.micGainDb
        micGainDb = min(Settings.micGainRange.upperBound,
                        max(Settings.micGainRange.lowerBound, gain))
    }
}

// MARK: - 实时通话

/// 由 Homebrew 数据流聚合出来的“通话”：一次语音头到语音结束符之间的所有 DMRD 帧。
/// 语音载荷同时会送进 VoicePipeline 解码播放，这里只负责信令与统计。
struct LiveCall: Identifiable, Equatable {
    let id: String          // src-dst-slot
    let src: Int
    let dst: Int
    let slot: Int
    let isPrivate: Bool
    var frames: Int
    var startedAt: Date
    var updatedAt: Date
    var isActive: Bool
    /// YSF 这类「身份是字符串」的协议用：源呼号直接带下来，不用再查库。
    /// DMR 的记录这里是 nil，仍按 `src` 走呼号库。
    var name: String? = nil
    /// 频道那一行的显示文本（YSF 是目的呼号，比如 "ALL" 或某人的呼号）。
    var channel: String? = nil

    var duration: TimeInterval { max(0, updatedAt.timeIntervalSince(startedAt)) }
    var callTypeText: String { isPrivate ? "单呼" : "组呼" }
    var slotText: String { "TS\(slot)" }
}

/// 当前（或刚刚）在说话的那个人。
///
/// Homebrew 的 DMRD 帧里只有数字 ID，呼号要靠 `CallsignDirectory` 另查，
/// 所以这里只存协议层能拿到的字段。
struct ActiveSpeaker: Equatable {
    let src: Int
    let dst: Int
    let slot: Int
    let isPrivate: Bool
    let startedAt: Date
    /// 最后一条语音帧的时间，用来判断「还在说」还是「已经说完」。
    var lastVoiceAt: Date
    /// 收到语音结束符的时间；nil 表示还没收到。
    var endedAt: Date?
    /// YSF 的源呼号（协议里本来就没有数字 ID）。DMR 下是 nil。
    var name: String? = nil
    /// 频道那一行的显示文本；nil 时按 DMR 的「通话组 + 时隙」拼。
    var channel: String? = nil

    /// 3 秒内还有语音帧才算正在说话。
    ///
    /// 有些 master 不推语音结束符（或者结束符丢了），只看 `endedAt`
    /// 会让「讲话中」永远不灭；反过来只看时间又会在长句的换气间隙闪。两条一起用。
    func isSpeaking(at now: Date) -> Bool {
        guard endedAt == nil else { return false }
        return now.timeIntervalSince(lastVoiceAt) < 3
    }

    /// 这一句说了多久（收尾后固定为总时长）。
    var talkTime: TimeInterval {
        max(0, (endedAt ?? lastVoiceAt).timeIntervalSince(startedAt))
    }
}

// MARK: - 协议日志

struct LogEntry: Identifiable {
    enum Kind {
        case info, tx, rx, warning, error

        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .tx: return "arrow.up.circle"
            case .rx: return "arrow.down.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String
    var hex: String?
}

// MARK: - 格式化

enum Fmt {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: "%02d:%02d", total / 60, total % 60) }
        if total < 3600 { return String(format: "%02d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

extension Data {
    /// 空格分隔的十六进制，便于在日志里肉眼比对协议。
    var hexDump: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
