//
//  LiveActivityController.swift
//  EasyDMR
//
//  把「连接状态 / 信号 / 通话组 / 说话人」推到锁屏卡片和灵动岛。
//
//  为什么要节流：Live Activity 的更新预算是按小时给的，1 秒推一次会被系统降频、
//  甚至直接丢掉后续更新（表现是灵动岛卡在旧状态）。所以这里只做两件事——
//  结构性的变化（在线状态、通话组、说话人、发射）立刻推；
//  连续量（电平、信号读数、收帧数）最多 3 秒推一次。
//
//  Dynamic Island 只有在 iPhone 14 Pro 及以后才有；其余机型看到的是锁屏卡片。
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
@MainActor
final class LiveActivityController {

    static let shared = LiveActivityController()

    /// 把 DMR ID 换成呼号（查本地库，同步、很便宜）。由 `AppState` 注入。
    var nameResolver: ((Int) -> String?)?

    private var activity: Activity<HotspotActivityAttributes>?
    private var lastState: HotspotActivityAttributes.ContentState?
    private var lastPushedAt = Date.distantPast
    /// 创建失败后的冷却时间，避免每秒重试一次刷系统接口。
    private var lastFailureAt: Date?
    /// 最近一次失败原因，调试用；界面上没有展示。
    private(set) var lastProblem: String?

    private init() {}

    // MARK: - 推送

    /// 由 `HomebrewClient` 每秒调一次（只在连接期间跑）。
    func sync(hotspot: HomebrewClient, settings: Settings) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = contentState(hotspot: hotspot, settings: settings)

        // App 被杀之后重启：系统里可能还挂着上一次的卡片，直接接管，不要再建一个。
        if activity == nil {
            activity = Activity<HotspotActivityAttributes>.activities.first
        }

        guard let activity = activity else {
            request(state: state, hotspot: hotspot, settings: settings)
            return
        }

        guard shouldPush(state) else { return }
        lastState = state
        lastPushedAt = Date()

        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state,
                                                      stalenessDate: Date().addingTimeInterval(120)))
            } else {
                await activity.update(using: state)
            }
        }
    }

    /// 断开连接时调用：卡片直接收走，不留在锁屏上装「还在听」。
    func end() {
        guard let activity = activity else { return }
        let final = lastState
        self.activity = nil
        lastState = nil
        lastPushedAt = .distantPast

        Task {
            if #available(iOS 16.2, *), let final {
                await activity.end(ActivityContent(state: final, stalenessDate: Date()),
                                   dismissalPolicy: .immediate)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - 内部

    private func request(state: HotspotActivityAttributes.ContentState,
                         hotspot: HomebrewClient,
                         settings: Settings) {
        guard hotspot.state == .online else { return }
        if let lastFailureAt = lastFailureAt, Date().timeIntervalSince(lastFailureAt) < 30 { return }

        // 连上之前就把自己的身份定死：卡片上半部分在整段连接里不会变。
        let attributes = HotspotActivityAttributes(
            callsign: settings.normalizedCallsign,
            dmrId: settings.dmrId > 0 ? "\(settings.dmrId)" : "",
            host: "\(settings.host):\(settings.port)"
        )

        do {
            if #available(iOS 16.2, *) {
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state,
                                             stalenessDate: Date().addingTimeInterval(120)),
                    pushType: nil
                )
            } else {
                activity = try Activity.request(attributes: attributes,
                                                contentState: state,
                                                pushType: nil)
            }
            lastState = state
            lastPushedAt = Date()
            lastFailureAt = nil
            lastProblem = nil
        } catch {
            // 常见原因：用户在系统设置里关了「实时活动」、或同一 App 的卡片被限额。
            lastFailureAt = Date()
            lastProblem = error.localizedDescription
        }
    }

    /// 结构性变化立刻推，连续量最多 3 秒一次。
    private func shouldPush(_ state: HotspotActivityAttributes.ContentState) -> Bool {
        guard let last = lastState else { return true }

        if last.statusText != state.statusText
            || last.isOnline != state.isOnline
            || last.talkgroup != state.talkgroup
            || last.isTransmitting != state.isTransmitting
            || last.speakerId != state.speakerId {
            return true
        }

        return Date().timeIntervalSince(lastPushedAt) >= 3
    }

    private func contentState(hotspot: HomebrewClient,
                              settings: Settings) -> HotspotActivityAttributes.ContentState {
        let talkgroup = hotspot.activeTalkgroup > 0 ? hotspot.activeTalkgroup : settings.talkgroup
        let speakerId = hotspot.currentSpeaker?.src
        let report = SignalReport(level: Double(hotspot.voiceLevel))

        return HotspotActivityAttributes.ContentState(
            statusText: hotspot.state.label,
            isOnline: hotspot.state == .online,
            talkgroup: talkgroup,
            signal: report.text,
            level: Double(hotspot.voiceLevel),
            isTransmitting: hotspot.isTransmitting,
            // 用「现在 - 已发射秒数」反推起点，交给 `Text(timerInterval:)` 自己走秒，
            // 这样发射中的计时不需要我们每秒推一次内容。
            txStartedAt: hotspot.isTransmitting ? Date().addingTimeInterval(-hotspot.txSeconds) : nil,
            speakerLabel: speakerId.flatMap { nameResolver?($0) },
            speakerId: speakerId,
            rxFrames: hotspot.rxFrames
        )
    }
}
