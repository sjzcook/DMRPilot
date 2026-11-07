//
//  HotspotActivityAttributes.swift
//  EasyDMR
//
//  Live Activity（锁屏卡片 + 灵动岛）的数据契约。
//
//  这个文件同时编进主 App 和 Widget 扩展两个 target（`.pbxproj` 里挂了两个
//  PBXBuildFile），所以两边拿到的是同一份定义。分成两份写最容易在字段类型、
//  顺序上悄悄跑偏，而这类错误编译能过、运行时 update 直接抛。
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct HotspotActivityAttributes: ActivityAttributes {

    /// 每次 update 整份替换的内容，所以只放「会变」的。
    struct ContentState: Codable, Hashable {
        /// 「已在线」「正在连接…」，直接取 `ConnectionState.label`。
        var statusText: String
        var isOnline: Bool
        /// 当前收听（订阅）的通话组；0 表示没选。
        var talkgroup: Int
        /// 信号报告：`59` / `59+20` / `—`，和首页那条表同源。
        var signal: String
        /// 0…1 的音频峰值，灵动岛里画那条小电平。
        var level: Double
        /// 正在按住 PTT。
        var isTransmitting: Bool
        /// 发射开始的时刻。交给 SwiftUI 的 `Text(timerInterval:)` 自己走秒，
        /// 否则得每秒 push 一次内容，会被系统节流。
        var txStartedAt: Date?
        /// 正在说话的人；查不到呼号时只留 ID。
        var speakerLabel: String?
        var speakerId: Int?
        /// 收帧计数，锁屏上当作「链路还活着」的证据。
        var rxFrames: Int
    }

    /// 整个连接周期里不变的：自己的身份和连的哪台服务器。
    var callsign: String
    var dmrId: String
    var host: String
}
