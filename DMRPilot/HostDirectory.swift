//
//  HostDirectory.swift
//  DMRPilot
//
//  服务器列表：DMR 和 YSF 两张表，各自解析、下载、缓存。
//  DMR 来自 Pi-Star 格式的 DMRHosts.txt（逻辑移植自参考实现 droidstar.cpp 的
//  process_dmr_hosts() 与 HttpManager）；YSF 来自 YSFHosts.txt（process_ysf_hosts()）。
//  两份按类型分开保存，首页右上角模式选 YSF 时选择器加载 YSF 那份，DMR 加载 DMR。
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

// MARK: - 服务器类型

/// 服务器列表按协议分两份：DMR（DMRHosts.txt）和 YSF（YSFHosts.txt）。
/// 首页右上角模式菜单选 YSF 时，选择器加载 YSF 那一份；DMR 加载 DMR。
enum HostKind: String, CaseIterable, Identifiable {
    case dmr
    case ysf

    var id: String { rawValue }
}

// MARK: - 单条服务器

struct DMRHost: Identifiable, Hashable {
    let name: String
    let hostname: String
    let port: UInt16
    /// 表里给出的默认密码，一般是 passw0rd；用户在设置里填的密码优先。
    let tablePassword: String?
    /// 这台属于哪张表。DMR 和 YSF 的判定逻辑互不搭边，列表分开存、分开挑。
    let kind: HostKind

    init(name: String, hostname: String, port: UInt16,
         tablePassword: String? = nil, kind: HostKind = .dmr) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.tablePassword = tablePassword
        self.kind = kind
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
        guard kind == .dmr, !isTGIF else { return false }
        let lower = hostname.lowercased()
        return name.uppercased().hasPrefix("BM")
            || lower.contains("brandmeister")
            || lower.contains("repeater.net")
            || port == 54006
    }

    /// 列表右侧的协议标签。54006 是 ODTP，其余 BM 走 HomeBrew 62031；
    /// YSF 表里的条目一律标 YSF。
    var tag: String {
        if kind == .ysf { return "YSF" }
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

// MARK: - YSF 解析

enum YSFHostTable {
    /// YSFHosts.txt（Pi-Star 生成的 YSF 反射器表）用**分号**切列：
    ///
    ///     # Format: designator;name;description;host;port;000;
    ///     00006;GR-HELLAS Zone A;(YCS202);46.59.68.211;42000;000;
    ///
    /// 解析规则对齐参考实现 process_ysf_hosts()：跳过 # 注释，列数 > 4，
    /// 第 2 列是名称、第 4 列是主机、第 5 列是端口（0 起数）。
    /// 同名只留最后一条（C++ 那边也是 map 按 name 覆盖）。
    static func parse(_ text: String) -> [DMRHost] {
        var byName: [String: DMRHost] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let columns = line.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count > 4 else { continue }

            let name = columns[1]
            let hostname = columns[3]
            guard !name.isEmpty, !hostname.isEmpty,
                  let port = UInt16(columns[4]) else { continue }

            byName[name] = DMRHost(name: name, hostname: hostname, port: port, kind: .ysf)
        }

        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 下载 + 缓存

@MainActor
final class DMRHostStore: ObservableObject {
    /// DMR 服务器（DMRHosts.txt）。选择器在 DMR 模式下用这一份。
    @Published private(set) var hosts: [DMRHost] = []
    /// YSF 反射器（YSFHosts.txt）。和 DMR 表分开下载、分开落盘、分开加载。
    @Published private(set) var ysfHosts: [DMRHost] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// 当前列表来自哪儿：`本地快照` 或镜像域名。
    @Published private(set) var loadedFrom: String = ""
    /// 两份快照里较新的保存时间，给设置页「服务器列表」的「更新于」用。
    @Published private(set) var savedAt: Date?

    /// 只留 BrandMeister 条目，DMR 选择器默认只显示这些（YSF 没有这个概念）。
    var brandMeisterHosts: [DMRHost] { hosts.filter(\.isBrandMeister) }

    /// 按类型取全量列表（不做范围过滤）。
    func allHosts(of kind: HostKind) -> [DMRHost] {
        kind == .ysf ? ysfHosts : hosts
    }

    /// 本机是否已经存好至少一份可用的表。搜索只看内存里这份（来自本地文件）。
    var hasSnapshot: Bool { !hosts.isEmpty || !ysfHosts.isEmpty }

    /// 设置页「服务器表」那一行的小字，以及选择器列表的表头。
    var snapshotDetail: String {
        guard hasSnapshot else { return loadedFrom }
        guard let savedAt else { return "本机" }
        return "本机 · " + Self.dayFormatter.string(from: savedAt)
    }

    /// DMR：主镜像 + 上一版快照。参考实现里还有个 http://www.dudetronics.com/ar-dns 老镜像，
    /// 但 ATS 默认禁止明文 HTTP，留着只会白等 15 秒超时，这里不带。
    static let dmrMirrors = [
        "https://ds.vu3lvo.com/DMRHosts.txt",
        "https://ds.vu3lvo.com/backup/DMRHosts.txt"
    ]

    /// YSF：Pi-Star 的 YSF 反射器表，目前只有这一个来源。
    static let ysfMirrors = [
        "https://ds.vu3lvo.com/YSFHosts.txt"
    ]

    private var hasAttemptedLoad = false

    /// 进入选择器时调用：只尝试一次，避免每次切 Tab / 开 sheet 都重新拉。
    func loadIfNeeded() async {
        guard !hasAttemptedLoad else { return }
        await load()
    }

    /// 未指定 force 时优先读本地快照——**不联网**，所以服务器选择器的搜索
    /// 完全靠本机数据就能用（点「服务器列表」行的「更新」时才真正下载）。
    ///
    /// 两张表各自独立：谁没快照谁联网；点「更新」（force）时两张都重下。
    /// 一张失败不影响另一张，错误信息拼在一起显示。
    func load(force: Bool = false) async {
        guard !isLoading else { return }
        hasAttemptedLoad = true

        var dmrReady = force
        var ysfReady = force

        if !force, let snapshot = readSnapshot(kind: .dmr) {
            let parsed = DMRHostTable.parse(snapshot.text)
            if !parsed.isEmpty {
                hosts = parsed
                savedAt = newer(savedAt, snapshot.savedAt)
                dmrReady = true
            }
        }

        if !force, let snapshot = readSnapshot(kind: .ysf) {
            let parsed = YSFHostTable.parse(snapshot.text)
            if !parsed.isEmpty {
                ysfHosts = parsed
                savedAt = newer(savedAt, snapshot.savedAt)
                ysfReady = true
            }
        }

        if dmrReady && ysfReady {
            loadedFrom = "本地快照"
            lastError = nil
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        var downloadErrors: [String] = []

        if !dmrReady, let result = await Self.downloadFirst(Self.dmrMirrors) {
            let parsed = DMRHostTable.parse(result.text)
            if !parsed.isEmpty {
                let now = Date()
                writeSnapshot(kind: .dmr, text: result.text, savedAt: now, count: parsed.count)
                hosts = parsed
                loadedFrom = result.source
                savedAt = newer(savedAt, now)
                dmrReady = true
            }
        }
        if !dmrReady {
            downloadErrors.append("DMR 列表下载失败，检查网络后重试")
        }

        if !ysfReady, let result = await Self.downloadFirst(Self.ysfMirrors) {
            let parsed = YSFHostTable.parse(result.text)
            if !parsed.isEmpty {
                let now = Date()
                writeSnapshot(kind: .ysf, text: result.text, savedAt: now, count: parsed.count)
                ysfHosts = parsed
                savedAt = newer(savedAt, now)
                ysfReady = true
            }
        }
        if !ysfReady {
            downloadErrors.append("YSF 列表下载失败，检查网络后重试")
        }

        lastError = downloadErrors.isEmpty ? nil : downloadErrors.joined(separator: "\n")

        if !dmrReady && !ysfReady && hosts.isEmpty && ysfHosts.isEmpty {
            loadedFrom = ""
            if lastError == nil { lastError = "服务器列表下载失败，检查网络后点这一行的「更新」重试" }
        }
    }

    // MARK: - 下载

    /// 逐个试镜像，拿到第一份合法文本为止；全部失败返回 nil。
    /// 错误原因不细分（超时 / 404 / 错误页面），调用方只给一句汇总提示。
    private static func downloadFirst(_ mirrors: [String]) async -> (text: String, source: String)? {
        for urlString in mirrors {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("EasyDMR/1.0", forHTTPHeaderField: "User-Agent")
                // URLSession 会自动处理 gzip，C++ 里那段手动 inflate 在这里不需要。
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }
                guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else { continue }
                guard Self.isValidPayload(text) else { continue }

                return (text, url.host ?? urlString)
            } catch {
                // 换下一个镜像接着试，最后一个的异常也不单独上报。
            }
        }
        return nil
    }

    private static func newer(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return max(a, b)
        }
    }

    // MARK: - 本地快照

    /// 存 Application Support 而不是 Caches：Caches 会被系统在存储紧张时清掉，
    /// 清掉之后选择器就只剩联网一条路。这两张表各几十 KB，没必要让它消失。
    /// DMR 用原有的 hosts.txt（老版本无缝沿用）；YSF 单独存 ysfhosts.txt。
    private static let folderName = "DMRPilot"
    private static func fileName(for kind: HostKind) -> String {
        kind == .dmr ? "hosts.txt" : "ysfhosts.txt"
    }
    private static func metaName(for kind: HostKind) -> String {
        kind == .dmr ? "hosts.meta.json" : "ysfhosts.meta.json"
    }

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

    private func snapshotURL(for kind: HostKind) -> URL {
        directoryURL.appendingPathComponent(Self.fileName(for: kind))
    }
    private func metaURL(for kind: HostKind) -> URL {
        directoryURL.appendingPathComponent(Self.metaName(for: kind))
    }

    /// 老版本把表放在 Caches/DMRHosts.txt，读一次做迁移。
    private var legacyURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DMRHosts.txt")
    }

    private func readSnapshot(kind: HostKind) -> (text: String, savedAt: Date?)? {
        let fileURL = snapshotURL(for: kind)
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8) {
            let meta = (try? Data(contentsOf: metaURL(for: kind)))
                .flatMap { try? JSONDecoder().decode(SnapshotMeta.self, from: $0) }
            let date = meta.map { Date(timeIntervalSince1970: $0.savedAt) }
                ?? fileDate(fileURL)
            return (text, date)
        }

        // 迁移（只对 DMR）：把老 Caches 里那份搬过来，之后就一直用新路径。
        guard kind == .dmr,
              let legacyURL,
              let data = try? Data(contentsOf: legacyURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parsed = DMRHostTable.parse(text)
        guard !parsed.isEmpty else { return nil }

        let date = fileDate(legacyURL) ?? Date()
        writeSnapshot(kind: .dmr, text: text, savedAt: date, count: parsed.count)
        return (text, date)
    }

    private func writeSnapshot(kind: HostKind, text: String, savedAt: Date, count: Int) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: snapshotURL(for: kind), options: .atomic)
            let meta = SnapshotMeta(savedAt: savedAt.timeIntervalSince1970,
                                    source: "ds.vu3lvo.com",
                                    count: count)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL(for: kind), options: .atomic)
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
    private static func isValidPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 64 else { return false }
        let head = String(trimmed.prefix(64)).lowercased()
        return !head.hasPrefix("<!doctype") && !head.hasPrefix("<html") && !head.hasPrefix("<body")
    }
}
