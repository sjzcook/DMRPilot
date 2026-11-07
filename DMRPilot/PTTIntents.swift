//
//  PTTIntents.swift
//  DMRPilot
//
//  快捷指令 / Action Button 用的 PTT 动作（App Intents）。
//
//  ── 为什么是「定时 / 开关」而不是真的按住 ──────────────────────────
//
//  Action Button 触发快捷指令时只给**一次**「按下」事件，没有「松开」回调。
//  所以「按住说、松手停」这件事没法照搬：能做的只有
//    - PTT 发射（定时）：按一下，说 N 秒，自己收尾；
//    - PTT 开关：按一下开始，再按一下结束（最接近按住 / 松开的手感）；
//    - PTT 开始 / PTT 结束：留给「快捷指令」里自己拼（比如配合自动化）。
//
//  ── 跑在哪里 ────────────────────────────────────────────────────
//
//  App Intent 的 perform() 在 App 进程里执行，但拿不到 SwiftUI 注入的
//  environmentObject。所以统一走 `AppState.shared`，保证和界面上是同一个
//  HomebrewClient、同一个麦克风、同一个通话组。
//
//  另外「App 在后台时能不能开麦」取决于 Info.plist 的 UIBackgroundModes，
//  这个 key 由工程里的 INFOPLIST_KEY_UIBackgroundModes = audio 生成。
//

import AppIntents
import Foundation

// MARK: - 失败原因

/// 快捷指令里能直接看到的错误文案（App Intents 会把 `errorDescription` 弹出来）。
enum PTTIntentError: LocalizedError {
    case identityIncomplete
    case notConnected
    case noTalkgroup
    case microphoneDenied
    case transmitFailed
    case notTransmitting

    var errorDescription: String? {
        switch self {
        case .identityIncomplete:
            return "身份信息不完整：先在 App 里填好 DMR ID 和 BM密码。"
        case .notConnected:
            return "连不上服务器：先在 App 里连一次，确认能看到「已在线」。"
        case .noTalkgroup:
            return "还没选通话组：先在首页选一个组，PTT 才有地方发。"
        case .microphoneDenied:
            return "麦克风没授权：到 设置 → DMRPilot → 麦克风 打开，再试一次。"
        case .transmitFailed:
            return "发射没启动：可能是音频会话被别的 App 占着（比如正在通话），或者会话已经断了。"
        case .notTransmitting:
            return "当前没有在发射。"
        }
    }
}

// MARK: - 实际动作

/// 三个 intent 共用的一段逻辑。全部在主线程上做——`HomebrewClient` 是 @MainActor 的。
@MainActor
enum PTTCommand {

    /// 还没连上时最多等这么久（握手一般 1～3 秒）。
    private static let connectTimeout: TimeInterval = 8

    /// 开始发射，返回这次用的通话组。
    ///
    /// 里外两层兜底：App 被系统挂起过的话连接多半已经掉了，这时候先替用户连一次
    /// ——按 Action Button 的意思就是「我要说话」，不该回一句「请先打开 App」。
    @discardableResult
    static func start() async throws -> Int {
        let app = AppState.shared
        let talkgroup = app.settings.talkgroup

        guard app.settings.isIdentityReady else { throw PTTIntentError.identityIncomplete }
        guard talkgroup > 0 else { throw PTTIntentError.noTalkgroup }

        if app.hotspot.state != .online {
            try await ensureConnected(app)
        }

        guard !app.hotspot.isTransmitting else { return talkgroup }

        // 首次使用会在系统层面弹一次授权框；已经拒绝过就直接失败，别让用户干等。
        guard await PttMicrophone.requestPermission() else { throw PTTIntentError.microphoneDenied }

        app.hotspot.beginPtt(talkgroup: talkgroup)
        guard app.hotspot.isTransmitting else { throw PTTIntentError.transmitFailed }
        return talkgroup
    }

    /// 断着就重连，并在 `connectTimeout` 内等它变成 online。
    private static func ensureConnected(_ app: AppState) async throws {
        switch app.hotspot.state {
        case .connecting, .loggingIn, .authenticating, .configuring:
            break
        default:
            app.connect()
        }

        let deadline = Date().addingTimeInterval(connectTimeout)
        while app.hotspot.state != .online {
            switch app.hotspot.state {
            case .failed:
                throw PTTIntentError.notConnected
            default:
                break
            }
            guard Date() < deadline else { throw PTTIntentError.notConnected }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// 结束发射。返回结束前是否真的在发射（用来决定提示语）。
    @discardableResult
    static func stop() -> Bool {
        let hotspot = AppState.shared.hotspot
        guard hotspot.isTransmitting else { return false }
        hotspot.endPtt()
        return true
    }

    /// 正在发射 / 已经连上，给开关式动作判断用。
    static var isTransmitting: Bool {
        AppState.shared.hotspot.isTransmitting
    }
}

// MARK: - 定时发射（Action Button 的默认写法）

/// 按一下说 N 秒：这是 Action Button 上唯一不需要「第二次按」的写法。
struct PTTSendIntent: AppIntent {

    static var title: LocalizedStringResource = "PTT 发射（定时）"

    static var description: IntentDescription? = IntentDescription(
        "按一下开始发射，说够指定秒数后自动结束。Action Button 只能拿到「按下」，没有「松开」，所以用固定时长代替松手。"
    )

    /// 只在后台跑：不想按一下 Action Button 就把 App 弹到前台。
    static var openAppWhenRun: Bool = false

    @Parameter(title: "持续秒数", description: "1–120 秒", default: 10, inclusiveRange: 1...120)
    var seconds: Int

    init() {}

    init(seconds: Int) {
        self.seconds = seconds
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let duration = max(1, min(120, seconds))
        let talkgroup = try await PTTCommand.start()

        // 定时到了就收尾；中途被打断（进程挂起等）也不会把会话一直挂着，
        // 下一次 start 里 isTransmitting 的判断会兜住。
        try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
        await PTTCommand.stop()

        return .result(dialog: IntentDialog("已发射 \(duration) 秒 · TG \(talkgroup)"))
    }
}

// MARK: - 开关（最接近「按住说、松手停」）

/// 按一下开始，再按一下结束。把同一个动作挂在 Action Button 上就是「对讲机」手感。
struct PTTToggleIntent: AppIntent {

    static var title: LocalizedStringResource = "PTT 开关"

    static var description: IntentDescription? = IntentDescription(
        "第一次按开始发射，第二次按结束发射。适合把 Action Button 当成对讲机的按键。"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if await PTTCommand.isTransmitting {
            await PTTCommand.stop()
            return .result(dialog: IntentDialog("已结束发射"))
        }

        let talkgroup = try await PTTCommand.start()
        return .result(dialog: IntentDialog("开始发射 · TG \(talkgroup)，再按一次结束"))
    }
}

// MARK: - 分开的开始 / 结束

/// 只开始，不自动收尾。留给「快捷指令」里自己拼（比如配合自动化 / 条件）。
struct PTTStartIntent: AppIntent {

    static var title: LocalizedStringResource = "PTT 开始发射"

    static var description: IntentDescription? = IntentDescription("开始发射并一直保持，直到调用「PTT 结束发射」。")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let talkgroup = try await PTTCommand.start()
        return .result(dialog: IntentDialog("开始发射 · TG \(talkgroup)"))
    }
}

/// 结束发射。没在发射时不报错，只回一句「当前没有在发射」。
struct PTTStopIntent: AppIntent {

    static var title: LocalizedStringResource = "PTT 结束发射"

    static var description: IntentDescription? = IntentDescription("把正在进行的发射收尾（发结束符、停麦克风）。")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let wasTransmitting = await PTTCommand.stop()
        return .result(dialog: wasTransmitting ? IntentDialog("已结束发射") : IntentDialog("当前没有在发射"))
    }
}

// MARK: - 快捷指令里的现成条目

/// 装上 App 之后，快捷指令 / Action Button 的动作列表里直接能看到上面这几个，
/// 不用自己一个个拼；这里的 phrases 只是顺手把 Siri 的说法也注册上。
struct DMRPilotShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PTTToggleIntent(),
                    phrases: ["用\(.applicationName)发射",
                              "用\(.applicationName)开始说话"],
                    shortTitle: "PTT 开关",
                    systemImageName: "mic.circle.fill")

        AppShortcut(intent: PTTSendIntent(),
                    phrases: ["用\(.applicationName)说一句"],
                    shortTitle: "PTT 发射",
                    systemImageName: "mic.fill")

        AppShortcut(intent: PTTStopIntent(),
                    phrases: ["用\(.applicationName)停止发射"],
                    shortTitle: "停止发射",
                    systemImageName: "mic.slash.fill")
    }
}
