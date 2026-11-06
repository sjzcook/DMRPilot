//
//  HostPickerField.swift
//  DMRPilot
//
//  设置页「服务器」一栏的主体：搜索框 + 下拉列表。
//  搜索框按 Hostname（顺带匹配表里的名字）过滤，列表来自 DMRHosts.txt，
//  选中一项就把 name / hostname / port 写回 Settings。
//

import SwiftUI
import UIKit

struct HostPickerField: View {
    @ObservedObject var store: DMRHostStore
    @Binding var settings: Settings

    @State private var isExpanded = false
    @State private var query = ""
    @State private var scope: Scope = .brandMeister

    /// 下拉列表一次最多渲染多少条，避免 1200 多条全部进视图。
    private let resultLimit = 30

    enum Scope: String, CaseIterable, Identifiable {
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

    // MARK: - 数据

    private var selectedHost: DMRHost? {
        guard !settings.hostName.isEmpty else { return nil }
        return store.hosts.first { $0.name == settings.hostName }
    }

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
        VStack(alignment: .leading, spacing: 10) {
            searchField
            triggerRow
            if selectedHost == nil { domainField }
            if isExpanded { expandedContent }
        }
        .task { await store.loadIfNeeded() }
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

    // MARK: - 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("按 Hostname 搜索，如 4602 / china", text: $query)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: query) { newValue in
            if !newValue.isEmpty && !isExpanded {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded = true }
            }
        }
    }

    // MARK: - 下拉触发器

    private var triggerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
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

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 展开后的列表

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("范围", selection: $scope) {
                ForEach(Scope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            hostList
            statusRow
        }
    }

    private var hostList: some View {
        VStack(spacing: 0) {
            customRow

            ForEach(visible) { host in
                Divider()
                hostRow(host)
            }

            if filtered.isEmpty {
                Divider()
                emptyRow
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var customRow: some View {
        Button {
            settings.hostName = ""
            if settings.host.isEmpty { settings.host = "api.brandmeister.network" }
            collapse()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("自定义服务器")
                        .font(.footnote.weight(.medium))
                    Text("手动填写域名，下表里没有的私服用这个")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if settings.hostName.isEmpty {
                    checkmark
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hostRow(_ host: DMRHost) -> some View {
        Button {
            settings.hostName = host.name
            settings.host = host.hostname
            settings.port = Int(host.port)
            collapse()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Text(host.endpoint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(host.tag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if host.name == settings.hostName {
                    checkmark
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 14)
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            if store.isLoading {
                Text("正在下载服务器列表…")
            } else if store.hosts.isEmpty {
                Text("列表还没下载下来，点下面的「更新」重试")
            } else if !query.isEmpty && scope == .brandMeister {
                Text("BrandMeister 里没有匹配「\(query)」的服务器")
                Text("切到「全部」再看看，或者用自定义服务器")
                    .foregroundStyle(.secondary)
            } else {
                Text("没有匹配「\(query)」的服务器")
            }
        }
        .font(.caption2)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                    Text("正在下载…")
                } else {
                    Text(statusText)
                }

                Spacer(minLength: 6)

                if !query.isEmpty && filtered.count > resultLimit {
                    Text("仅显示前 \(resultLimit) 条")
                }

                Button {
                    Task { await store.load(force: true) }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(store.isLoading)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let error = store.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusText: String {
        var text = "共 \(baseList.count) 台"
        if !store.loadedFrom.isEmpty { text += " · \(store.loadedFrom)" }
        return text
    }

    // MARK: - 动作

    private func collapse() {
        withAnimation(.easeInOut(duration: 0.18)) { isExpanded = false }
        query = ""
    }
}
