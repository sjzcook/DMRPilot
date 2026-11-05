//
//  HotspotView.swift
//  DMRPilot
//
//  热点主界面：连接状态、实时通话（由 DMRD 信令聚合）、协议日志入口。
//

import SwiftUI

struct HotspotView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var hotspot: HomebrewClient
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusCard
                }

                if !hotspot.activeCalls.isEmpty {
                    Section("正在通话") {
                        ForEach(hotspot.activeCalls) { call in
                            CallRow(call: call, label: app.label(for: call.dst))
                        }
                    }
                }

                if !hotspot.recentCalls.isEmpty {
                    Section("刚刚结束") {
                        ForEach(hotspot.recentCalls.prefix(8)) { call in
                            CallRow(call: call, label: app.label(for: call.dst))
                        }
                    }
                }

                Section("关于语音") {
                    Text("DMR 空口传的是 AMBE+2 编码帧，解码器受专利保护，App 内不解码音频。这里显示的是真实的登录状态、心跳与通话信令——能听到谁在呼叫哪个时隙，已经证明链路是通的。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("热点")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showLog = true
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .accessibilityLabel("协议日志")
                }
            }
            .sheet(isPresented: $showLog) {
                LogConsoleView()
                    .environmentObject(hotspot)
            }
        }
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(hotspot.state.label)
                    .font(.headline)

                Spacer()

                if hotspot.state == .online {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(uptimeText(at: context.date))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if case .failed(let message) = hotspot.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 0) {
                Metric(title: "DMR ID", value: app.settings.dmrId > 0 ? "\(app.settings.dmrId)" : "未设置")
                Divider().frame(height: 30)
                Metric(title: "传输", value: app.settings.transport.short)
                Divider().frame(height: 30)
                Metric(title: "收帧", value: "\(hotspot.rxFrames)")
            }

            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption2)
                Text("\(app.settings.host):\(String(app.settings.port))")
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)

            Button(action: toggleConnection) {
                Label(buttonTitle, systemImage: buttonIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 辅助

    private var isConnectedOrBusy: Bool {
        hotspot.state == .online || hotspot.state.isBusy
    }

    private var buttonTitle: String {
        isConnectedOrBusy ? "断开连接" : "连接 BrandMeister"
    }

    private var buttonIcon: String {
        isConnectedOrBusy ? "stop.circle" : "bolt.horizontal.circle"
    }

    private var statusColor: Color {
        switch hotspot.state {
        case .online:
            return .green
        case .offline:
            return .gray.opacity(0.5)
        case .failed:
            return .red
        default:
            return .orange
        }
    }

    private func uptimeText(at date: Date) -> String {
        guard let since = hotspot.connectedSince else { return "--:--" }
        return Fmt.duration(date.timeIntervalSince(since))
    }

    private func toggleConnection() {
        if isConnectedOrBusy {
            app.disconnect()
        } else {
            app.connect()
        }
    }
}

// MARK: - 通话行

struct CallRow: View {
    let call: LiveCall
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Text(call.slotText)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(slotColor.opacity(0.14), in: Capsule())
                .foregroundStyle(slotColor)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(call.src)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.subheadline)
                        .lineLimit(1)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text(Fmt.duration(call.duration))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let status = call.isActive ? "通话中" : "已结束"
        return "\(call.callTypeText) · \(call.frames) 帧 · \(status)"
    }

    private var slotColor: Color {
        call.slot == 1 ? .blue : .purple
    }
}

// MARK: - 指标

struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
