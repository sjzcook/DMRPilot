//
//  HotspotView.swift
//  DMRPilot
//
//  首页：连接状态、PTT、当前讲话人 / 刚刚结束（由 DMRD 信令聚合）、协议日志入口。
//

import SwiftUI
import UIKit

struct HotspotView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var hotspot: HomebrewClient
    @EnvironmentObject private var callsigns: CallsignDirectory
    @State private var showLog = false
    @State private var pttPressed = false
    @State private var pttDenied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusCard
                }

                pttSection

                speakerSection

                if !recentSpeakerItems.isEmpty {
                    Section("刚刚结束") {
                        ForEach(recentSpeakerItems) { item in
                            speakerRow(item, at: Date())
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("首页")
            .onAppear {
                // 切回本页时可能正有人在说话：onChange 不会补发，这里补一次。
                if let id = hotspot.currentSpeaker?.src { callsigns.request(id) }
            }
            // 通话组列表是选择器的数据源，进页面就先拿一次（有缓存时不重复请求）。
            .task { await app.loadTalkgroupsIfNeeded() }
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
            // 这一行的高度单独给个下限：未连接时右边没有 uptime 和静音按钮，
            // 只剩「圆点 + 状态文字」，会明显比在线时矮一截，看着像整块在跳动。
            // 只抬行高，字号保持 .headline 不动。
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

                    // 连接时间右边的静音开关：和设置里「语音播放」是同一个设置，
                    // 只是放在这儿能边说边按。图标跟着状态切换。
                    Button(action: toggleAudio) {
                        Image(systemName: app.settings.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(app.settings.audioEnabled ? Color.accentColor : Color.orange)
                    .accessibilityLabel(app.settings.audioEnabled ? "静音" : "恢复声音")
                }
            }
            .frame(minHeight: 38)

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

            // 只有电平表这一行加高，图标字号不动——整行的高度由电平表决定。
            HStack(spacing: 8) {
                Image(systemName: audioIcon)
                    .font(.caption)
                    .foregroundStyle(hotspot.isVoicePlaying ? Color.accentColor : Color.secondary)

                LevelMeter(level: Double(hotspot.voiceLevel))
                    .frame(width: 80, height: 16)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)

            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption2)
                Text("\(app.settings.host):\(String(app.settings.port))")
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)

            // 连接按钮和通话组选择器并排，各占一半宽度。
            // 选组是「点开列表挑一个」，和设置页选服务器是同一套交互，不再手打号码。
            HStack(alignment: .center, spacing: 10) {
                Button(action: toggleConnection) {
                    Text(buttonTitle)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                TalkgroupPickerField(talkgroups: app.talkgroups,
                                     selected: app.settings.talkgroup,
                                     isLoading: app.isLoadingTalkgroups,
                                     error: app.talkgroupsError,
                                     onSelect: { app.setTalkgroup($0) },
                                     onRefresh: { await app.reloadTalkgroups() })
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 46)
        }
        .padding(.vertical, 6)
    }

    // MARK: - PTT（按住说话）

    /// 状态卡下方的圆形 PTT：按住开始发射，松手停止。
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
            return "先在连接按钮右边选一个通话组"
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

    // MARK: - 当前讲话人

    private var speakerSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let item = currentSpeakerItem {
                    speakerRow(item, at: context.date)
                } else {
                    waitingRow
                }
            }
        } header: {
            Text("当前讲话人")
        }
    }

    /// 「当前讲话人」和「刚刚结束」共用同一套行：呼号、组 / 时隙 / 姓名 / 城市，
    /// 右侧是「讲话中 + 电平」或「已结束 + 时长」。两边长得一样，看起来才是一个列表的延续。
    private func speakerRow(_ item: SpeakerItem, at now: Date) -> some View {
        let speaker = item.speaker
        let speaking = item.isSpeaking(at: now)

        return HStack(spacing: 14) {
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
        // 本地库里没有的 ID 才联网补查一次；已知的会被 CallsignDirectory 直接跳过。
        .onAppear { callsigns.request(speaker.src) }
    }

    private var waitingRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(.secondary)
            Text(hotspot.state == .online ? "等待通话" : "未连接")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - 通话记录合并

    private var currentSpeakerItem: SpeakerItem? {
        hotspot.currentSpeaker.map { SpeakerItem(speaker: $0, isLive: true) }
    }

    /// 「刚刚结束」的列表，两条规则：
    ///
    /// - 同一个 `src→dst→slot` 只保留**最新**一条（核心里的 `calls` 是「新插入在 0」，
    ///   所以第一次遇到的就是最新的）。
    /// - 和当前讲话人重复的那条直接跳过——它已经显示在最上面了，不能出现两份。
    private var recentSpeakerItems: [SpeakerItem] {
        var seen = Set<String>()
        if let current = currentSpeakerItem { seen.insert(current.id) }

        var items: [SpeakerItem] = []
        for call in hotspot.recentCalls {
            let item = SpeakerItem(call: call)
            guard seen.insert(item.id).inserted else { continue }
            items.append(item)
            if items.count >= 8 { break }
        }
        return items
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

        // 本地 DMR ID 库里有姓名和城市就带上，比一串数字 ID 有用得多。
        // 换成呼号显示时，再把 ID 补在后面，方便对号。
        let known = callsigns.callsign(for: speaker.src) != nil
        if let user = callsigns.user(for: speaker.src) {
            if !user.fullName.isEmpty { parts.append(user.fullName) }
            let place = user.placeText
            if !place.isEmpty { parts.append(place) }
        }
        if known { parts.append("ID \(speaker.src)") }

        return parts.joined(separator: " · ")
    }

    // MARK: - 语音（开关在设置页，这里只留状态和快捷开关）

    /// 连接时间右边那个静音按钮：改的是和设置 → 语音 → 「语音播放」同一个开关。
    private func toggleAudio() {
        app.settings.audioEnabled.toggle()
        hotspot.applyAudioPreference(app.settings)
    }

    private var audioIcon: String {
        if !app.settings.audioEnabled { return "speaker.slash" }
        return hotspot.isVoicePlaying ? "waveform" : "speaker.wave.1"
    }

    // MARK: - 辅助

    private var isConnectedOrBusy: Bool {
        hotspot.state == .online || hotspot.state.isBusy
    }

    private var buttonTitle: String {
        isConnectedOrBusy ? "断开连接" : "连接"
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

// MARK: - 一条通话记录

/// 「当前讲话人」和「刚刚结束」共用的一条记录。
///
/// `LiveCall` 和 `ActiveSpeaker` 的字段几乎一样，显示也要求完全一致，
/// 所以先统一成这个结构再交给同一个行视图渲染。
private struct SpeakerItem: Identifiable, Equatable {
    let speaker: ActiveSpeaker
    /// 是不是最上面那行「当前讲话人」（只有它会每秒刷新、显示实时电平）。
    let isLive: Bool
    /// 同一个 `src→dst→slot` 只能出现一次，和核心里的 `LiveCall.id` 是同一个格式。
    let id: String

    init(speaker: ActiveSpeaker, isLive: Bool) {
        self.speaker = speaker
        self.isLive = isLive
        self.id = "\(speaker.src)-\(speaker.dst)-\(speaker.slot)"
    }

    init(call: LiveCall) {
        self.init(speaker: ActiveSpeaker(src: call.src,
                                         dst: call.dst,
                                         slot: call.slot,
                                         isPrivate: call.isPrivate,
                                         startedAt: call.startedAt,
                                         lastVoiceAt: call.updatedAt,
                                         endedAt: call.isActive ? nil : call.updatedAt),
                  isLive: false)
    }

    func isSpeaking(at now: Date) -> Bool {
        isLive && speaker.isSpeaking(at: now)
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
