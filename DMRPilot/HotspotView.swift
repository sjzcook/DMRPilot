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
    @EnvironmentObject private var callsigns: CallsignDirectory
    @State private var showLog = false
    @State private var talkgroupDraft = ""
    @FocusState private var talkgroupFocused: Bool

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

                talkgroupSection
                speakerSection
                audioSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("热点")
            .onAppear {
                talkgroupDraft = draftText(for: app.settings.talkgroup)
                // 切回本页时可能正有人在说话：onChange 不会补发，这里补一次。
                if let id = hotspot.currentSpeaker?.src { callsigns.request(id) }
            }
            .onChange(of: app.settings.talkgroup) { newValue in
                talkgroupDraft = draftText(for: newValue)
            }
            // 换人说话时立刻查一次呼号；已知的和刚查过没结果的都会被 CallsignDirectory 跳过，
            // 所以这里不用再判断，每句通话触发一次网络请求是可以接受的。
            .onChange(of: hotspot.currentSpeaker?.src) { newValue in
                guard let id = newValue else { return }
                callsigns.request(id)
            }
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

    // MARK: - 通话组

    private var talkgroupSection: some View {
        Section {
            HStack(spacing: 12) {
                Text("输入号码")

                Spacer(minLength: 8)

                TextField("全部", text: $talkgroupDraft)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($talkgroupFocused)
                    .frame(maxWidth: 110)

                Button("确定") { applyTalkgroup() }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .disabled(!canApplyTalkgroup)
            }

            HStack {
                Text("正在收听")
                Spacer()
                Text(activeGroupText)
                    .monospacedDigit()
                    .foregroundStyle(hotspot.activeTalkgroup > 0 ? Color.accentColor : Color.secondary)
            }

            if draftValue > 16_777_215 {
                Text("号码超出范围：DMR 目的地址是 24 位，最大 16777215")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if hotspot.activeTalkgroup > 0 {
                Button("恢复收听全部通话组") {
                    commit(talkgroup: 0)
                }
                .font(.footnote)
            }

            if hotspot.activeTalkgroup > 0, hotspot.filteredFrames > 0 {
                HStack {
                    Text("已跳过其它通话组")
                    Spacer()
                    Text("\(hotspot.filteredFrames) 帧")
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if hotspot.activeTalkgroup > 0, app.settings.autoRenewTalkgroup {
                HStack {
                    Text("静默自动续订")
                    Spacer()
                    Text("每 \(app.settings.talkgroupRenewMinutes) 分钟")
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("通话组")
        } footer: {
            Text("输入号码后点「确定」，只解码并播放这个通话组的语音；留空再点「确定」= 听全部。单呼只要发给你，照样会响。\n点「确定」会向这个组发一次静音呼叫，BrandMeister 因此把它记为动态订阅，语音才会推下来；静默一段时间后 App 会自动再呼叫一次续上（设置 → 行为 里可调）。")
        }
    }

    private var draftValue: Int {
        Int(talkgroupDraft.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private var canApplyTalkgroup: Bool {
        draftValue <= 16_777_215 && draftValue != app.settings.talkgroup
    }

    private var activeGroupText: String {
        let talkgroup = hotspot.activeTalkgroup
        guard talkgroup > 0 else { return "全部通话组" }
        if let name = app.name(for: talkgroup) { return "\(name) · \(talkgroup)" }
        return "TG \(talkgroup)"
    }

    private func draftText(for talkgroup: Int) -> String {
        talkgroup > 0 ? "\(talkgroup)" : ""
    }

    private func applyTalkgroup() {
        talkgroupFocused = false
        commit(talkgroup: draftValue)
    }

    private func commit(talkgroup: Int) {
        app.setTalkgroup(talkgroup)
        talkgroupDraft = draftText(for: talkgroup)
    }

    // MARK: - 当前讲话人

    private var speakerSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                speakerRow(at: context.date)
            }
        } header: {
            Text("当前讲话人")
        } footer: {
            Text("呼号按 ID 从 RadioID.net 的用户库实时查询，并缓存在本机；查不到就显示数字 ID（该 ID 可能尚未入库，或来自中继台 / 网关）。")
        }
    }

    @ViewBuilder
    private func speakerRow(at now: Date) -> some View {
        if let speaker = hotspot.currentSpeaker {
            let speaking = speaker.isSpeaking(at: now)

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(speaking ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: speaking ? "waveform" : "person.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(speaking ? Color.accentColor : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(speakerLine(for: speaker.src))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    Text(speakerSubtitle(speaker))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 5) {
                    Text(speaking ? "讲话中" : "已结束")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(speaking ? Color.accentColor : Color.secondary)

                    if speaking {
                        LevelMeter(level: Double(hotspot.voiceLevel))
                            .frame(width: 54, height: 8)
                    } else {
                        Text(Fmt.duration(speaker.talkTime))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .animation(.easeInOut(duration: 0.2), value: speaking)
        } else {
            HStack(spacing: 12) {
                Image(systemName: "person.wave.2")
                    .foregroundStyle(.secondary)
                Text(hotspot.state == .online ? "等待通话" : "未连接")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// 有呼号显示呼号，没有就退回数字 ID——宁可显示得糙一点，也不能空着。
    private func speakerLine(for id: Int) -> String {
        callsigns.callsign(for: id) ?? "\(id)"
    }

    private func speakerSubtitle(_ speaker: ActiveSpeaker) -> String {
        var parts: [String] = []

        if speaker.isPrivate {
            parts.append("单呼")
        } else if let name = app.name(for: speaker.dst) {
            parts.append("\(name) · \(speaker.dst)")
        } else {
            parts.append("TG \(speaker.dst)")
        }

        parts.append("TS\(speaker.slot)")

        // 主行已经是呼号时才重复显示 ID；主行本来就是 ID 的话没必要再来一遍。
        if callsigns.callsign(for: speaker.src) != nil {
            parts.append("ID \(speaker.src)")
        }

        return parts.joined(separator: " · ")
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
