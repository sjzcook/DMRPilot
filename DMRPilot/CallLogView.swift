//
//  CallLogView.swift
//  DMRPilot
//
//  日志页：所有说过话的人，按最近一次通话的日期归档。
//
//  数据来自本地 SQLite（`CallLogStore`），不是内存里的 `HomebrewClient.calls`——
//  内存那份按 200 条裁剪，只够首页用；日志要的是「一句都不少」，
//  所以退出 App、重启手机之后这里还在。同一个人说多次只占一行，
//  那一行显示的是最近一次（时间 / 通话组都换成最新的）。
//
//  每一行是一张卡片，三行文字：呼号+姓名 / 通话组（与时隙）/ 地区。
//
//  支持按呼号 / 数字 ID / 姓名 / 城市 / 通话组名搜索，过滤在 SQL 里做，
//  翻页时不会漏掉后面的记录。单条记录可以左滑删除。
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
                                    // 卡片样式：去掉默认行底色和分隔线，卡片自己画圆角底。
                                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    // 左滑删单条：只删这一行，不影响其他人，也不影响首页内存里那份。
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            log.delete(item.record.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                        // 顶层 `.tint(.blue)` 会把左滑按钮也染成蓝色，
                                        // 这里显式指定红色，保证删除按钮和全滑底色都是红的。
                                        .tint(.red)
                                    }
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

    /// 一条记录的卡片：左边三行文字（呼号+姓名 / 通话组 / 地区），右边时间与时长。
    private func row(for record: CallRecord) -> some View {
        let user = callsigns.user(for: record.src)
        let callsign = record.callsign ?? user?.callsign
        let name = record.name ?? user?.fullName
        let place = record.city ?? user?.placeText

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 第一行：呼号 + 姓名
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

                // 第二行：通话组（Homebrew 下再带时隙）
                Text(channelText(for: record))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // 第三行：地区
                if let place, !place.isEmpty {
                    Text(place)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.clock.string(from: record.startedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(Fmt.duration(record.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    /// `通话组 · TG 46001`；单呼另说，Homebrew 下再补 TSx。
    private func channelText(for record: CallRecord) -> String {
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
                    Text("连上服务器后，每个人的最近一次通话都会写进本机的数据库；同一个人只占一行，左滑可以删掉。")
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
