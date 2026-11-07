//
//  HostPickerField.swift
//  DMRPilot
//
//  设置页「服务器」一栏：一行下拉触发器 + 自定义域名输入框。
//  点开后是弹出式选择器（sheet），列表来自 DMRHosts.txt，
//  搜索框固定在列表上方，按 Hostname（顺带匹配表里的名字）过滤。
//  选中一项就把 name / hostname / port 写回 Settings。
//

import SwiftUI

struct HostPickerField: View {
    @ObservedObject var store: DMRHostStore
    @Binding var settings: Settings

    @State private var isPicking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            triggerRow
            if selectedHost == nil { domainField }
        }
        .task { await store.loadIfNeeded() }
        .sheet(isPresented: $isPicking) {
            HostPickerSheet(store: store, settings: $settings)
        }
    }

    // MARK: - 数据

    private var selectedHost: DMRHost? {
        guard !settings.hostName.isEmpty else { return nil }
        return store.hosts.first { $0.name == settings.hostName }
    }

    // MARK: - 下拉触发器

    private var triggerRow: some View {
        Button {
            isPicking = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedHost?.name ?? "自定义服务器")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(settings.host):\(String(settings.port))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let tag = selectedHost?.tag {
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
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
        }
        .padding(.leading, 24)
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
    @Binding var settings: Settings

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var scope: HostScope = .brandMeister

    /// 一次最多渲染多少条，避免 1200 多条全进列表。
    private let resultLimit = 60

    // MARK: - 数据

    private var baseList: [DMRHost] {
        switch scope {
        case .brandMeister: return store.brandMeisterHosts
        case .all: return store.hosts
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
                Picker("范围", selection: $scope) {
                    ForEach(HostScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

                list
            }
            .navigationTitle("选择服务器")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "按 Hostname 搜索，如 4602 / china")
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
                customRow
            } footer: {
                Text("下表里没有的服务器（自建 HBLink、私服）用这一项手填域名。")
            }

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

    private var customRow: some View {
        Button {
            settings.hostName = ""
            if settings.host.isEmpty { settings.host = "api.brandmeister.network" }
            dismiss()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自定义服务器")
                        .font(.subheadline)
                    Text("手动填写域名")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if settings.hostName.isEmpty {
                    checkmark
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hostRow(_ host: DMRHost) -> some View {
        Button {
            settings.hostName = host.name
            settings.host = host.hostname
            // 主机表是 Pi-Star 的 Homebrew 列表（62031）；走 ODTP 时端口固定在 54006，
            // 不能把表里的端口照抄进来，否则会连到一个不认 Rewind 的端口上。
            settings.port = settings.linkProtocol == .odtp ? settings.linkProtocol.defaultPort : Int(host.port)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(host.endpoint)
                        .font(.caption2.monospaced())
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
            } else if store.hosts.isEmpty {
                Text("列表还没下载下来，点右上角刷新重试")
            } else if !query.isEmpty && scope == .brandMeister {
                Text("BrandMeister 里没有匹配「\(query)」的服务器")
                Text("切到「全部」再看看，或者用自定义服务器")
                    .foregroundStyle(.secondary)
            } else {
                Text("没有匹配「\(query)」的服务器")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var headerText: String {
        var text = "共 \(baseList.count) 台"
        if !store.loadedFrom.isEmpty { text += " · \(store.loadedFrom)" }
        return text
    }
}
