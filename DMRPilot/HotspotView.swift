//
//  HotspotView.swift
//  DMRPilot
//
//  热点主界面：连接状态、实时通话（由 DMRD 信令聚合）、协议日志入口。
//

import SwiftUI
import UIKit

struct HotspotView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var hotspot: HomebrewClient
    @EnvironmentObject private var callsigns: CallsignDirectory
    @State private var showLog = false
    @State private var talkgroupDraft = ""
    @State private var pttPressed = false
    @State private var pttDenied = false
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

                pttSection
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
                Metric(title: (app.settings.usesEssid || app.settings.hotspotIdOverride > 0) ? "热点 ID" : "DMR ID",
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

    // MARK: - PTT（按住说话）

    /// 通话组上方的圆形 PTT：按住开始发射，松手停止。
    ///
    /// 交互用 `DragGesture(minimumDistance: 0)` 而不是 `Button`：Button 只有抬起时才有
    /// 回调，拿不到「按住期间」的状态，也就没法做「按住发射 / 松手停止」。
    private var pttSection: some View {
        Section {
            VStack(spacing: 10) {
                pttButton

                Text(pttStatusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(hotspot.isTransmitting ? Color.red : Color.secondary)
                    .animation(.none, value: hotspot.txSeconds)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    private var pttButton: some View {
        let active = hotspot.isTransmitting
        let level = CGFloat(max(0, min(1, hotspot.txLevel)))

        return ZStack {
            // 外圈随输入电平扩散：说话大声一点，环就大一点
            Circle()
                .stroke(Color.red.opacity(active ? 0.30 : 0.10), lineWidth: 5)
                .frame(width: 146 + level * 26, height: 146 + level * 26)
                .animation(.easeOut(duration: 0.12), value: level)

            Circle()
                .fill(LinearGradient(colors: active
                                     ? [Color(red: 0.94, green: 0.30, blue: 0.26),
                                        Color(red: 0.70, green: 0.09, blue: 0.07)]
                                     : [Color(red: 0.44, green: 0.47, blue: 0.54),
                                        Color(red: 0.27, green: 0.29, blue: 0.35)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 124, height: 124)
                .overlay(
                    Circle().stroke(Color.white.opacity(active ? 0.22 : 0.10), lineWidth: 1)
                )
                .shadow(color: active ? Color.red.opacity(0.45) : Color.black.opacity(0.16),
                        radius: active ? 16 : 6, x: 0, y: 4)

            Text("PTT")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .kerning(1.5)
                .foregroundStyle(.white)
        }
        .frame(width: 178, height: 178)
        .scaleEffect(pttPressed ? 0.94 : 1)
        .opacity(canTransmit ? 1 : 0.45)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.12), value: pttPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressPtt() }
                .onEnded { _ in releasePtt() }
        )
        .accessibilityLabel("按住发射")
        .accessibilityHint("按住时使用麦克风向当前通话组发射，松手停止")
    }

    private var canTransmit: Bool {
        hotspot.state == .online && app.settings.talkgroup > 0
    }

    private var pttStatusText: String {
        if hotspot.isTransmitting {
            return String(format: "正在发射 %.1f 秒", hotspot.txSeconds)
                + " · TG \(app.settings.talkgroup)"
        }
        if pttDenied {
            return "麦克风没授权：设置 → DMRPilot → 麦克风"
        }
        if hotspot.state != .online {
            return "连上服务器后才能发射"
        }
        if app.settings.talkgroup <= 0 {
            return "先在下面的「通话组」里填一个号码"
        }
        return "按住说话 · TG \(app.settings.talkgroup)"
    }

    private func pressPtt() {
        guard !pttPressed else { return }
        guard canTransmit else { return }
        pttPressed = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()

        Task { @MainActor in
            let granted = await PttMicrophone.requestPermission()
            guard granted else {
                pttPressed = false
                pttDenied = true
                return
            }
            pttDenied = false
            // 权限弹框期间用户可能已经松手了，这时候不该再开麦
            guard pttPressed else { return }
            hotspot.beginPtt(talkgroup: app.settings.talkgroup)
            if !hotspot.isTransmitting {
                // 开麦失败（没权限 / 没有可用输入）时把按钮状态收回来，
                // 否则会一直显示成按下却不发射。
                pttPressed = false
            }
        }
    }

    private func releasePtt() {
        guard pttPressed || hotspot.isTransmitting else { return }
        pttPressed = false
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        hotspot.endPtt()
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
                Text("订阅目标")
                Spacer()
                Text(activeGroupText)
                    .monospacedDigit()
                    .foregroundStyle(hotspot.activeTalkgroup > 0 ? Color.accentColor : Color.secondary)
            }

            if let pushed = hotspot.serverTalkgroup, pushed != hotspot.activeTalkgroup {
                HStack {
                    Text("服务器实际下发")
                    Spacer()
                    Text("TG \(pushed)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
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
            Text("输入号码后点「确定」订阅这个组；留空再点「确定」= 听全部。单呼只要发给你，照样会响。\n**ODTP（BrandMeister）**：订阅是一条显式的 SUBSCRIPTION 命令，服务器回执后立即生效，不需要发射。\n**Homebrew（MMDVM / HBlink）**：没有订阅指令，实际做法是发一次完整发射——语音头 + 12 个语音突发（两个超帧，带嵌入 LC）+ 结束符，约 0.75 秒，服务器把这台热点记成动态订阅；静默一段时间后 App 会自动再续一次（设置 → 行为 里可调）。\n接收侧照参考实现 DroidStar：服务器推什么就解什么，不按目的地址丢帧。所以「正在收听」和「服务器实际下发」可能不是同一个组 —— 服务器推的往往是这台热点被订阅的全部组，包括 SelfCare 里的静态组。想只听选中的那一个，去设置 → 行为 关掉「跟随服务器下发的通话组」。")
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

        // ODTP 没有时隙概念，标个 TS2 只会误导
        if app.settings.linkProtocol == .homebrew {
            parts.append("TS\(speaker.slot)")
        }

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
            Text("帧的接收与拆解由 C++ 协议核心完成（Core/DMRCore.cpp，移植自 DroidStar 的 dmr.cpp，GPL-3.0）；AMBE+2 半速率解码器直接用的是 DroidStar 的 halfrate 原文件（Core/Vocoder/，GPL-3.0），参数也与它一致。每一路通话单独维护解码器状态，中途接入的通话也能直接出声。\n纠错比特是 Golay(23,12) 每帧纠正的位数，持续大于 12 说明信号质量很差。")
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
