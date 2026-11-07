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

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                serverSection
                behaviourSection
                audioSection
                actionSection
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
            HostPickerField(store: app.hostStore, settings: $app.settings)

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

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            Button {
                app.connect()
            } label: {
                Label("保存并连接", systemImage: "bolt.horizontal")
            }
            .disabled(!app.settings.isIdentityReady)

            if hotspot.state != .offline {
                Button("断开连接", role: .destructive) {
                    app.disconnect()
                }
            }
        } footer: {
            if !app.settings.isIdentityReady {
                Text("填写 DMR ID 与 BM密码之后才能连接。")
            } else {
                Text("当前状态：\(hotspot.state.label)")
            }
        }
    }

    // MARK: - 数据

    /// 服务器表 + 本地 DMR ID 库。两者都存在本机，首页查呼号完全不联网。
    private var dataSection: some View {
        Section {
            Button {
                Task { await app.refreshAllData() }
            } label: {
                HStack(spacing: 10) {
                    Label("更新数据", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if app.isRefreshingData {
                        ProgressView()
                    }
                }
            }
            .disabled(app.isRefreshingData)

            if app.isRefreshingData {
                if let progress = callsigns.databaseProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
                Text(updateStageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            row("DMR ID 库", databaseCountText, detail: databaseSizeText)
            row("服务器表", "\(app.hostStore.hosts.count) 台", detail: app.hostStore.loadedFrom)
            row("最近更新", updateTimeText)

            // 原来的「目录」tab 让给了日志页，设备查询和通话组表从这里进。
            NavigationLink {
                DirectoryView()
            } label: {
                Label("设备 / 通话组查询", systemImage: "book.closed")
            }

            if let error = app.refreshError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !callsigns.hasDatabase {
                Text("还没下载 DMR ID 库。首页只能逐条联网查呼号，慢而且经常查不到。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("数据")
        } footer: {
            Text("**服务器信息**：ds.vu3lvo.com 的 DMRHosts.txt（Pi-Star 格式），上面「服务器」里的下拉列表就是它，约 1500 台。\n**DMR ID 库**：RadioID.net 的整包用户表 user.csv（约 17 MB / 31 万条），下载后在本机建索引（2.5 MB），之后首页的呼号、姓名、城市全部从本地查，不再逐条联网，换人说话也不会卡。库里查不到的 ID（中继台、网关、刚申请还没入库的）才会再走一次网络。\n建议一两周点一次；下载中旧库仍然可用，换到新库是一次性的原子替换，中途失败不会把已有的库弄坏。")
        }
    }

    /// 两列信息的统一排版：标题 + 主值（+ 次要说明）。
    private func row(_ title: String, _ value: String, detail: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
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
        }
    }

    private var updateStageText: String {
        let stage = callsigns.databaseStage
        return stage.isEmpty ? "正在更新服务器列表…" : stage
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

    private var updateTimeText: String {
        if let date = callsigns.databaseUpdatedAt { return Self.stamp.string(from: date) }
        if let date = app.dataRefreshedAt { return Self.stamp.string(from: date) }
        return "—"
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text("1.0 (1)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("协议")
                Spacer()
                Text("ODTP (54006)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("协议核心")
                Spacer()
                Text("C++ 桥接")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("数据来源")
                Spacer()
                Text("RadioID.net · api.brandmeister.network")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
