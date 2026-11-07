//
//  HostPickerField.swift
//  DMRPilot
//
//  首页连接按钮上方的「服务器」选择器：一行下拉触发器 + 自定义域名输入框。
//  点开后是弹出式选择器（sheet），列表来自 DMRHosts.txt / YSFHosts.txt，
//  搜索框固定在列表上方，按 Hostname（顺带匹配表里的名字）过滤。
//  选中一项就把 name / hostname / port 写回 Settings。
//  kind 决定加载哪份列表：首页右上角模式选 YSF 就看 YSF 反射器，DMR 看 DMR。
//

import SwiftUI

struct HostPickerField: View {
    @ObservedObject var store: DMRHostStore
    /// 挑哪一类服务器：首页按右上角模式菜单传 DMR / YSF。
    var kind: HostKind = .dmr
    @Binding var settings: Settings
    /// 服务器变了（选中表里一台，或手填域名回车）之后的回调。
    /// 首页拿它做「自动断开重连」，所以这里只负责通知，不判断连接状态。
    var onServerChange: () -> Void = {}

    @State private var isPicking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            triggerRow
            if selectedHost == nil { domainField }
        }
        .task { await store.loadIfNeeded() }
        .sheet(isPresented: $isPicking) {
            HostPickerSheet(store: store, kind: kind, settings: $settings, onServerChange: onServerChange)
        }
    }

    // MARK: - 数据

    private var selectedHost: DMRHost? {
        guard !settings.hostName.isEmpty else { return nil }
        // 先在当前类型的列表里找；模式刚切过来、旧选择属于另一类时
        // 退回两份一起找——名字至少还显示得出来，选新服务器时再覆盖。
        if let hit = store.allHosts(of: kind).first(where: { $0.name == settings.hostName }) {
            return hit
        }
        return (store.hosts + store.ysfHosts).first { $0.name == settings.hostName }
    }

    // MARK: - 下拉触发器

    /// 和通话组选择器（TalkgroupPickerField）同一套版式：
    /// 左边两行文字（名称 / host:port），右边下拉箭头，灰底圆角块。
    /// 没有左侧图标，也不显示右侧的 BM 标签。
    private var triggerRow: some View {
        Button {
            isPicking = true
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedHost?.name ?? "选择服务器")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text("\(settings.host):\(String(settings.port))")
                        .font(.caption2)
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
            .accessibilityLabel("服务器")
            .accessibilityValue(selectedHost?.name ?? "未选择")
            .accessibilityHint("点击选择要连接的服务器")
        }
        .buttonStyle(.plain)
    }

    // MARK: - 自定义域名

    /// 没选中表里任何一台时，允许直接填域名（私服 / 自建 HBLink）。
    private var domainField: some View {
        HStack(spacing: 6) {
            Text("域名")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("api.brandmeister.network", text: $settings.host)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .multilineTextAlignment(.trailing)
                // 手填的域名没法每敲一个字符就重连，按下回车才算定下来。
                .onSubmit { onServerChange() }
        }
        .padding(.leading, 10)
    }
}

// MARK: - 弹出选择器

private enum HostScope: String, CaseIterable, Identifiable {
    case brandMeister
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brandMeister: return "BrandMeister"
        case .all: return "全部"
        }
    }
}

private struct HostPickerSheet: View {
    @ObservedObject var store: DMRHostStore
    /// 和触发器同一个类型：决定列表加载 DMR 还是 YSF。
    var kind: HostKind = .dmr
    @Binding var settings: Settings
    var onServerChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var scope: HostScope = .brandMeister

    /// 一次最多渲染多少条，避免 1200 多条全进列表。
    private let resultLimit = 60

    // MARK: - 数据

    /// 当前类型下的全量列表（范围过滤之前）。
    private var kindList: [DMRHost] {
        store.allHosts(of: kind)
    }

    private var baseList: [DMRHost] {
        // 范围切换只有 DMR 有意义（BrandMeister / 全部）；
        // YSF 反射器表没有这个划分，直接列全部。
        guard kind == .dmr else { return kindList }
        switch scope {
        case .brandMeister: return store.brandMeisterHosts
        case .all: return kindList
        }
    }

    private var filtered: [DMRHost] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return baseList }
        return baseList.filter {
            $0.hostname.localizedCaseInsensitiveContains(keyword)
                || $0.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var visible: [DMRHost] {
        Array(filtered.prefix(resultLimit))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if kind == .dmr {
                    Picker("范围", selection: $scope) {
                        ForEach(HostScope.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                }

                list
            }
            .navigationTitle("选择服务器")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: kind == .ysf ? "按名称搜索，如 HUBNet" : "按 Hostname 搜索，如 4602 / china")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await store.load(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task { await store.loadIfNeeded() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            Section {
                if visible.isEmpty {
                    emptyRow
                } else {
                    ForEach(visible) { host in
                        hostRow(host)
                    }
                    if filtered.count > resultLimit {
                        Text("还有 \(filtered.count - resultLimit) 台没显示，继续输入关键字缩小范围")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(headerText)
            } footer: {
                if let error = store.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.plain)
    }

    private func hostRow(_ host: DMRHost) -> some View {
        Button {
            // 点的是当前这台就什么都不用做，别白白断一次线。
            let changed = settings.hostName != host.name || settings.host != host.hostname
            settings.hostName = host.name
            settings.host = host.hostname
            // 主机表是 Pi-Star 的 Homebrew 列表（62031）；走 ODTP 时端口固定在 54006，
            // 不能把表里的端口照抄进来，否则会连到一个不认 Rewind 的端口上。
            // YSF 反射器（42000 等）不走这套协议，端口直接用表里的。
            if kind == .ysf {
                settings.port = Int(host.port)
            } else {
                settings.port = settings.linkProtocol == .odtp
                    ? settings.linkProtocol.defaultPort
                    : Int(host.port)
            }
            dismiss()
            // 选完立刻生效：首页那边会断开重连（没在线就只是保存）。
            if changed { onServerChange() }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(host.endpoint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(host.tag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if host.name == settings.hostName {
                    checkmark
                }
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
            if store.isLoading {
                Text("正在下载服务器列表…")
            } else if kindList.isEmpty {
                Text("列表还没下载下来，点右上角刷新重试")
            } else if !query.isEmpty && kind == .dmr && scope == .brandMeister {
                Text("BrandMeister 里没有匹配「\(query)」的服务器")
                Text("切到「全部」再看看")
                    .foregroundStyle(.secondary)
            } else {
                Text("没有匹配「\(query)」的服务器")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// 列表只搜本机这份快照（进入选择器时从 `hosts.txt` 读出来），不会因为搜索去联网。
    private var headerText: String {
        var text = "共 \(baseList.count) 台"
        if !store.loadedFrom.isEmpty { text += " · \(store.snapshotDetail)" }
        return text
    }
}
