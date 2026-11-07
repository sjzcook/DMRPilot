//
//  AppState.swift
//  DMRPilot
//
//  全局状态：设置持久化、通话组字典、我的设备信息、热点连接。
//

import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    /// 进程内唯一实例。
    ///
    /// 快捷指令（`PTTIntents.swift`）是在 App 进程里跑的，但拿不到 SwiftUI 注入的
    /// environmentObject，只能从这里取同一个 AppState——否则会新造一个 HomebrewClient，
    /// 连着一半的连接、另一个麦克风。
    static let shared = AppState()

    // MARK: - 设置

    @Published var settings: Settings {
        didSet {
            persistSettings()
            // 续订间隔、时隙这类设置改了不该要求重连
            hotspot.applyBehaviour(settings)
        }
    }

    // MARK: - 远端数据

    @Published private(set) var talkgroups: [Int: String] = [:]
    @Published private(set) var talkgroupsLoaded = false
    @Published private(set) var talkgroupsError: String?
    /// 正在拉通话组名称表（首页的选择器靠它显示转圈）。
    @Published private(set) var isLoadingTalkgroups = false
    @Published private(set) var myDevice: BmDevice?
    @Published private(set) var myDeviceError: String?
    @Published private(set) var isLoadingDevice = false

    // MARK: - 依赖

    let hotspot = HomebrewClient()
    /// DMRHosts.txt 服务器表，设置页的下拉列表用它。
    ///
    /// 两份本地数据（服务器表 / DMR ID 库）各自更新，设置页里各有一个「更新」按钮，
    /// 进度和错误也各自挂在 store 上，AppState 不另存一份：
    /// `hostStore.isLoading` / `lastError`、`callsigns.isUpdatingDatabase` / `databaseStage` / `databaseError`。
    let hostStore = DMRHostStore()
    /// DMR ID → 呼号。首页的「当前讲话人」靠它把数字 ID 变成呼号。
    let callsigns = CallsignDirectory()
    private let api = BrandMeisterAPI()
    private static let settingsKey = "dmrpilot.settings.v1"

    init() {
        settings = Self.loadSettings()
        hotspot.adoptTalkgroup(settings.talkgroup)

        // 通话记录落盘时要顺手把呼号和通话组名快照下来，这里把两份引用挂过去。
        // 用 weak：日志库是单例，不该反过来抓着 AppState 不放。
        let callLog = CallLogStore.shared
        callLog.callsigns = callsigns
        callLog.app = self

        // 锁屏卡片 / 灵动岛要显示说话人的呼号，控制器自己拿不到本地库，
        // 这里把查询闭包挂过去（`callsigns` 查的是内存里的索引，同步且很便宜）。
        if #available(iOS 16.1, *) {
            LiveActivityController.shared.nameResolver = { [weak self] id in
                self?.callsigns.callsign(for: id)
            }
        }
    }

    // MARK: - 查询辅助

    func name(for id: Int) -> String? {
        talkgroups[id]
    }

    /// 通话组显示名：有名字显示名字，没有就只显示编号
    func label(for id: Int) -> String {
        if let name = talkgroups[id] {
            return "\(name) · \(id)"
        }
        return "TG \(id)"
    }

    /// 已知的呼号；还没查到返回 nil（调用方决定显示 ID 还是占位符）。
    func callsign(for id: Int) -> String? {
        callsigns.callsign(for: id)
    }

    // MARK: - 连接

    func connect() {
        hotspot.connect(with: settings)
    }

    func disconnect() {
        hotspot.disconnect()
    }

    /// 设置页换服务器之后调用：已经连着就自动断开重连到新地址。
    ///
    /// 没连（或连接失败停在 `.failed`）时只保存设置，不替用户把连接拉起来——
    /// 上线是首页那个连接按钮的事。
    ///
    /// 不先调 `disconnect()`：`connect(with:)` 内部会先发 RPTCL 结束上一个会话、
    /// 留 0.3 秒再把新连接起来，否则 master 会看到同一个 ID 的两条连接并关掉新的那条（MSTCL）。
    func restartForServerChange() {
        guard hotspot.state != .offline else { return }
        hotspot.connect(with: settings)
    }

    // MARK: - 首页模式

    /// 切换首页模式（DMR / YSF），顺带回显这一类上次选的服务器。
    ///
    /// 每种类型各自记一台：先把当前这台存进旧类型的槽，再把新类型的槽回填到
    /// `host / hostName / port`，界面上的选择器就自动回显了。
    /// 新类型还没选过（槽是空的）就保持现状，等用户在列表里挑一台。
    ///
    /// 类型换了等于换了协议（DMR 的 RPTL/ODTP 与 YSF 的 YSFP 完全不通用），
    /// 所以只要还有会话就直接断开，不替用户自动重连——用户按连接按钮时才用新协议上线。
    func setHomeMode(_ mode: HomeMode) {
        guard mode != settings.homeMode else { return }

        // 存旧类型的选择
        settings.rememberCurrentHost(as: settings.homeMode.hostKind)
        settings.homeMode = mode

        // 回显新类型的选择
        let remembered = settings.rememberedHost(for: mode.hostKind)
        if !remembered.isEmpty {
            settings.applyHost(remembered)
        }

        // 模式一换就是换协议（RPTL / ODTP ↔ YSFP 完全不通用），只要还有会话就直接断开，
        // 不替用户自动重连——连接按钮按下去时才用新协议上线。
        //
        // 判断用 `hotspot.hasSession` 而不是 `state != .offline`：状态可能已经是 offline、
        // 但 socket 还要 0.25 秒才拆（刚断过一次又切模式就是这个窗口），
        // 那种情况下也要把残留的会话收干净。
        if hotspot.isTransmitting {
            hotspot.endPtt()
        }
        if hotspot.hasSession {
            disconnect()
        }
    }

    // MARK: - 组呼 / 单呼

    /// 切换首页 PTT 的呼叫类型（组呼 ↔ 单呼）。
    ///
    /// 只改「发到哪」，不碰接收：接收侧仍然是服务器推什么就播什么。
    ///
    /// 切换之后**直接断开**，既不替用户重连，也不再自动补订阅：
    /// 组订阅是服务器那边记着的，单呼期间留着组订阅，服务器会继续把这台热点订阅的
    /// 组语音推下来；而切回组呼时补一次订阅（`hotspot.call`）本质上是一整个超帧的
    /// **真实发射**，用户看到的是「只换了个模式，电台自己发了一次」。
    ///
    /// 断开之后由用户按「连接」，用新模式的干净会话重新上线；组呼模式连上后
    /// `autoCallOnConnect` 会照旧补订阅，所以断开不会让组呼失去订阅。
    func setCallMode(_ mode: CallMode) {
        guard settings.callMode != mode else { return }

        // 正在发射就先收尾：带着「正在发射」的状态断开，PTT 圆会卡在按下态。
        if hotspot.isTransmitting {
            hotspot.endPtt()
        }

        settings.callMode = mode

        if hotspot.hasSession {
            disconnect()
        }
    }

    // MARK: - 通话组

    /// 切换收听的 TG（0 = 全部）。写进设置（会持久化），同时通知连接层立刻生效，
    /// 不需要重连——Homebrew 的推送内容由服务器决定。
    ///
    /// 切到一个具体 TG 时还会顺手向它订阅一次：本地只能决定「播不播」，
    /// 要让服务器真的把语音推下来，得让 master 认为这个组被订阅了。
    ///
    /// 这个是**唯一**的切组入口：选择器里点一行、手填号码点「确定」都走这里，
    /// 所以两条路径的效果一定一致——旧组上挂着的通话先收尾、旧订阅先退掉（`cancelSubscription`），
    /// 再切到新组订阅，并把播放范围锁到新组（`listenLock`），旧组的语音立刻停掉。
    func setTalkgroup(_ talkgroup: Int) {
        let value = max(0, talkgroup)

        if settings.talkgroup != value {
            // 先让连接层把旧组收掉（结束在途通话、清掉旧订阅的计数），再落设置：
            // 「断开旧组 → 切到新组」一步完成，不会出现新组已经显示、旧通话还挂着的中间态。
            hotspot.setTalkgroup(value)
            settings.talkgroup = value
        }

        // 值没变也照发：用户点「确定」/ 点同一行的意思就是「我要听这个组，再激活一次」。
        if value > 0 {
            hotspot.call(talkgroup: value)
        }
    }

    // MARK: - 远端刷新

    func loadTalkgroupsIfNeeded() async {
        guard !talkgroupsLoaded, !isLoadingTalkgroups else { return }
        await reloadTalkgroups()
    }

    func reloadTalkgroups() async {
        guard !isLoadingTalkgroups else { return }

        isLoadingTalkgroups = true
        defer { isLoadingTalkgroups = false }

        do {
            let table = try await api.talkgroups()
            talkgroups = table
            talkgroupsLoaded = !table.isEmpty
            talkgroupsError = nil
        } catch {
            talkgroupsError = error.localizedDescription
        }
    }

    func loadMyDevice() async {
        guard settings.dmrId > 0 else {
            myDeviceError = "先在设置里填写 DMR ID"
            return
        }
        isLoadingDevice = true
        defer { isLoadingDevice = false }
        do {
            myDevice = try await api.device(settings.dmrId)
            myDeviceError = nil
        } catch {
            myDevice = nil
            myDeviceError = error.localizedDescription
        }
    }

    func device(_ id: Int) async throws -> BmDevice {
        try await api.device(id)
    }

    // MARK: - 更新本地数据

    /// 设置页「DMR ID 库」那一行的「更新」按钮：下载整包用户表并重建本地索引。
    /// 失败信息由 `callsigns.databaseError` 发布，行里直接显示。
    func refreshCallsignDatabase() async {
        await callsigns.updateDatabase()
    }

    /// 设置页「服务器列表」那一行的「更新」按钮：强制联网重下 DMRHosts.txt 和
    /// YSFHosts.txt 两张表并落盘（哪张失败不影响另一张，错误拼在一起显示）。
    func refreshHostTable() async {
        await hostStore.load(force: true)
    }

    // MARK: - 持久化

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private static func loadSettings() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return decoded
    }
}
