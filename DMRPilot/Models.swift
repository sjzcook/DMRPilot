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
    var host: String = "api.brandmeister.network"
    var port: Int = 62031
    var transport: HbTransport = .udp
    /// WebSocket 路径，仅在 transport == .websocket 时生效
    var wsPath: String = "/ws"
    /// 使用新版心跳 `DMRP`（MMDVMHost 2024+ / 55 字节帧）。
    /// 传统 BrandMeister 走 `RPTPING` / 53 字节帧，默认关闭。
    var modernPing: Bool = false
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
    /// 万一服务器不接受这个包（回 `MSTCL` 关会话），客户端会自动改成不发并重连一次，
    /// 不需要用户自己去关开关。
    var sendConfig: Bool = true
    var autoReconnect: Bool = true

    /// 要收听的通话组（TG），0 表示全部。
    ///
    /// Homebrew 是「服务器推什么就收什么」的协议，这个值首先是**播放过滤**：
    /// 只解码、播放、记账这个 TG 的通话，其余帧照样计数但不出声。
    /// 要让服务器真的把这个组推下来，还得靠 `autoCallOnConnect` 那次静音呼叫
    /// 建立动态订阅；两者配合才等于「切到某个组」。
    var talkgroup: Int = 0

    /// 呼叫时用的时隙。BrandMeister 上大部分中文 TG 挂在 TS2，个别老组在 TS1。
    var callSlot: Int = 2
    /// 连上之后自动向当前 TG 发一次呼叫，让服务器把它标成动态订阅。
    ///
    /// Homebrew 没有订阅指令，只能靠「发一次 PTT」让 master 认这个组；
    /// 不发的话只能收到 SelfCare 里配成 Static TG 的那些。
    var autoCallOnConnect: Bool = true

    /// 动态订阅静默一段时间后自动再呼叫一次。
    ///
    /// BrandMeister 的动态 TG 长时间没有活动会被释放，释放后再想听就得重新
    /// 发一次静音呼叫。打开这个选项，连接期间只要该组静默超过
    /// `talkgroupRenewMinutes` 分钟就自动续上一次。
    var autoRenewTalkgroup: Bool = true

    /// 续订间隔（分钟）。BM 大约 10 分钟释放动态 TG，默认 8 分钟留出余量。
    var talkgroupRenewMinutes: Int = 8

    // MARK: 语音

    /// 是否解码并播放收到的 DMR 语音
    var audioEnabled: Bool = true
    /// 播放音量 0…1
    var audioVolume: Double = 0.9

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
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        transport = try container.decodeIfPresent(HbTransport.self, forKey: .transport) ?? defaults.transport
        wsPath = try container.decodeIfPresent(String.self, forKey: .wsPath) ?? defaults.wsPath
        modernPing = try container.decodeIfPresent(Bool.self, forKey: .modernPing) ?? defaults.modernPing
        sendConfig = try container.decodeIfPresent(Bool.self, forKey: .sendConfig) ?? defaults.sendConfig
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? defaults.autoReconnect
        talkgroup = try container.decodeIfPresent(Int.self, forKey: .talkgroup) ?? defaults.talkgroup
        callSlot = try container.decodeIfPresent(Int.self, forKey: .callSlot) ?? defaults.callSlot
        autoCallOnConnect = try container.decodeIfPresent(Bool.self, forKey: .autoCallOnConnect) ?? defaults.autoCallOnConnect
        autoRenewTalkgroup = try container.decodeIfPresent(Bool.self, forKey: .autoRenewTalkgroup) ?? defaults.autoRenewTalkgroup
        talkgroupRenewMinutes = try container.decodeIfPresent(Int.self, forKey: .talkgroupRenewMinutes) ?? defaults.talkgroupRenewMinutes
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? defaults.audioEnabled
        audioVolume = try container.decodeIfPresent(Double.self, forKey: .audioVolume) ?? defaults.audioVolume
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
