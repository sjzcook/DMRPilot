//
//  SettingsView.swift
//  DMRPilot
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var hotspot: HomebrewClient
    /// 本地 DMR ID 库的下载进度由它发布，所以这里也要观察，
    /// 只是从 `app.callsigns` 读的话进度条不会动。
    @EnvironmentObject private var callsigns: CallsignDirectory
    /// 服务器表同理：行内「更新」按钮的转圈和下载后的台数都靠它发布。
    @EnvironmentObject private var hostStore: DMRHostStore

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                serverSection
                behaviourSection
                audioSection
                dataSection
                aboutSection
            }
            .navigationTitle("设置")
        }
    }

    // MARK: - 身份

    private var identitySection: some View {
        Section {
            HStack {
                Text("DMR ID")
                Spacer()
                TextField("7 位 DMR ID", text: idBinding)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("呼号")
                Spacer()
                TextField("如 BG7ABC", text: $app.settings.callsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("BM密码")
                Spacer()
                SecureField("必填", text: $app.settings.password)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("身份")
        } footer: {
            Text("BM密码不是 BrandMeister 登录密码，是 SelfCare → Hotspot Security 中设置的密码。")
        }
    }

    // MARK: - 服务器

    private var serverSection: some View {
        Section {
            HostPickerField(store: hostStore, settings: $app.settings) {
                // 换服务器后自动断开重连（没在线时只保存）。
                app.restartForServerChange()
            }

            // 这些只在 Homebrew 下有含义：ODTP 没有热点后缀、没有时隙/色码，
            // 也不发 RPTC，而且只走 UDP。协议现在固定 ODTP，所以这段不会显示，
            // 留着是为了保住 Homebrew 的代码路径。
            if app.settings.linkProtocol == .homebrew {
                HStack {
                    Text("ESSID 后缀")
                    Spacer()
                    TextField("01", text: essidBinding)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56)
                    Stepper("ESSID", value: $app.settings.essid, in: 0...99)
                        .labelsHidden()
                }

                HStack {
                    Text("自定义热点 ID")
                    Spacer()
                    TextField("可空", text: hotspotOverrideBinding)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }

                if app.settings.usesEssid || app.settings.hotspotIdOverride > 0 {
                    HStack {
                        Text("登录热点 ID")
                        Spacer()
                        Text(String(app.settings.hotspotId))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("传输方式", selection: $app.settings.transport) {
                    ForEach(HbTransport.allCases) { transport in
                        Text(transport.title).tag(transport)
                    }
                }

                if app.settings.transport == .websocket {
                    HStack {
                        Text("WS 路径")
                        Spacer()
                        TextField("/ws", text: $app.settings.wsPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                }
                Toggle("上报配置包 RPTC（实验性）", isOn: $app.settings.sendConfig)
            }
        } header: {
            Text("服务器")
        }
    }

    // MARK: - 行为

    private var behaviourSection: some View {
        Section {
            // 外观主题：只是界面配色，改完立刻生效，不涉及连接与音频。
            // 用 menu 样式就是为了「下拉选择」这个交互（点开才展开三项）。
            Picker("应用主题", selection: $app.settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.menu)

            Toggle("断线自动重连", isOn: $app.settings.autoReconnect)

            Toggle("连接后自动订阅通话组", isOn: $app.settings.autoCallOnConnect)

            Toggle("跟随服务器下发的通话组", isOn: $app.settings.followServerTalkgroups)

            // 时隙 / 色码 / 续订都只属于 Homebrew：ODTP 没有时隙与色码，
            // 订阅也不会静默过期（会话靠 KEEP_ALIVE 维持）。
            if app.settings.linkProtocol == .homebrew {
                Toggle("静默后自动续订", isOn: $app.settings.autoRenewTalkgroup)

                if app.settings.autoRenewTalkgroup {
                    Picker("续订间隔", selection: $app.settings.talkgroupRenewMinutes) {
                        Text("5 分钟").tag(5)
                        Text("8 分钟").tag(8)
                        Text("10 分钟").tag(10)
                    }
                }

                Picker("呼叫时隙", selection: $app.settings.callSlot) {
                    Text("TS1").tag(1)
                    Text("TS2").tag(2)
                }

                Picker("色码 CC", selection: $app.settings.colorCode) {
                    ForEach(0...15, id: \.self) { value in
                        Text("CC\(value)").tag(value)
                    }
                }
            }
        } header: {
            Text("行为")
        }
    }

    // MARK: - 语音

    /// 从首页搬过来的整块「语音」。
    ///
    /// 首页只留状态显示和「连接时间」右边那个静音按钮，开关与音量统一放到设置里，
    /// 免得每次想调音量都要翻回首页。
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

            HStack(spacing: 12) {
                Text("麦克风增益")
                Slider(value: micGainBinding, in: Settings.micGainRange, step: 1)
                Text(micGainText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        } header: {
            Text("语音")
        }
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

    /// 麦克风增益：只影响发射。改一下立刻推给采集端，正在发射时也生效。
    private var micGainBinding: Binding<Double> {
        Binding(
            get: { app.settings.micGainDb },
            set: { newValue in
                app.settings.micGainDb = newValue
                hotspot.applyMicGain(app.settings)
            }
        )
    }

    private var micGainText: String {
        let db = Int(app.settings.micGainDb.rounded())
        return db > 0 ? "+\(db) dB" : "\(db) dB"
    }

    // MARK: - 数据

    /// 服务器列表 + 本地 DMR ID 库。两者都存在本机，首页查呼号完全不联网。
    /// 每行末尾各有一个「更新」按钮，只刷新自己那一份数据；更新时间落在标题左下角。
    private var dataSection: some View {
        Section {
            dataRow("DMR ID",
                    databaseCountText,
                    detail: databaseSizeText,
                    updatedAt: callsigns.databaseUpdatedAt,
                    isBusy: callsigns.isUpdatingDatabase) {
                Task { await app.refreshCallsignDatabase() }
            }

            if callsigns.isUpdatingDatabase {
                if let progress = callsigns.databaseProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
                Text(callsigns.databaseStage.isEmpty ? "正在更新 DMR ID 库…" : callsigns.databaseStage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = callsigns.databaseError {
                errorText(error)
            } else if !callsigns.hasDatabase {
                Text("还没下载 DMR ID 库。首页只能逐条联网查呼号，慢而且经常查不到。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            dataRow("服务器列表",
                    hostStore.hasSnapshot ? "\(hostStore.hosts.count) 台" : "未下载",
                    updatedAt: hostStore.savedAt,
                    isBusy: hostStore.isLoading) {
                Task { await app.refreshHostTable() }
            }

            if hostStore.isLoading {
                Text("正在更新服务器列表…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = hostStore.lastError {
                errorText(error)
            }
        } header: {
            Text("数据")
        }
    }

    /// 数据行：标题 + 更新时间（左下角）、主值（+ 次要说明）在右侧，行尾是「更新」按钮。
    /// 按钮用 `.borderless`，点它只触发更新，不会连带整行。
    private func dataRow(_ title: String,
                         _ value: String,
                         detail: String = "",
                         updatedAt: Date?,
                         isBusy: Bool,
                         action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(updateLabel(updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(value == "未下载" ? Color.secondary : Color.primary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Button(action: action) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("更新")
                        .font(.footnote.weight(.semibold))
                }
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
            .accessibilityLabel("更新\(title)")
        }
    }

    /// 左下角那行小字：没有时间就是「未更新」。
    private func updateLabel(_ date: Date?) -> String {
        guard let date else { return "未更新" }
        return "更新于 " + Self.stamp.string(from: date)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var databaseCountText: String {
        let count = callsigns.databaseCount
        guard count > 0 else { return "未下载" }
        return String(format: "%.1f 万条", Double(count) / 10000)
    }

    private var databaseSizeText: String {
        let bytes = callsigns.databaseBytes
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 关于

    /// 关于：只留版本号。协议（ODTP 54006）、协议核心（C++ 桥接）和数据来源
    /// 这几行属于开发期信息，界面上已经去掉，需要时看 README。
    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text("1.0 (1)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        }
    }

    // MARK: - 绑定

    private var idBinding: Binding<String> {
        Binding(
            get: { app.settings.dmrId == 0 ? "" : String(app.settings.dmrId) },
            set: { app.settings.dmrId = Int($0.filter(\.isNumber)) ?? 0 }
        )
    }

    /// 只收数字并限制在 0…99，越界不会把上报 ID 算成垃圾值。
    private var essidBinding: Binding<String> {
        Binding(
            get: { String(app.settings.essid) },
            set: { app.settings.essid = min(99, max(0, Int($0.filter(\.isNumber)) ?? 0)) }
        )
    }

    /// 自定义 9 位热点 ID：留空（0）就按 ESSID 换算。
    private var hotspotOverrideBinding: Binding<String> {
        Binding(
            get: { app.settings.hotspotIdOverride > 0 ? String(app.settings.hotspotIdOverride) : "" },
            set: {
                let digits = String($0.filter(\.isNumber).prefix(9))
                app.settings.hotspotIdOverride = Int(digits) ?? 0
            }
        )
    }
}
