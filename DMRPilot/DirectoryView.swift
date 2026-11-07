//
//  DirectoryView.swift
//  DMRPilot
//
//  BrandMeister v2 REST 查询：设备详情 + 全球通话组名称表。
//

import SwiftUI

struct DirectoryView: View {
    @EnvironmentObject private var app: AppState

    @State private var deviceIDText = ""
    @State private var device: BmDevice?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var groupQuery = ""

    var body: some View {
        // 原来这是独立的「目录」tab，tab 让给日志页之后一度挂在
        // 设置 → 数据 →「设备 / 通话组查询」；设置页的入口已经去掉，
        // 这个文件目前没有任何跳转进来（留着备查，重新挂入口即可复用）。
        // 它自己不要再套 NavigationStack（会和调用方那层叠成双层导航栏）。
        List {
            querySection

            if let device {
                deviceSection(device)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            talkgroupSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设备 / 通话组")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $groupQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索通话组名称或编号")
        .refreshable { await app.reloadTalkgroups() }
        .task { await app.loadTalkgroupsIfNeeded() }
    }

    // MARK: - 查询区

    private var querySection: some View {
        Section {
            HStack {
                TextField("输入 DMR ID，例如 262301", text: $deviceIDText)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if isLoading {
                    ProgressView()
                } else {
                    Button("查询") {
                        Task { await lookup() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(deviceIDText.isEmpty)
                }
            }

            Button {
                deviceIDText = "\(app.settings.dmrId)"
                Task { await lookup() }
            } label: {
                Label("查询我自己的 ID", systemImage: "person.crop.circle")
                    .font(.footnote)
            }
            .disabled(app.settings.dmrId <= 0)
        } header: {
            Text("设备查询")
        } footer: {
            Text("数据来自 api.brandmeister.network/v2/device，可查任何热点、中继台或电台 ID。")
        }
    }

    // MARK: - 设备详情

    private func deviceSection(_ device: BmDevice) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(displayCallsign(device))
                    .font(.title3.weight(.bold))

                HStack(spacing: 8) {
                    Text("\(device.id)")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    if let statusText = device.statusText, !statusText.isEmpty {
                        Text(statusText)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(statusColor(device).opacity(0.15), in: Capsule())
                            .foregroundStyle(statusColor(device))
                    }
                }
            }
            .padding(.vertical, 2)

            row("最后在线", device.lastSeen ?? "—")
            row("城市", nonEmpty(device.city))
            row("硬件", nonEmpty(device.hardware))
            row("固件", nonEmpty(device.firmware))
            row("色码", device.colorcode.map { "CC \($0)" } ?? "—")
            row("RX / TX", "\(nonEmpty(device.rx)) / \(nonEmpty(device.tx))")

            if let coordinate = device.coordinateText {
                row("坐标", coordinate)
            }
        } header: {
            Text("设备信息")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.footnote)
                .multilineTextAlignment(.trailing)
        }
    }

    private func displayCallsign(_ device: BmDevice) -> String {
        if let callsign = device.callsign, !callsign.isEmpty { return callsign }
        return "ID \(device.id)"
    }

    private func nonEmpty(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "—" }
        return text
    }

    private func statusColor(_ device: BmDevice) -> Color {
        switch device.status ?? 0 {
        case 0: return .gray
        case 1: return .orange
        case 2, 3: return .green
        default: return .blue
        }
    }

    // MARK: - 通话组

    private var talkgroupSection: some View {
        Section {
            if app.talkgroups.isEmpty {
                if let error = app.talkgroupsError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在拉取全球通话组…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(visibleTalkgroups) { entry in
                    HStack {
                        Text("\(entry.id)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                        Text(entry.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }

                if isTruncated {
                    Text("只显示前 200 条，用搜索缩小范围")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("通话组")
                Spacer()
                Text(app.talkgroups.isEmpty ? "—" : "\(app.talkgroups.count) 个")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allEntries: [TalkgroupEntry] {
        app.talkgroups
            .map { TalkgroupEntry(id: $0.key, name: $0.value) }
            .sorted { $0.id < $1.id }
    }

    private var visibleTalkgroups: [TalkgroupEntry] {
        let keyword = groupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [TalkgroupEntry]
        if keyword.isEmpty {
            matched = allEntries
        } else {
            matched = allEntries.filter {
                $0.name.localizedCaseInsensitiveContains(keyword) || String($0.id).contains(keyword)
            }
        }
        return Array(matched.prefix(200))
    }

    private var isTruncated: Bool { visibleTalkgroups.count >= 200 }

    // MARK: - 动作

    private func lookup() async {
        guard let id = Int(deviceIDText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "请输入数字形式的 DMR ID"
            device = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            device = try await app.device(id)
        } catch {
            device = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct TalkgroupEntry: Identifiable {
    let id: Int
    let name: String
}
