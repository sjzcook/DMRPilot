//
//  TalkgroupPickerField.swift
//  DMRPilot
//
//  首页「连接」按钮右边的通话组选择器。
//  交互与设置页选择服务器（HostPickerField）一致：一行触发器，点开是弹出式列表，
//  顶部有范围切换 + 搜索框，行尾带勾选，末尾还能手填号码。
//
//  数据来自 BrandMeister 的 v2/talkgroup（AppState.talkgroups），只是显示用的名称表，
//  真正订阅还是走 AppState.setTalkgroup。
//

import SwiftUI
import UIKit

struct TalkgroupPickerField: View {
    /// 全球通话组名称表。表还没下载完时是空的。
    let talkgroups: [Int: String]
    /// 当前选中的组，0 = 听全部。
    let selected: Int
    let isLoading: Bool
    let error: String?
    /// 选中一项（0 = 全部）后回调，调用方负责订阅 + 持久化。
    let onSelect: (Int) -> Void
    let onRefresh: () async -> Void

    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            trigger
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPicking) {
            TalkgroupPickerSheet(talkgroups: talkgroups,
                                 selected: selected,
                                 isLoading: isLoading,
                                 error: error,
                                 onSelect: onSelect,
                                 onRefresh: onRefresh)
        }
    }

    // MARK: - 触发器

    private var trigger: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color(uiColor: .secondarySystemFill),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityLabel("通话组")
        .accessibilityValue(selected > 0 ? "TG \(selected)" : "全部通话组")
        .accessibilityHint("点击选择要收听的通话组")
    }

    private var name: String? {
        guard selected > 0 else { return nil }
        return talkgroups[selected]
    }

    /// 有名字显示名字，没名字就显示编号——跟首页别处的写法保持一致。
    private var title: String {
        guard selected > 0 else { return "全部通话组" }
        return name ?? "TG \(selected)"
    }

    private var subtitle: String {
        guard selected > 0 else { return "收听全部" }
        return name == nil ? "自定义 · TG \(selected)" : "TG \(selected)"
    }
}

// MARK: - 弹出选择器

private enum TalkgroupScope: String, CaseIterable, Identifiable {
    case china
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .china: return "中国"
        case .all: return "全部"
        }
    }
}

/// 表里的一个组。列表要按编号排序，字典直接 `sorted` 一遍存起来，别每次输入都重排。
private struct TalkgroupEntry: Identifiable {
    let id: Int
    let name: String
}

private struct TalkgroupPickerSheet: View {
    let entries: [TalkgroupEntry]
    let selected: Int
    let isLoading: Bool
    let error: String?
    let onSelect: (Int) -> Void
    let onRefresh: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var scope: TalkgroupScope = .china
    @State private var isManual = false
    @State private var manualDraft = ""
    @FocusState private var manualFocused: Bool

    /// 一次最多渲染多少条，和服务器选择器一致。
    private let resultLimit = 60

    init(talkgroups: [Int: String],
         selected: Int,
         isLoading: Bool,
         error: String?,
         onSelect: @escaping (Int) -> Void,
         onRefresh: @escaping () async -> Void) {
        self.entries = talkgroups
            .map { TalkgroupEntry(id: $0.key, name: $0.value) }
            .sorted { $0.id < $1.id }
        self.selected = selected
        self.isLoading = isLoading
        self.error = error
        self.onSelect = onSelect
        self.onRefresh = onRefresh
    }

    // MARK: - 数据

    private var baseList: [TalkgroupEntry] {
        switch scope {
        case .china:
            // 460xxx 是中国区的编号段（4601、46001、46099…），前缀判断足够。
            return entries.filter { String($0.id).hasPrefix("460") }
        case .all:
            return entries
        }
    }

    private var filtered: [TalkgroupEntry] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return baseList }
        return baseList.filter { entry in
            entry.name.localizedCaseInsensitiveContains(keyword)
                || String(entry.id).hasPrefix(keyword)
                || String(entry.id).contains(keyword)
        }
    }

    private var visible: [TalkgroupEntry] {
        Array(filtered.prefix(resultLimit))
    }

    private var manualValue: Int? {
        guard let value = Int(manualDraft.trimmingCharacters(in: .whitespaces)),
              (1...16_777_215).contains(value) else { return nil }
        return value
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("范围", selection: $scope) {
                    ForEach(TalkgroupScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

                list
            }
            .navigationTitle("选择通话组")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "按名称或号码搜索，如 460 / China")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await onRefresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            Section {
                manualRow
            }

            if isManual {
                Section {
                    HStack(spacing: 8) {
                        // 键盘用文本类型（默认键盘），不再强拉数字盘。
                        // 号码合法性仍由 manualValue 校验，非法时下面出红字、确定置灰。
                        TextField("输入号码，最大 16777215", text: $manualDraft)
                            .keyboardType(.default)
                            .monospacedDigit()
                            .focused($manualFocused)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color(uiColor: .secondarySystemFill),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                        Button("确定") { commitManual() }
                            .buttonStyle(.borderless)
                            .fontWeight(.semibold)
                            .disabled(manualValue == nil)
                    }
                } footer: {
                    if !manualDraft.isEmpty && manualValue == nil {
                        Text("号码要在 1…16777215 之间（DMR 目的地址是 24 位）")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                if visible.isEmpty {
                    emptyRow
                } else {
                    ForEach(visible) { entry in
                        entryRow(entry)
                    }
                    if filtered.count > resultLimit {
                        Text("还有 \(filtered.count - resultLimit) 个没显示，继续输入关键字缩小范围")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.plain)
    }

    private var manualRow: some View {
        Button {
            isManual = true
            if manualDraft.isEmpty, selected > 0 { manualDraft = "\(selected)" }
            // 字段刚插进列表，等一帧再抢焦点，否则 focus 会落到空处。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { manualFocused = true }
        } label: {
            HStack(spacing: 8) {
                Text("手动输入号码")
                    .font(.subheadline)
                Spacer(minLength: 8)
                if selected > 0 && !entries.contains(where: { $0.id == selected }) { checkmark }
                Image(systemName: isManual ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func entryRow(_ entry: TalkgroupEntry) -> some View {
        Button {
            commit(entry.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("TG \(entry.id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if entry.id == selected { checkmark }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.footnote.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 14)
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isLoading {
                Text("正在下载通话组列表…")
            } else if entries.isEmpty {
                Text("列表还没下载下来，点右上角刷新重试")
            } else if !query.isEmpty && scope == .china {
                Text("中国区里没有匹配「\(query)」的通话组")
                Text("切到「全部」再看看，或者用手动输入")
                    .foregroundStyle(.secondary)
            } else {
                Text("没有匹配「\(query)」的通话组")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func commitManual() {
        guard let value = manualValue else { return }
        commit(value)
    }

    /// 列表点选和手动输入「确定」都走这里，两者行为必须一模一样。
    ///
    /// 收掉手填框的焦点（还在输入时键盘没退），再交给上层切组：`AppState.setTalkgroup`
    /// 会先把旧组上挂着的通话收尾、换掉旧的订阅，然后向新组订阅一次，
    /// 所以「选择后自动断掉原来的组，切到选定的组」这件事由同一个入口保证。
    private func commit(_ value: Int) {
        manualFocused = false
        onSelect(value)
        dismiss()
    }
}
