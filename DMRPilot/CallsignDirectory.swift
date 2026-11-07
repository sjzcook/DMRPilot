//
//  CallsignDirectory.swift
//  DMRPilot
//
//  DMR ID → 呼号。
//
//  Homebrew 的 DMRD 帧头只有 3 字节源 ID 和 3 字节目的 ID，**没有呼号**——
//  呼号是 DMR 的 LC（link control）信息，Homebrew 不下发，所以只能外部补。两级：
//
//    1. 本地 DMR ID 库（`DMRUserDatabase`）：RadioID.net 的整包用户表，
//       用户在「设置 → 数据 → 更新数据」下载后完全离线可查。首页每次换人说话
//       都要把源 ID 翻成呼号，只有走本地库才来得及、也不会被限流。
//    2. 本地库里没有的 ID（中继台、网关、刚申请还没入库的），再退到网络逐条查：
//       RadioID.net 的单条接口 → BrandMeister 设备库（中继台在这里有呼号）。
//
//  网络查询是串行的、间隔 250ms —— RadioID 对突发请求会限流；同一个 ID 查不到时
//  10 分钟内不再重试，避免每来一帧语音就往服务器打一次。结果写进 Caches，
//  之后完全离线也能显示。
//

import Combine
import Foundation

@MainActor
final class CallsignDirectory: ObservableObject {

    /// id → 呼号。视图直接读这个字典，变化会自动刷新。
    @Published private(set) var callsigns: [Int: String] = [:]

    // MARK: - 本地库状态（设置页「数据」一栏显示）

    @Published private(set) var databaseCount = 0
    @Published private(set) var databaseBytes = 0
    @Published private(set) var databaseUpdatedAt: Date?
    @Published private(set) var databaseSource = ""
    @Published private(set) var isUpdatingDatabase = false
    /// 0…1；nil 表示进度未知（服务器没给 Content-Length）。
    @Published private(set) var databaseProgress: Double?
    @Published private(set) var databaseStage = ""
    @Published private(set) var databaseError: String?

    /// RadioID.net 的整包用户表。查询全部走它，网络只做兜底。
    private let database = RadioIDDatabase()

    /// 正在查询的 id，防止排队期间重复入队。
    private var inFlight: Set<Int> = []
    /// 查过但库里没有的 id → 那次查询的时间。
    private var misses: [Int: Date] = [:]
    private var queue: [Int] = []
    private var isDraining = false
    private var didLoadCache = false

    /// 查不到之后隔多久才允许再查。呼号入库有延迟，但没必要一直打。
    private let missLifetime: TimeInterval = 600
    /// 两次请求之间的间隔（纳秒）。
    private let spacing: UInt64 = 250_000_000

    private let session: URLSession
    private static let cacheFilename = "callsigns.json"

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)

        applyDatabaseSnapshot()
        loadCacheIfNeeded()
    }

    // MARK: - 对外

    /// 本地库里的完整记录（姓名、城市）。首页用它做副标题。
    func user(for id: Int) -> DMRUser? {
        database.lookup(id)
    }

    /// 已知的呼号。本地库优先，其次才是以前联网查到的结果。
    func callsign(for id: Int) -> String? {
        if let user = database.lookup(id) { return user.callsign }
        return callsigns[id]
    }

    /// 本地库里有没有整包数据。
    var hasDatabase: Bool { databaseCount > 0 }

    /// 把 id 交给查询队列。本地库有的、已知的、正在查的、刚查过没结果的都会直接跳过。
    /// 可以放心在「每帧语音」这种高频位置调用。
    func request(_ id: Int) {
        request([id])
    }

    func request(_ ids: [Int]) {
        loadCacheIfNeeded()

        let now = Date()
        for id in ids where id > 0 {
            if callsigns[id] != nil || inFlight.contains(id) || queue.contains(id) { continue }
            // 本地库能答的，一次网络请求都不发
            if database.lookup(id) != nil { continue }
            if let missed = misses[id], now.timeIntervalSince(missed) < missLifetime { continue }
            queue.append(id)
        }

        guard !isDraining, !queue.isEmpty else { return }
        isDraining = true
        Task { await drain() }
    }

    // MARK: - 更新本地库

    /// 下载整包用户表并重建索引。界面上的「更新数据」按钮调这个。
    func updateDatabase() async {
        guard !isUpdatingDatabase else { return }

        isUpdatingDatabase = true
        databaseError = nil
        databaseProgress = 0
        databaseStage = "正在连接 RadioID.net…"

        defer {
            isUpdatingDatabase = false
            databaseProgress = nil
            databaseStage = ""
        }

        do {
            let snapshot = try await database.update { [weak self] phase in
                Task { @MainActor in
                    guard let self else { return }
                    switch phase {
                    case .downloading(let fraction):
                        self.databaseProgress = fraction
                        if let fraction {
                            self.databaseStage = "正在下载 DMR ID 库 \(Int(fraction * 100))%"
                        } else {
                            self.databaseStage = "正在下载 DMR ID 库…"
                        }
                    case .indexing:
                        self.databaseProgress = nil
                        self.databaseStage = "正在建立本地索引…"
                    }
                }
            }

            apply(snapshot)
            // 新库把以前「查不到」的 ID 也覆盖了一遍，清掉这份黑名单重新判断
            misses.removeAll()
            databaseError = nil
        } catch {
            databaseError = error.localizedDescription
        }
    }

    private func apply(_ snapshot: RadioIDDatabase.Snapshot) {
        databaseCount = snapshot.count
        databaseBytes = snapshot.bytes
        databaseUpdatedAt = snapshot.updatedAt
        databaseSource = snapshot.source
    }

    private func applyDatabaseSnapshot() {
        guard let snapshot = database.currentSnapshot() else { return }
        apply(snapshot)
    }

    // MARK: - 网络兜底队列

    private func drain() async {
        defer { isDraining = false }

        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard callsigns[id] == nil, !inFlight.contains(id) else { continue }

            inFlight.insert(id)
            if let name = await lookup(id) {
                callsigns[id] = name
                misses[id] = nil
                persist()
            } else {
                misses[id] = Date()
            }
            inFlight.remove(id)

            if !queue.isEmpty {
                try? await Task.sleep(nanoseconds: spacing)
            }
        }
    }

    private func lookup(_ id: Int) async -> String? {
        if let name = await radioID(id) { return name }
        return await brandMeisterDevice(id)
    }

    /// RadioID.net 用户库。查不到时返回 `count: 0`（HTTP 仍是 200），所以只认 results。
    private func radioID(_ id: Int) async -> String? {
        guard let url = URL(string: "https://database.radioid.net/api/dmr/user/?id=\(id)") else {
            return nil
        }
        guard let data = await fetch(url) else { return nil }

        struct Response: Decodable {
            struct User: Decodable {
                let callsign: String?
            }
            let results: [User]
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let callsign = decoded.results.first?.callsign else { return nil }
        return normalize(callsign)
    }

    /// BrandMeister 设备库：中继台 / 热点在这里有呼号，普通用户 ID 会 404。
    private func brandMeisterDevice(_ id: Int) async -> String? {
        guard let url = URL(string: "https://api.brandmeister.network/v2/device/\(id)") else {
            return nil
        }
        guard let data = await fetch(url) else { return nil }

        struct Device: Decodable {
            let callsign: String?
        }

        guard let device = try? JSONDecoder().decode(Device.self, from: data) else { return nil }
        return normalize(device.callsign)
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DMRPilot/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// 呼号统一大写、去掉首尾空白；空串或纯空白视为没查到。
    private func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 缓存

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(Self.cacheFilename)
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return }

        var table: [Int: String] = [:]
        table.reserveCapacity(raw.count)
        for (key, value) in raw {
            if let id = Int(key) { table[id] = value }
        }
        callsigns = table
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: callsigns.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
