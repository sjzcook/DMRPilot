//
//  HostDirectory.swift
//  DMRPilot
//
//  服务器列表：解析 Pi-Star 格式的 DMRHosts.txt，并负责下载 / 缓存。
//  逻辑移植自参考实现里的 BMHost + BMHostList + BMHostListStore
//  （对应 C++ 侧 droidstar.cpp 的 process_dmr_hosts() 与 HttpManager）。
//
//  表格式（列之间用任意空白分隔，NO SPACES 指名字里不能带空格）：
//
//      # Name            DMR-ID   IP/Hostname                      Password   Port
//      BM_4601_China     4601     4601.master.brandmeister.network  passw0rd   62031
//
//  解析规则与 C++ 版本一致：切列后要求 5 列以上，跳过本机网关三条记录，
//  第 3 列是域名、第 4 列是表内默认密码、第 5 列是端口。
//

import Combine
import Foundation

// MARK: - 单条服务器

struct DMRHost: Identifiable, Hashable {
    let name: String
    let hostname: String
    let port: UInt16
    /// 表里给出的默认密码，一般是 passw0rd；用户在设置里填的密码优先。
    let tablePassword: String?

    init(name: String, hostname: String, port: UInt16, tablePassword: String? = nil) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.tablePassword = tablePassword
    }

    /// 表里名字唯一，直接拿名字做 id。
    var id: String { name }

    var endpoint: String { "\(hostname):\(port)" }

    var isTGIF: Bool {
        name.uppercased().hasPrefix("TGIF") || hostname.lowercased().contains("tgif")
    }

    /// 与 C++ process_connect() 里的 isBMServer 判定保持一致：
    /// 名字以 BM 开头、域名含 brandmeister / repeater.net，或端口本来就是 54006（ODTP）。
    var isBrandMeister: Bool {
        if isTGIF { return false }
        let lower = hostname.lowercased()
        return name.uppercased().hasPrefix("BM")
            || lower.contains("brandmeister")
            || lower.contains("repeater.net")
            || port == 54006
    }

    /// 列表右侧的协议标签。54006 是 ODTP，其余 BM 走 HomeBrew 62031。
    var tag: String {
        if isTGIF { return "TGIF" }
        if isBrandMeister { return port == 54006 ? "ODTP" : "BM" }
        if name.uppercased().hasPrefix("XLX") { return "XLX" }
        return "DMR+"
    }
}

// MARK: - 解析

enum DMRHostTable {
    /// 表里被跳过的本机网关条目。
    private static let gatewayNames: Set<String> = ["DMRGateway", "DMR2YSF", "DMR2NXDN"]

    static func parse(_ text: String) -> [DMRHost] {
        var byName: [String: DMRHost] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 5 else { continue }

            let name = columns[0]
            if gatewayNames.contains(name) { continue }
            guard let port = UInt16(columns[4]) else { continue }

            let password = columns[3].caseInsensitiveCompare("none") == .orderedSame ? nil : columns[3]
            byName[name] = DMRHost(name: name,
                                   hostname: columns[2],
                                   port: port,
                                   tablePassword: password)
        }

        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 下载 + 缓存

@MainActor
final class DMRHostStore: ObservableObject {
    @Published private(set) var hosts: [DMRHost] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// 当前列表来自哪儿：`本地快照` 或镜像域名。
    @Published private(set) var loadedFrom: String = ""
    /// 本地快照的保存时间（首次下载 / 上次点「服务器表」那一行的「更新」的时刻）。
    @Published private(set) var savedAt: Date?

    /// 只留 BrandMeister 条目，设置页默认只显示这些。
    var brandMeisterHosts: [DMRHost] { hosts.filter(\.isBrandMeister) }

    /// 本机是否已经存好一份可用的表。搜索只看内存里这份（来自本地文件）。
    var hasSnapshot: Bool { !hosts.isEmpty }

    /// 设置页「服务器表」那一行的小字，以及选择器列表的表头。
    var snapshotDetail: String {
        guard hasSnapshot else { return loadedFrom }
        guard let savedAt else { return "本机" }
        return "本机 · " + Self.dayFormatter.string(from: savedAt)
    }

    /// 主镜像 + 上一版快照。参考实现里还有个 http://www.dudetronics.com/ar-dns 老镜像，
    /// 但 ATS 默认禁止明文 HTTP，留着只会白等 15 秒超时，这里不带。
    static let mirrors = [
        "https://ds.vu3lvo.com/DMRHosts.txt",
        "https://ds.vu3lvo.com/backup/DMRHosts.txt"
    ]

    private var hasAttemptedLoad = false

    /// 进入设置页时调用：只尝试一次，避免每次切 Tab 都重新拉。
    func loadIfNeeded() async {
        guard !hasAttemptedLoad else { return }
        await load()
    }

    /// 未指定 force 时优先读本地快照——**不联网**，所以服务器选择器的搜索
    /// 完全靠本机数据就能用（点「服务器表」行的「更新」时才真正下载一次）。
    func load(force: Bool = false) async {
        guard !isLoading else { return }
        hasAttemptedLoad = true

        if !force, let snapshot = readSnapshot() {
            let parsed = DMRHostTable.parse(snapshot.text)
            if !parsed.isEmpty {
                hosts = parsed
                loadedFrom = "本地快照"
                savedAt = snapshot.savedAt
                lastError = nil
                return
            }
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        for urlString in Self.mirrors {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("DMRPilot/1.0", forHTTPHeaderField: "User-Agent")
                // URLSession 会自动处理 gzip，C++ 里那段手动 inflate 在这里不需要。
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }
                guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else { continue }
                guard isValidPayload(text) else { continue }

                let parsed = DMRHostTable.parse(text)
                guard !parsed.isEmpty else { continue }

                let now = Date()
                writeSnapshot(text: text, savedAt: now, count: parsed.count)
                hosts = parsed
                loadedFrom = url.host ?? urlString
                savedAt = now
                return
            } catch {
                lastError = error.localizedDescription
            }
        }

        if hosts.isEmpty {
            loadedFrom = ""
            if lastError == nil { lastError = "服务器列表下载失败，检查网络后点这一行的「更新」重试" }
        }
    }

    // MARK: - 本地快照

    /// 存 Application Support 而不是 Caches：Caches 会被系统在存储紧张时清掉，
    /// 清掉之后选择器就只剩联网一条路。这张表只有几十 KB，没必要让它消失。
    private static let folderName = "DMRPilot"
    private static let fileName = "hosts.txt"
    private static let metaName = "hosts.meta.json"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    /// 快照带的元信息，只为了在设置页显示「什么时候存的」。
    private struct SnapshotMeta: Codable {
        var savedAt: Double
        var source: String
        var count: Int
    }

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    private var snapshotURL: URL { directoryURL.appendingPathComponent(Self.fileName) }
    private var metaURL: URL { directoryURL.appendingPathComponent(Self.metaName) }

    /// 老版本把表放在 Caches/DMRHosts.txt，读一次做迁移。
    private var legacyURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DMRHosts.txt")
    }

    private func readSnapshot() -> (text: String, savedAt: Date?)? {
        if let data = try? Data(contentsOf: snapshotURL),
           let text = String(data: data, encoding: .utf8) {
            let meta = (try? Data(contentsOf: metaURL))
                .flatMap { try? JSONDecoder().decode(SnapshotMeta.self, from: $0) }
            let date = meta.map { Date(timeIntervalSince1970: $0.savedAt) }
                ?? fileDate(snapshotURL)
            return (text, date)
        }

        // 迁移：把老 Caches 里那份搬过来，之后就一直用新路径。
        guard let legacyURL,
              let data = try? Data(contentsOf: legacyURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parsed = DMRHostTable.parse(text)
        guard !parsed.isEmpty else { return nil }

        let date = fileDate(legacyURL) ?? Date()
        writeSnapshot(text: text, savedAt: date, count: parsed.count)
        return (text, date)
    }

    private func writeSnapshot(text: String, savedAt: Date, count: Int) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: snapshotURL, options: .atomic)
            let meta = SnapshotMeta(savedAt: savedAt.timeIntervalSince1970,
                                    source: "ds.vu3lvo.com",
                                    count: count)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL, options: .atomic)
            }
        } catch {
            // 写不进去也不影响本次使用，只是下次启动要重下。
            lastError = "服务器表保存失败：\(error.localizedDescription)"
        }
    }

    private func fileDate(_ url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return date
    }

    // MARK: - Private

    /// 镜像挂掉时经常回一个 HTML 错误页，别把页面当主机表存下来。
    private func isValidPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 64 else { return false }
        let head = String(trimmed.prefix(64)).lowercased()
        return !head.hasPrefix("<!doctype") && !head.hasPrefix("<html") && !head.hasPrefix("<body")
    }
}
