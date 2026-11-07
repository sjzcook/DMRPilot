//
//  CallLogStore.swift
//  DMRPilot
//
//  通话记录落盘：SQLite（`Application Support/DMRPilot/calls.sqlite3`）。
//
//  ── 为什么单独开一张表 ────────────────────────────────────────────
//
//  协议层只认得「这一句说完了」，没有历史概念；内存里的 `HomebrewClient.calls`
//  还按 200 条裁剪着给首页用。日志页要的是「一句都不少」，所以凡是收尾的通话
//  都在这里写一行，表只增不减（除非用户点清空）。
//
//  表结构刻意做成扁平的一张，不拆 src / dst 两张字典：
//    - 呼号、姓名、城市、通话组名在写入那一刻**快照**下来。日志记录的是当时
//      对外呈现的样子，之后本地 DMR ID 库更新了也不会把历史改掉。
//    - 好处是搜索能全走 SQL：`LIKE` 一次扫完，翻页不用先在内存里过滤，
//      「不裁剪」之后表可以有几万行也不怕。
//
//  唯一键是 (src, dst, slot, started_at)：同一次通话被收尾两次（先看门狗、
//  再断线）只会更新那一行，不会写出两条。
//

import Foundation
import SQLite3

// MARK: - 一条记录

/// 一条已经结束的通话。
///
/// 字段名和 `LiveCall` 对得上，但这是**从数据库读出来的历史**，
/// 不再随内存里的通话状态变化。
struct CallRecord: Identifiable, Equatable {
    /// 数据库自增主键；写入前是 0。
    let id: Int64
    let src: Int
    let dst: Int
    let slot: Int
    let isPrivate: Bool
    let startedAt: Date
    let endedAt: Date
    let frames: Int
    /// 写入那一刻的呼号快照（本地 DMR ID 库查不到时是 nil）。
    let callsign: String?
    let name: String?
    let city: String?
    /// 通话组名快照。
    let dstName: String?

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

// MARK: - 数据库

/// 纯 SQLite 层：不碰 UI，所有操作都排在自己的串行队列上。
///
/// `@unchecked Sendable` 是因为线程安全靠 `queue` 保证，而不是靠编译器。
final class CallLogDatabase: @unchecked Sendable {

    struct Page {
        let rows: [CallRecord]
        /// 满足条件的总条数（不是这一页的条数）。
        let total: Int
    }

    private let queue = DispatchQueue(label: "com.sjzcook.dmrpilot.calllog", qos: .utility)
    private var handle: OpaquePointer?
    private(set) var openError: String?

    init() {
        let manager = FileManager.default
        let base = (try? manager.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = base.appendingPathComponent("DMRPilot", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = folder.appendingPathComponent("calls.sqlite3")
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            openError = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let pointer { sqlite3_close(pointer) }
            return
        }

        handle = pointer
        sqlite3_busy_timeout(pointer, 3_000)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec(Self.schema)
    }

    deinit {
        // 单例活到进程结束，这个分支实际走不到；真走到时也不抢队列，
        // 免得在队列自己身上 sync 死锁。
        if let handle { sqlite3_close(handle) }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS calls (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        src         INTEGER NOT NULL,
        dst         INTEGER NOT NULL,
        slot        INTEGER NOT NULL,
        is_private  INTEGER NOT NULL DEFAULT 0,
        started_at  REAL    NOT NULL,
        ended_at    REAL    NOT NULL,
        frames      INTEGER NOT NULL DEFAULT 0,
        callsign    TEXT,
        name        TEXT,
        city        TEXT,
        dst_name    TEXT
    );
    CREATE UNIQUE INDEX IF NOT EXISTS ux_calls ON calls(src, dst, slot, started_at);
    CREATE INDEX IF NOT EXISTS ix_calls_started ON calls(started_at DESC);
    CREATE INDEX IF NOT EXISTS ix_calls_src ON calls(src);
    CREATE INDEX IF NOT EXISTS ix_calls_dst ON calls(dst);
    """

    // MARK: 写

    /// 落一条记录。`finished` 在写完之后回主线程调用。
    func insert(_ record: CallRecord, finished: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }

            let sql = """
            INSERT INTO calls (src, dst, slot, is_private, started_at, ended_at, frames,
                               callsign, name, city, dst_name)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            ON CONFLICT(src, dst, slot, started_at) DO UPDATE SET
                ended_at = excluded.ended_at,
                frames   = MAX(calls.frames, excluded.frames),
                callsign = COALESCE(calls.callsign, excluded.callsign),
                name     = COALESCE(calls.name, excluded.name),
                city     = COALESCE(calls.city, excluded.city),
                dst_name = COALESCE(calls.dst_name, excluded.dst_name)
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, Int64(record.src))
            sqlite3_bind_int64(statement, 2, Int64(record.dst))
            sqlite3_bind_int(statement, 3, Int32(record.slot))
            sqlite3_bind_int(statement, 4, record.isPrivate ? 1 : 0)
            sqlite3_bind_double(statement, 5, record.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, record.endedAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 7, Int64(record.frames))
            bind(statement, 8, record.callsign)
            bind(statement, 9, record.name)
            bind(statement, 10, record.city)
            bind(statement, 11, record.dstName)

            if sqlite3_step(statement) != SQLITE_DONE {
                #if DEBUG
                print("通话记录写入失败：\(String(cString: sqlite3_errmsg(handle)))")
                #endif
            }
            if let finished { DispatchQueue.main.async(execute: finished) }
        }
    }

    /// 给某个 ID 的历史记录补上呼号（本地 DMR ID 库更新后再进日志页会用到）。
    func fillContact(callsign: String?, name: String?, city: String?, for source: Int) {
        guard callsign != nil || name != nil || city != nil else { return }
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            let sql = """
            UPDATE calls
               SET callsign = COALESCE(callsign, ?1),
                   name     = COALESCE(name, ?2),
                   city     = COALESCE(city, ?3)
             WHERE src = ?4 AND (callsign IS NULL OR name IS NULL OR city IS NULL)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return }
            defer { sqlite3_finalize(statement) }
            self.bind(statement, 1, callsign)
            self.bind(statement, 2, name)
            self.bind(statement, 3, city)
            sqlite3_bind_int64(statement, 4, Int64(source))
            _ = sqlite3_step(statement)
        }
    }

    /// 清空整张表。返回删掉的条数。
    func deleteAll(finished: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else {
                DispatchQueue.main.async { finished(0) }
                return
            }
            let before = self.countLocked(handle, keyword: "")
            self.exec("DELETE FROM calls;")
            // 自增主键从头开始，免得列表 id 一路涨
            self.exec("DELETE FROM sqlite_sequence WHERE name = 'calls';")
            DispatchQueue.main.async { finished(before) }
        }
    }

    // MARK: 读

    /// 按开始时间倒序取一页。`keyword` 为空表示不过滤。
    func page(keyword: String, limit: Int, offset: Int, finished: @escaping (Page) -> Void) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else {
                DispatchQueue.main.async { finished(Page(rows: [], total: 0)) }
                return
            }

            let (whereClause, pattern) = Self.filter(keyword)
            let sql = """
            SELECT id, src, dst, slot, is_private, started_at, ended_at, frames,
                   callsign, name, city, dst_name
              FROM calls
            \(whereClause)
             ORDER BY started_at DESC, id DESC
             LIMIT ?2 OFFSET ?3
            """

            var rows: [CallRecord] = []
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement {
                defer { sqlite3_finalize(statement) }
                if let pattern { self.bind(statement, 1, pattern) } else { sqlite3_bind_null(statement, 1) }
                sqlite3_bind_int(statement, 2, Int32(limit))
                sqlite3_bind_int(statement, 3, Int32(offset))

                while sqlite3_step(statement) == SQLITE_ROW {
                    rows.append(CallRecord(
                        id: sqlite3_column_int64(statement, 0),
                        src: Int(sqlite3_column_int64(statement, 1)),
                        dst: Int(sqlite3_column_int64(statement, 2)),
                        slot: Int(sqlite3_column_int(statement, 3)),
                        isPrivate: sqlite3_column_int(statement, 4) != 0,
                        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                        endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                        frames: Int(sqlite3_column_int64(statement, 7)),
                        callsign: self.text(statement, 8),
                        name: self.text(statement, 9),
                        city: self.text(statement, 10),
                        dstName: self.text(statement, 11)
                    ))
                }
            }

            let total = self.countLocked(handle, keyword: keyword)
            DispatchQueue.main.async { finished(Page(rows: rows, total: total)) }
        }
    }

    // MARK: 内部

    private static func filter(_ keyword: String) -> (String, String?) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }
        let pattern = "%\(escapeLike(trimmed))%"
        let clause = """
        WHERE (callsign LIKE ?1 ESCAPE '\\'
            OR name     LIKE ?1 ESCAPE '\\'
            OR city     LIKE ?1 ESCAPE '\\'
            OR dst_name LIKE ?1 ESCAPE '\\'
            OR CAST(src AS TEXT) LIKE ?1 ESCAPE '\\'
            OR CAST(dst AS TEXT) LIKE ?1 ESCAPE '\\')
        """
        return (clause, pattern)
    }

    private static func escapeLike(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\", "%", "_":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    private func countLocked(_ handle: OpaquePointer, keyword: String) -> Int {
        let (whereClause, pattern) = Self.filter(keyword)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM calls \(whereClause);", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        if let pattern { bind(statement, 1, pattern) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqlTransient)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let handle else { return false }
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }
}

/// SQLite 要求「语句执行完再拷贝」的析构标记。
private let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 界面状态

/// 日志页的数据源。@MainActor 这一侧只负责分页状态，真正的 SQL 全在后台队列。
///
/// **不做任何裁剪**：写入只有 INSERT，没有「超过 N 条删最旧」的逻辑。
@MainActor
final class CallLogStore: ObservableObject {

    static let shared = CallLogStore()

    /// 每页条数。滚动到底再取下一页，几万行的表也不会一次读进内存。
    private static let pageSize = 100

    @Published private(set) var entries: [CallRecord] = []
    /// 当前筛选条件下的总条数。
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorText: String?
    /// 有新记录写进库时自增，日志页靠它决定要不要刷新第一页。
    @Published private(set) var revision = 0

    /// 查本地 DMR ID 库。由 `AppState` 启动时挂上来（weak，不持有）。
    weak var callsigns: CallsignDirectory?
    /// 通话组名称表也在 `AppState` 里。
    weak var app: AppState?

    private let db = CallLogDatabase()
    private var keyword = ""
    /// 每次重新加载 +1，用来丢弃过期的分页结果（搜索时连打几个字）。
    private var loadToken = 0
    private var isLoadingMore = false

    private init() {
        if let message = db.openError {
            errorText = "通话记录数据库打不开：\(message)"
        }
        reload()
    }

    // MARK: 写

    /// 通话收尾时调用。可以重复调用，唯一键保证只留一行。
    func record(_ call: LiveCall) {
        let user = callsigns?.user(for: call.src)
        let record = CallRecord(id: 0,
                                src: call.src,
                                dst: call.dst,
                                slot: call.slot,
                                isPrivate: call.isPrivate,
                                startedAt: call.startedAt,
                                endedAt: call.updatedAt,
                                frames: call.frames,
                                callsign: user?.callsign,
                                name: Self.clean(user?.fullName),
                                city: Self.clean(user?.placeText),
                                dstName: app?.name(for: call.dst))

        db.insert(record) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.revision &+= 1
                self.refreshIfAtTop()
            }
        }
    }

    /// 补历史记录的呼号：本地库查得到但库里快照是空的那种（比如先记了日志、
    /// 之后才点「更新数据」）。只处理当前已经读到内存的这几页。
    func fillMissingContacts() {
        var seen: Set<Int> = []
        for entry in entries where entry.callsign == nil || entry.name == nil {
            guard seen.insert(entry.src).inserted else { continue }
            guard let user = callsigns?.user(for: entry.src) else { continue }
            db.fillContact(callsign: user.callsign,
                           name: Self.clean(user.fullName),
                           city: Self.clean(user.placeText),
                           for: entry.src)
        }
    }

    // MARK: 读

    func reload(keyword newKeyword: String? = nil) {
        if let newKeyword {
            keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        loadToken &+= 1
        let token = loadToken
        isLoading = true
        isLoadingMore = false

        db.page(keyword: keyword, limit: Self.pageSize, offset: 0) { [weak self] page in
            Task { @MainActor [weak self] in
                guard let self, token == self.loadToken else { return }
                self.entries = page.rows
                self.total = page.total
                self.hasMore = page.rows.count < page.total
                self.isLoading = false
                self.errorText = nil
                self.fillMissingContacts()
            }
        }
    }

    /// 滚到底时追加下一页。
    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        let token = loadToken
        let offset = entries.count

        db.page(keyword: keyword, limit: Self.pageSize, offset: offset) { [weak self] page in
            Task { @MainActor [weak self] in
                guard let self, token == self.loadToken else { return }
                self.isLoadingMore = false
                guard !page.rows.isEmpty else {
                    self.hasMore = false
                    return
                }
                self.entries.append(contentsOf: page.rows)
                self.total = page.total
                self.hasMore = self.entries.count < page.total
                self.fillMissingContacts()
            }
        }
    }

    /// 新记录进库后由日志页判断要不要刷第一页（翻过页就保持原位）。
    func refreshIfAtTop() {
        guard entries.count <= Self.pageSize else { return }
        reload()
    }

    // MARK: 删

    func clear() {
        db.deleteAll { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.revision &+= 1
                self.reload()
            }
        }
    }

    // MARK: 杂项

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
