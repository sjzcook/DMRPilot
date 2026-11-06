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
    /// 呼号，仅用于 RPTC 配置上报，可留空
    var callsign: String = ""
    /// ESSID 后缀 0…99。0 = 不上报后缀，直接用 DMR ID 当热点 ID；
    /// 1…99 时按 BrandMeister 的规则换算成 9 位热点 ID，见 `hotspotId`。
    var essid: Int = 0
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
    var autoReconnect: Bool = true

    // MARK: 语音

    /// 是否解码并播放收到的 DMR 语音
    var audioEnabled: Bool = true
    /// 播放音量 0…1
    var audioVolume: Double = 0.9

    var isIdentityReady: Bool { dmrId > 0 && !sanitizedPassword.isEmpty }

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
    /// BrandMeister / MMDVM 的换算（DMR::set_dmr_params）：
    ///     m_essid = dmrID * 100 + (后缀 - 1)
    /// 即 7 位 ID 1234567 + 后缀 01 → 123456700，后缀 02 → 123456701。
    /// 没有后缀时 master 直接把 DMR ID 当热点 ID。
    ///
    /// 填了 9 位热点 ID 再乘 100 会溢出 uint32、master 只会回 NAK，
    /// 所以和参考实现一样先挡住（Int 在 64 位上不会溢出，但值是垃圾）。
    var hotspotId: Int {
        guard let suffix = essidSuffix, dmrId > 0, dmrId <= 42_949_672 else { return dmrId }
        return dmrId * 100 + (suffix - 1)
    }

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
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? defaults.password
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName) ?? defaults.hostName
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        transport = try container.decodeIfPresent(HbTransport.self, forKey: .transport) ?? defaults.transport
        wsPath = try container.decodeIfPresent(String.self, forKey: .wsPath) ?? defaults.wsPath
        modernPing = try container.decodeIfPresent(Bool.self, forKey: .modernPing) ?? defaults.modernPing
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? defaults.autoReconnect
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
