//
//  CallLogView.swift
//  DMRPilot
//
//  日志页：所有已经结束的通话，按天归档。
//
//  数据来自本地 SQLite（`CallLogStore`），不是内存里的 `HomebrewClient.calls`——
//  内存那份按 200 条裁剪，只够首页用；日志要的是「一句都不少」，
//  所以退出 App、重启手机之后这里还在。
//
//  支持按呼号 / 数字 ID / 姓名 / 城市 / 通话组名搜索，过滤在 SQL 里做，
//  翻页时不会漏掉后面的记录。
//

import Foundation
import SwiftUI

struct CallLogView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var callsigns: CallsignDirectory
    /// 落盘的记录（SQLite）。单例，在 App 入口注入。
    @EnvironmentObject private var log: CallLogStore

    @State private var query = ""
    @State private var showClearConfirm = false
    @State private var searchWork: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if log.entries.isEmpty {
                    emptySection
                } else {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                row(for: item.record)
                                    .onAppear { loadMoreIfNeeded(item) }
                            }
                        }
                    }

                    footerSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("日志")
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "按呼号 / ID / 通话组搜索")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if log.total > 0 {
                        Text("\(log.total) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(log.total == 0)
                    .accessibilityLabel("清空通话记录")
                }
            }
            .confirmationDialog("清空所有通话记录？",
                                isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("清空", role: .destructive) { hotspotClear() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会把本机数据库里记下的全部通话删除，删了找不回来。正在说的那一句不受影响。")
            }
            .task {
                log.reload()
                lookupCallsigns()
            }
            // 打字时不要每敲一个字符就查一次库
            .onChange(of: query) { newValue in
                searchWork?.cancel()
                searchWork = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    guard !Task.isCancelled else { return }
                    log.reload(keyword: newValue)
                }
            }
        }
    }

    // MARK: - 数据

    private var groups: [LogGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [LogItem]] = [:]

        for record in log.entries {
            let day = calendar.startOfDay(for: record.startedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(LogItem(record: record))
        }

        return order.map { day in
            LogGroup(day: day, title: Self.dayTitle(day), items: buckets[day] ?? [])
        }
    }

    /// 走到底了就取下一页。
    private func loadMoreIfNeeded(_ item: LogItem) {
        guard item.id == log.entries.last?.id else { return }
        log.loadMore()
    }

    /// 历史记录的呼号可能还没查到（先记了日志、之后才更新 ID 库），
    /// 这里把当前几页里缺的 ID 送进查询队列。本地库能答的不发网络请求。
    private func lookupCallsigns() {
        let missing = log.entries.filter { $0.callsign == nil }.prefix(30).map(\.src)
        guard !missing.isEmpty else { return }
        callsigns.request(Array(missing))
    }

    private func hotspotClear() {
        query = ""
        // 清库 + 清掉内存里那几十条，首页的「刚刚结束」也跟着空
        app.hotspot.clearCallLog()
    }

    // MARK: - 行

    private func row(for record: CallRecord) -> some View {
        let user = callsigns.user(for: record.src)
        let callsign = record.callsign ?? user?.callsign
        let name = record.name ?? user?.fullName

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(callsign ?? "\(record.src)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if let name, !name.isEmpty {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(subtitle(for: record, user: user))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.clock.string(from: record.startedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(Fmt.duration(record.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// `通话组 · TS2 · 12 帧`；单呼再补一句，省得跟组呼混在一起。
    private func subtitle(for record: CallRecord, user: DMRUser?) -> String {
        var parts: [String] = []

        if record.isPrivate {
            parts.append("单呼 \(record.src) → \(record.dst)")
        } else if let name = record.dstName ?? app.name(for: record.dst) {
            parts.append("\(name) · TG \(record.dst)")
        } else {
            parts.append("TG \(record.dst)")
        }

        // ODTP 没有时隙概念，标 TS2 只会误导
        if app.settings.linkProtocol == .homebrew {
            parts.append("TS\(record.slot)")
        }

        parts.append("\(record.frames) 帧")

        if let city = record.city ?? user?.placeText, !city.isEmpty {
            parts.append(city)
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - 空态 / 尾巴

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if log.isLoading {
                    Text("正在读取本地记录…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("还没有通话记录")
                        .font(.subheadline.weight(.medium))
                    Text("连上服务器后，每说完一句就会写进本机的数据库；退出 App 也不会丢。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("没有匹配「\(query)」的记录")
                        .font(.subheadline.weight(.medium))
                    Text("完整呼号可以只输入一部分；还没查到呼号的记录可以用数字 ID 或通话组名搜。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        if log.hasMore {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .onAppear { log.loadMore() }
            }
        } else if let error = log.errorText {
            Section {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 格式化

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()

    private static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return monthDay.string(from: day)
        }
        return fullDate.string(from: day)
    }
}

// MARK: - 分组

/// 一条记录的外壳。主键直接用数据库自增 id——同一个 src 说两句也不会撞。
private struct LogItem: Identifiable {
    let record: CallRecord
    var id: Int64 { record.id }
}

private struct LogGroup: Identifiable {
    let day: Date
    let title: String
    let items: [LogItem]

    var id: Date { day }
}
