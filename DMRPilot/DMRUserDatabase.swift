//
//  DMRUserDatabase.swift
//  DMRPilot
//
//  本地 DMR ID 库。
//
//  RadioID.net 的整包用户表是 `https://database.radioid.net/static/user.csv`，
//  2026-11 实测 17 MB / 31.6 万条，CRLF 换行，字段是
//
//      RADIO_ID,CALLSIGN,FIRST_NAME,LAST_NAME,CITY,STATE,COUNTRY
//      4600001,BD7IXF,Chiwai,,SHENZHEN,Hunan Guangdong Guangxi Hainan,China
//
//  首页每次换人说话都要把源 ID 翻成呼号，逐条打 API 既慢又会被限流
//  （`CallsignDirectory` 里那套 250 ms 串行队列就是为此存在）。所以这里把整包
//  下载到本地，做成「ID → 行偏移」的定长索引：
//
//      users.idx   : "RIDX" + 条数(UInt32 LE) + N × (ID:UInt32, 偏移:UInt32)  —— 已按 ID 升序
//      users.csv   : 原样保存，只读
//
//  查询时二分索引拿到偏移，再用 `Data` 的内存映射只读那一行。索引 2.5 MB 常驻，
//  17 MB 的 CSV 靠 mmap 由系统按页调入，实测查一次是微秒级，可以在 SwiftUI 的
//  body 里直接调。
//
//  文件放在 Application Support/DMRPilot 下（不是 Caches —— 系统可以在任意时刻
//  清掉 Caches，而用户点了「更新」之后应该是长期可用的），并标记不进 iCloud
//  备份：17 MB 的第三方数据没必要占用户的备份空间。
//

import Foundation

// MARK: - 一条用户记录

struct DMRUser: Hashable, Identifiable {
    let id: Int
    let callsign: String
    let givenName: String
    let surname: String
    let city: String
    let state: String

    /// 名 + 姓，按 RadioID 的存法就是 `FIRST_NAME LAST_NAME`。
    var fullName: String {
        let parts = [givenName, surname].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// 「城市, 省/州」。两层一样时只留一层（不少条目 CITY 和 STATE 是重复的）。
    ///
    /// 故意不显示 COUNTRY：RadioID 的国名字段是志愿者手填的，同一批数据里
    /// 有把中国地区写成别的名字的条目，展示出来只会误导。
    var placeText: String {
        let city = self.city.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = self.state.trimmingCharacters(in: .whitespacesAndNewlines)
        if city.isEmpty { return state }
        if state.isEmpty { return city }
        if city.caseInsensitiveCompare(state) == .orderedSame { return city }
        return "\(city), \(state)"
    }
}

// MARK: - 本地库

/// 本地 DMR ID 库：下载整包、建索引、按 ID 查询。
///
/// 线程模型：`lookup` 会被主线程直接调用，`update` 在后台跑。两者用一把锁串行，
/// 索引与 CSV 的引用在锁内整体替换，不会出现「索引是新的、CSV 是旧的」。
final class RadioIDDatabase {

    struct Snapshot: Equatable {
        var count: Int
        var bytes: Int
        var updatedAt: Date
        var source: String
    }

    enum UpdateError: LocalizedError {
        case download(String)
        case parse(String)
        case storage(String)

        var errorDescription: String? {
            switch self {
            case .download(let detail): return "DMR ID 库下载失败：\(detail)"
            case .parse(let detail): return "DMR ID 库解析失败：\(detail)"
            case .storage(let detail): return "DMR ID 库保存失败：\(detail)"
            }
        }
    }

    /// 索引格式版本。改布局时 +1，老文件会被当成无效自动重下。
    static let formatVersion = 1
    /// 主站 + 备用域名（同一份文件，Radioid 的 CDN 偶尔只挂一个）。
    static let mirrors = [
        "https://database.radioid.net/static/user.csv",
        "https://www.radioid.net/static/user.csv"
    ]
    /// 下载上限。正常 17 MB，超过这个数只可能是镜像挂掉回了奇怪的页面。
    static let maxBytes: Int64 = 120 * 1024 * 1024

    private let root: URL
    private let lock = NSLock()
    private var csvData: Data?
    private var indexData: Data?
    private var snapshot: Snapshot?

    init(directoryName: String = "DMRPilot") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent(directoryName, isDirectory: true)
        prepareDirectory()
        loadFromDisk()
    }

    // MARK: - 对外

    /// 当前库的概要信息；没下载过就是 nil。
    func currentSnapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return csvData != nil && indexData != nil
    }

    /// 按 DMR ID 查一条记录。没有就返回 nil —— 中继台、网关、未入库的新 ID 都会走到这儿。
    func lookup(_ id: Int) -> DMRUser? {
        guard id > 0 else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard let indexData, let csvData else { return nil }

        let offset: Int? = indexData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard raw.count >= RadioIDIndex.headerBytes else { return nil }
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            guard count > 0, raw.count >= RadioIDIndex.headerBytes + count * RadioIDIndex.entryBytes else {
                return nil
            }

            var low = 0
            var high = count - 1
            while low <= high {
                let mid = (low + high) / 2
                let base = RadioIDIndex.headerBytes + mid * RadioIDIndex.entryBytes
                let value = RadioIDIndex.readUInt64(bytes, at: base)
                let entryID = Int(value >> 32)
                if entryID == id { return Int(value & 0xFFFF_FFFF) }
                if entryID < id { low = mid + 1 } else { high = mid - 1 }
            }
            return nil
        }

        guard let offset else { return nil }
        return parseUser(id: id, offset: offset, csv: csvData)
    }

    /// 一次更新的两个阶段：先下载整包，再本地建索引。
    enum Phase: Equatable {
        case downloading(Double?)
        case indexing
    }

    /// 下载 + 重建索引 + 落盘。`progress` 会先在下载阶段报百分比，再报一次「建索引」。
    ///
    /// 整个过程在后台执行，下载完成前旧库一直可用。
    func update(progress: @escaping (Phase) -> Void) async throws -> Snapshot {
        let downloaded = try await Self.download(progress: progress)
        defer { try? FileManager.default.removeItem(at: downloaded.url) }

        let csvURL = downloaded.url
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: csvURL.path),
              let size = attributes[.size] as? Int, size > 0 else {
            throw UpdateError.storage("下载的文件是空的")
        }

        progress(.indexing)
        let built = try await Task.detached(priority: .utility) {
            try RadioIDIndex.build(csvURL: csvURL)
        }.value

        let newSnapshot = Snapshot(count: built.count,
                                   bytes: size,
                                   updatedAt: Date(),
                                   source: downloaded.source)

        try install(csvURL: csvURL, index: built.index, snapshot: newSnapshot)
        return newSnapshot
    }

    /// 清空本地库（设置里将来要做「删除本地数据」时用）。
    func removeAll() {
        lock.lock()
        csvData = nil
        indexData = nil
        snapshot = nil
        lock.unlock()

        for url in [csvURL, indexURL, metaURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 落盘

    private var csvURL: URL { root.appendingPathComponent("users.csv") }
    private var indexURL: URL { root.appendingPathComponent("users.idx") }
    private var metaURL: URL { root.appendingPathComponent("meta.json") }

    private func prepareDirectory() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: root.path) else { return }
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)

        // 17 MB 的第三方数据不进 iCloud 备份。
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func install(csvURL source: URL, index: Data, snapshot: Snapshot) throws {
        let manager = FileManager.default
        let stagingCSV = root.appendingPathComponent("users.csv.tmp")
        let stagingIndex = root.appendingPathComponent("users.idx.tmp")

        try? manager.removeItem(at: stagingCSV)
        try? manager.removeItem(at: stagingIndex)

        do {
            try manager.copyItem(at: source, to: stagingCSV)
            try index.write(to: stagingIndex, options: .atomic)
        } catch {
            try? manager.removeItem(at: stagingCSV)
            try? manager.removeItem(at: stagingIndex)
            throw UpdateError.storage(error.localizedDescription)
        }

        // meta 是「这份库完整可用」的标记，最后写；中途断电只会留下没有 meta
        // 的孤儿文件，下次启动会当成没下载过。
        do {
            try? manager.removeItem(at: csvURL)
            try? manager.removeItem(at: indexURL)
            try manager.moveItem(at: stagingCSV, to: csvURL)
            try manager.moveItem(at: stagingIndex, to: indexURL)
        } catch {
            try? manager.removeItem(at: metaURL)
            throw UpdateError.storage(error.localizedDescription)
        }

        let meta = Meta(version: Self.formatVersion,
                        count: snapshot.count,
                        bytes: snapshot.bytes,
                        updatedAt: snapshot.updatedAt,
                        source: snapshot.source)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL, options: .atomic)
        }

        let mapped = Self.map(csvURL)
        let mappedIndex = Self.map(indexURL)

        // 抽查索引与 CSV 是否真的对得上（只可能在中途失败过之后出现）。
        // 对不上宁可当没库，也不能拿错的偏移去读别人的呼号。
        guard let mapped, let mappedIndex,
              RadioIDIndex.isConsistent(csv: mapped, index: mappedIndex) else {
            try? manager.removeItem(at: metaURL)
            throw UpdateError.storage("索引与数据文件对不上，已丢弃，请重新更新")
        }

        lock.lock()
        csvData = mapped
        indexData = mappedIndex
        self.snapshot = snapshot
        lock.unlock()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              meta.version == Self.formatVersion,
              let mapped = Self.map(csvURL),
              let mappedIndex = Self.map(indexURL),
              RadioIDIndex.isConsistent(csv: mapped, index: mappedIndex) else { return }

        lock.lock()
        csvData = mapped
        indexData = mappedIndex
        snapshot = Snapshot(count: meta.count,
                            bytes: meta.bytes,
                            updatedAt: meta.updatedAt,
                            source: meta.source)
        lock.unlock()
    }

    /// 内存映射读：17 MB 不必真的读进堆，查到哪一行就调哪一页。
    private static func map(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return nil
        }
        return data
    }

    // MARK: - 下载

    private static func download(progress: @escaping (Phase) -> Void) async throws -> (url: URL, source: String) {
        var lastError: Error?

        for urlString in mirrors {
            guard let url = URL(string: urlString) else { continue }
            let downloader = FileDownloader(maxBytes: maxBytes)
            do {
                let file = try await downloader.run(url: url) { written, expected in
                    if expected > 0 {
                        progress(.downloading(min(1, max(0, Double(written) / Double(expected)))))
                    } else {
                        progress(.downloading(nil))
                    }
                }
                return (file, url.host ?? urlString)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? UpdateError.download("没有可用的下载地址")
    }

    // MARK: - 行解析

    private func parseUser(id: Int, offset: Int, csv: Data) -> DMRUser? {
        csv.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DMRUser? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard offset >= 0, offset < raw.count else { return nil }

            var end = offset
            while end < raw.count, bytes[end] != 0x0A { end += 1 }
            var stop = end
            if stop > offset, bytes[stop - 1] == 0x0D { stop -= 1 }
            guard stop > offset else { return nil }

            var fields: [String] = []
            fields.reserveCapacity(7)
            var fieldStart = offset
            var cursor = offset
            var hasQuote = false

            while cursor < stop {
                let byte = bytes[cursor]
                if byte == RadioIDIndex.comma {
                    fields.append(RadioIDIndex.decode(bytes, fieldStart, cursor))
                    fieldStart = cursor + 1
                } else if byte == RadioIDIndex.quote {
                    hasQuote = true
                }
                cursor += 1
            }
            fields.append(RadioIDIndex.decode(bytes, fieldStart, stop))

            // 常规路径只按逗号切；碰到引号就整行重切一次（字段里可能有逗号）。
            // 真实数据里 316264 行只有 1 行带引号，这点开销可以忽略。
            if hasQuote {
                fields = RadioIDIndex.splitQuoted(bytes, from: offset, to: stop)
            }

            guard fields.count >= 2 else { return nil }
            let callsign = fields[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !callsign.isEmpty else { return nil }

            func field(_ index: Int) -> String {
                guard index < fields.count else { return "" }
                return fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return DMRUser(id: id,
                           callsign: callsign,
                           givenName: field(2),
                           surname: field(3),
                           city: field(4),
                           state: field(5))
        }
    }

    // MARK: - meta

    private struct Meta: Codable {
        var version: Int
        var count: Int
        var bytes: Int
        var updatedAt: Date
        var source: String
    }
}

// MARK: - 索引

enum RadioIDIndex {
    static let headerBytes = 8
    static let entryBytes = 8

    static let comma: UInt8 = 0x2C
    static let quote: UInt8 = 0x22
    static let lineFeed: UInt8 = 0x0A

    struct Built {
        let index: Data
        let count: Int
    }

    /// 扫一遍 CSV，把「ID → 行首字节偏移」压成定长记录并按 ID 排序。
    ///
    /// 排序用的是一个 UInt64 打包值 `(ID << 32) | 偏移`：一次 `sort()` 就同时得到
    /// 按 ID 升序的索引，不必再维护两份数组。CSV 只有十几 MB，偏移用 32 位足够。
    static func build(csvURL: URL) throws -> Built {
        let data: Data
        do {
            data = try Data(contentsOf: csvURL)
        } catch {
            throw RadioIDDatabase.UpdateError.storage(error.localizedDescription)
        }

        var packed: [UInt64] = []
        packed.reserveCapacity(320_000)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            var cursor = 0
            while cursor < raw.count {
                if bytes[cursor] == lineFeed {
                    appendEntry(bytes, from: lineStart, to: cursor, into: &packed)
                    lineStart = cursor + 1
                }
                cursor += 1
            }
            if lineStart < raw.count {
                appendEntry(bytes, from: lineStart, to: raw.count, into: &packed)
            }
        }

        guard packed.count > 1_000 else {
            throw RadioIDDatabase.UpdateError.parse("只有 \(packed.count) 条有效记录，文件内容不像用户库")
        }

        packed.sort()

        var index = Data(count: headerBytes + packed.count * entryBytes)
        index.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let out = raw.bindMemory(to: UInt8.self)
            out[0] = 0x52   // R
            out[1] = 0x49   // I
            out[2] = 0x44   // D
            out[3] = 0x58   // X
            let count = UInt32(packed.count)
            out[4] = UInt8(count & 0xFF)
            out[5] = UInt8((count >> 8) & 0xFF)
            out[6] = UInt8((count >> 16) & 0xFF)
            out[7] = UInt8((count >> 24) & 0xFF)

            var cursor = headerBytes
            for entry in packed {
                out[cursor] = UInt8(entry & 0xFF)
                out[cursor + 1] = UInt8((entry >> 8) & 0xFF)
                out[cursor + 2] = UInt8((entry >> 16) & 0xFF)
                out[cursor + 3] = UInt8((entry >> 24) & 0xFF)
                out[cursor + 4] = UInt8((entry >> 32) & 0xFF)
                out[cursor + 5] = UInt8((entry >> 40) & 0xFF)
                out[cursor + 6] = UInt8((entry >> 48) & 0xFF)
                out[cursor + 7] = UInt8((entry >> 56) & 0xFF)
                cursor += entryBytes
            }
        }

        return Built(index: index, count: packed.count)
    }

    /// 行首必须是数字 ID，紧随其后必须是逗号 —— 表头 `RADIO_ID,...` 和空行靠这条筛掉。
    private static func appendEntry(_ bytes: UnsafeBufferPointer<UInt8>,
                                    from start: Int,
                                    to end: Int,
                                    into out: inout [UInt64]) {
        var cursor = start
        var value: UInt64 = 0
        var digits = 0

        while cursor < end {
            let byte = bytes[cursor]
            guard byte >= 0x30, byte <= 0x39 else { break }
            value = value * 10 + UInt64(byte - 0x30)
            digits += 1
            cursor += 1
        }

        guard digits >= 4, cursor < end, bytes[cursor] == comma, value > 0, value <= 0xFFFF_FFFF else { return }
        out.append((value << 32) | UInt64(UInt32(truncatingIfNeeded: start)))
    }

    static func readUInt64(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt64 {
        UInt64(bytes[offset])
            | UInt64(bytes[offset + 1]) << 8
            | UInt64(bytes[offset + 2]) << 16
            | UInt64(bytes[offset + 3]) << 24
            | UInt64(bytes[offset + 4]) << 32
            | UInt64(bytes[offset + 5]) << 40
            | UInt64(bytes[offset + 6]) << 48
            | UInt64(bytes[offset + 7]) << 56
    }

    /// 抽查首 / 中 / 尾三条：索引里的偏移指向的那一行，必须真的以「ID + 逗号」开头。
    ///
    /// 正常流程下两边一定是同一份数据；这条检查只为兜住「CSV 换成了新的、索引还是旧的」
    /// 这种半新半旧的状态（比如换文件时断电）。对不上就当没库，绝不能拿错的偏移
    /// 去读别人的呼号。
    static func isConsistent(csv: Data, index: Data) -> Bool {
        guard !csv.isEmpty else { return false }

        return index.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard raw.count >= headerBytes else { return false }
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            guard count > 0, raw.count >= headerBytes + count * entryBytes else { return false }

            for position in [0, count / 2, count - 1] {
                let value = readUInt64(bytes, at: headerBytes + position * entryBytes)
                let id = UInt64(value >> 32)
                let offset = Int(value & 0xFFFF_FFFF)
                guard offset < csv.count else { return false }

                // 把偏移那一行的开头数字读出来跟索引比。按数值比而不是按字符串比：
                // 真实数据里可能有 `0076543` 这种前导零，按字符串比会误判。
                var cursor = offset
                var parsed: UInt64 = 0
                var digits = 0
                while cursor < csv.count {
                    let byte = csv[cursor]
                    if byte == comma { break }
                    guard byte >= 0x30, byte <= 0x39 else { return false }
                    parsed = parsed &* 10 &+ UInt64(byte - 0x30)
                    digits += 1
                    guard digits <= 12 else { return false }
                    cursor += 1
                }
                guard digits > 0, cursor < csv.count, parsed == id else { return false }
            }
            return true
        }
    }

    static func decode(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        guard end > start else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
    }

    /// 带引号的 CSV 切分：`"a,b",c` → `["a,b", "c"]`，`""` 是转义的双引号。
    ///
    /// RadioID 的 user.csv 里 31.6 万行只有 1 行带引号（`"La Victoria Aragua"`），
    /// 但万一哪天出现 `"City, State"` 这种含逗号的字段，按逗号硬切会让后面所有列错位。
    static func splitQuoted(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> [String] {
        var fields: [String] = []
        fields.reserveCapacity(7)
        var current: [UInt8] = []
        current.reserveCapacity(32)
        var inQuotes = false
        var cursor = start

        while cursor < end {
            let byte = bytes[cursor]

            if inQuotes {
                if byte == quote {
                    if cursor + 1 < end, bytes[cursor + 1] == quote {
                        current.append(quote)
                        cursor += 2
                        continue
                    }
                    inQuotes = false
                    cursor += 1
                    continue
                }
                current.append(byte)
                cursor += 1
                continue
            }

            if byte == quote {
                inQuotes = true
                cursor += 1
                continue
            }

            if byte == comma {
                fields.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
                cursor += 1
                continue
            }

            current.append(byte)
            cursor += 1
        }

        fields.append(String(decoding: current, as: UTF8.self))
        return fields
    }
}

// MARK: - 带进度的下载

/// `URLSession.download` 的 async 包装，顺便把进度报出来。
///
/// 用 `URLSessionDownloadTask` 而不是 `data(for:)`：17 MB 落在磁盘上，解析时再读，
/// 内存峰值只有一份；`data(for:)` 会在内存里堆出整包。
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// 注意别叫 `Progress` —— Foundation 里已经有一个同名类，容易看岔。
    typealias ProgressHandler = (Int64, Int64) -> Void

    private let maxBytes: Int64
    private var progress: ProgressHandler?
    private var continuation: CheckedContinuation<URL, Error>?
    private var saved: URL?
    private var failure: Error?
    /// 上一次上报的字节数。17 MB 会回调几百次，每 256 KB 报一次就够界面用了。
    private var lastReported: Int64 = 0

    init(maxBytes: Int64) {
        self.maxBytes = maxBytes
    }

    func run(url: URL, progress: @escaping ProgressHandler) async throws -> URL {
        self.progress = progress

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = true

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if maxBytes > 0, totalBytesExpectedToWrite > maxBytes {
            failure = RadioIDDatabase.UpdateError.download("文件大小 \(totalBytesExpectedToWrite) 字节，超出预期")
            downloadTask.cancel()
            return
        }

        let finished = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard finished || totalBytesWritten - lastReported >= 262_144 else { return }
        lastReported = totalBytesWritten
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = RadioIDDatabase.UpdateError.download("HTTP \(http.statusCode)")
            return
        }

        // 这个回调返回后系统就会删掉临时文件，必须在这里挪走。
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("radioid-\(UUID().uuidString).csv")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            saved = destination
        } catch {
            failure = RadioIDDatabase.UpdateError.storage(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        progress = nil

        guard let continuation else { return }

        // 主动取消（文件超大）时 error 也是非 nil，但它只是想说明「被取消了」，
        // 真正的理由在 failure 里，所以先看 failure。
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            continuation.resume(throwing: RadioIDDatabase.UpdateError.download(error.localizedDescription))
        } else if let saved {
            continuation.resume(returning: saved)
        } else {
            continuation.resume(throwing: RadioIDDatabase.UpdateError.download("下载没有产生文件"))
        }
    }
}
