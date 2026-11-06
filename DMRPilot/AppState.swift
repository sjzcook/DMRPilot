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
        didSet { persistSettings() }
    }

    // MARK: - 远端数据

    @Published private(set) var talkgroups: [Int: String] = [:]
    @Published private(set) var talkgroupsLoaded = false
    @Published private(set) var talkgroupsError: String?
    @Published private(set) var myDevice: BmDevice?
    @Published private(set) var myDeviceError: String?
    @Published private(set) var isLoadingDevice = false

    // MARK: - 依赖

    let hotspot = HomebrewClient()
    /// DMRHosts.txt 服务器表，设置页的下拉列表用它。
    let hostStore = DMRHostStore()
    private let api = BrandMeisterAPI()
    private static let settingsKey = "dmrpilot.settings.v1"

    init() {
        settings = Self.loadSettings()
        hotspot.adoptTalkgroup(settings.talkgroup)
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

    // MARK: - 连接

    func connect() {
        hotspot.connect(with: settings)
    }

    func disconnect() {
        hotspot.disconnect()
    }

    // MARK: - 通话组

    /// 切换收听的 TG（0 = 全部）。写进设置（会持久化），同时通知连接层立刻生效，
    /// 不需要重连——Homebrew 的推送内容由服务器决定，这里只是本地的播放过滤。
    func setTalkgroup(_ talkgroup: Int) {
        let value = max(0, talkgroup)
        guard settings.talkgroup != value else { return }
        settings.talkgroup = value
        hotspot.setTalkgroup(value)
    }

    // MARK: - 远端刷新

    func loadTalkgroupsIfNeeded() async {
        guard !talkgroupsLoaded else { return }
        await reloadTalkgroups()
    }

    func reloadTalkgroups() async {
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
