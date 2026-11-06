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

                audioSection
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
                Metric(title: app.settings.usesEssid ? "热点 ID" : "DMR ID",
                       value: app.settings.dmrId > 0 ? "\(app.settings.hotspotId)" : "未设置")
                Divider().frame(height: 30)
                Metric(title: "传输", value: app.settings.transport.short)
                Divider().frame(height: 30)
                Metric(title: "收帧", value: "\(hotspot.rxFrames)")
            }

            HStack(spacing: 8) {
                Image(systemName: audioIcon)
                    .font(.caption)
                    .foregroundStyle(hotspot.isVoicePlaying ? Color.accentColor : Color.secondary)

                LevelMeter(level: Double(hotspot.voiceLevel))
                    .frame(width: 80, height: 10)

                Spacer()

                Text(audioStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    // MARK: - 语音设置

    private var audioSection: some View {
        Section {
            Toggle(isOn: audioEnabledBinding) {
                Label("语音播放", systemImage: "speaker.wave.2.fill")
            }

            if app.settings.audioEnabled {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: volumeBinding, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("已解码")
                Spacer()
                Text("\(hotspot.voicePackets) 包")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("纠错比特")
                Spacer()
                Text("\(hotspot.voiceErrorCount)")
                    .monospacedDigit()
                    .foregroundStyle(hotspot.voiceErrorCount > 12 ? Color.orange : Color.secondary)
            }
        } header: {
            Text("语音")
        } footer: {
            Text("AMBE+2 半速率解码器由纯 Swift 实现（移植自 DroidStar 的 halfrate，GPL-3.0），不依赖任何 C/C++ 代码。每一路通话单独维护解码器状态，中途接入的通话也能直接出声。\n纠错比特是 Golay(23,12) 每帧纠正的位数，持续大于 12 说明信号质量很差。")
        }
    }

    private var audioIcon: String {
        if !app.settings.audioEnabled { return "speaker.slash" }
        return hotspot.isVoicePlaying ? "waveform" : "speaker.wave.1"
    }

    private var audioStatusText: String {
        if !app.settings.audioEnabled { return "语音已关闭" }
        if hotspot.isVoicePlaying { return "解码中" }
        return "静默"
    }

    private var audioEnabledBinding: Binding<Bool> {
        Binding(
            get: { app.settings.audioEnabled },
            set: { newValue in
                app.settings.audioEnabled = newValue
                hotspot.applyAudioPreference(app.settings)
            }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { app.settings.audioVolume },
            set: { newValue in
                app.settings.audioVolume = newValue
                hotspot.applyAudioPreference(app.settings)
            }
        )
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

// MARK: - 电平表

/// 8 段电平指示，跟着解码器每个包输出的峰值跳动。
struct LevelMeter: View {
    let level: Double

    private static let segmentCount = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                let threshold = Double(index + 1) / Double(Self.segmentCount)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(level >= threshold ? color(at: index) : Color.secondary.opacity(0.15))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("电平 \(Int(level * 100))%")
    }

    private func color(at index: Int) -> Color {
        if index >= Self.segmentCount - 1 { return .red }
        if index >= Self.segmentCount - 3 { return .orange }
        return .green
    }
}
