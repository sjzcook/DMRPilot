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

    // MARK: - 本地数据

    /// 「更新数据」正在跑（服务器表 + 本地 DMR ID 库）。
    @Published private(set) var isRefreshingData = false
    /// 最近一次完整成功的时间。
    @Published private(set) var dataRefreshedAt: Date?
    @Published private(set) var refreshError: String?

    // MARK: - 依赖

    let hotspot = HomebrewClient()
    /// DMRHosts.txt 服务器表，设置页的下拉列表用它。
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

    // MARK: - 通话组

    /// 切换收听的 TG（0 = 全部）。写进设置（会持久化），同时通知连接层立刻生效，
    /// 不需要重连——Homebrew 的推送内容由服务器决定。
    ///
    /// 切到一个具体 TG 时还会顺手向它订阅一次：本地只能决定「播不播」，
    /// 要让服务器真的把语音推下来，得让 master 认为这个组被订阅了。
    func setTalkgroup(_ talkgroup: Int) {
        let value = max(0, talkgroup)

        if settings.talkgroup != value {
            settings.talkgroup = value
            hotspot.setTalkgroup(value)
        }

        // 值没变也照发：用户点「确定」的意思就是「我要听这个组，再激活一次」。
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

    /// 设置页「更新数据」：服务器表 + 本地 DMR ID 库一起刷新。
    ///
    /// 两件事互不依赖，并行跑：服务器表只有几百 KB，本地库有 17 MB 左右，
    /// 串行等下来会让用户白等几十秒。
    func refreshAllData() async {
        guard !isRefreshingData else { return }

        isRefreshingData = true
        refreshError = nil

        async let hosts: Void = hostStore.load(force: true)

        await callsigns.updateDatabase()
        await hosts

        if let error = callsigns.databaseError {
            refreshError = error
        } else if hostStore.hosts.isEmpty, let error = hostStore.lastError {
            refreshError = error
        } else {
            dataRefreshedAt = Date()
        }

        isRefreshingData = false
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
