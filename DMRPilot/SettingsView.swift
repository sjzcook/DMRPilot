//
//  SettingsView.swift
//  DMRPilot
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var hotspot: HomebrewClient

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                serverSection
                behaviourSection
                actionSection
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
                TextField("热点编号", text: idBinding)
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
                Text("Hotspot 密码")
                Spacer()
                SecureField("必填", text: $app.settings.password)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("身份")
        } footer: {
            Text("DMR ID 是热点自己的编号。密码在 BrandMeister 自助页 SelfCare → Hotspot Security 设置，不是登录 BrandMeister 网站用的账号密码。\n呼号只在「上报配置包 RPTC」打开时才会用到（写进配置块的前 8 字节）。这个开关默认打开，所以建议照实填写；关掉之后可以不填。")
        }
    }

    // MARK: - 服务器

    private var serverSection: some View {
        Section {
            HostPickerField(store: app.hostStore, settings: $app.settings)

            HStack {
                Text("端口")
                Spacer()
                TextField("62031", text: portBinding)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }

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
        } header: {
            Text("服务器")
        } footer: {
            Text("服务器表来自 ds.vu3lvo.com/DMRHosts.txt（Pi-Star 格式），选中后自动填好域名和端口，也可以切到「自定义服务器」手填。\nBrandMeister 的热点是 9 位：7 位 Radio ID 后面追加两位别名，所以登录 ID = DMR ID × 100 + 后缀（DMR ID 4601234 + 后缀 01 → 460123401）。上面那行「登录热点 ID」就是要发给服务器的号码，请和 SelfCare → My Hotspots 里显示的数字逐位对照。不想算就把那串 9 位数字直接填进「自定义热点 ID」，它优先于后缀换算。后缀留 0 表示用 7 位 DMR ID 直接登录（BrandMeister 不认，收不到任何语音）。\nBrandMeister 热点标准走 UDP 62031。\n「上报配置包 RPTC」默认打开，与参考实现 DroidStar 一致：它的握手是三段 RPTL → RPTK → RPTC，收到第三个 RPTACK 才算进入收发状态，那之前下来的 DMRD 一律不处理。只有自建网关 / HBLink 明确不收这个包时才关掉——关掉后就只剩两段，属于非标准流程。\nWebSocket 走 wss，仅部分自建 HBLink 或网关支持。")
        }
    }

    // MARK: - 行为

    private var behaviourSection: some View {
        Section {
            Toggle("断线自动重连", isOn: $app.settings.autoReconnect)

            Toggle("连接后自动呼叫通话组", isOn: $app.settings.autoCallOnConnect)

            Toggle("跟随服务器下发的通话组", isOn: $app.settings.followServerTalkgroups)

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
        } header: {
            Text("行为")
        } footer: {
            Text("Homebrew 没有「订阅」指令：连上后在通话组上发一次完整 PTT（语音头 + 6 个突发 + 结束符，带嵌入 LC），BrandMeister 才会把这个组标成动态订阅，它的语音也才会推下来。热点页点「确定」切换组时也会自动来一次。\n「跟随服务器下发的通话组」对应参考实现 DroidStar 的接收策略：它收到 DMRD 就直接解，从不按目的地址过滤。BrandMeister 推的是这台热点被订阅的组，其中可能包含 SelfCare 里的静态组——如果它跟你在上面选的不一样，按 TG 硬丢帧就会表现成「订阅没建立」，其实语音一直在下来。关掉这个开关才会严格只听选中的那一个组。\n订阅时隙要和该组在 SelfCare 里挂的时隙一致——中国区多数 TG 在 TS2。\nBrandMeister 的动态订阅静默约 10 分钟会被释放，打开「静默后自动续订」后，App 会在该组连续没有语音时自动再发一次（间隔取上面的值，建议 8 分钟，留出余量）。\n色码只写进我们发出去的语音帧（slot type 与嵌入信令 DMREMB）和上报配置包里的资料字段，**连接与接收都不需要它**：Homebrew 握手没有任何色码校验，收帧也不按色码过滤。只有收听方电台固定了 CC 时才需要跟它一致，BrandMeister 上一般是 CC1。")
        }
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
                Text("填写 DMR ID 与 Hotspot 密码之后才能连接。")
            } else {
                Text("当前状态：\(hotspot.state.label)")
            }
        }
    }

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
                Text("Homebrew / MMDVM")
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
                Text("api.brandmeister.network/v2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("握手、组帧、编码与拆帧由内置的 C++ 核心完成（Core/DMRCore.cpp，移植自 DroidStar 的 dmr.cpp，GPL-3.0），Swift 只负责网络收发与界面；语音由纯 Swift 的 AMBE+2 半速率解码器还原（同样移植自 DroidStar 的 halfrate，GPL-3.0）。语音开关与音量在「热点」页。")
        }
    }

    // MARK: - 绑定

    private var idBinding: Binding<String> {
        Binding(
            get: { app.settings.dmrId == 0 ? "" : String(app.settings.dmrId) },
            set: { app.settings.dmrId = Int($0.filter(\.isNumber)) ?? 0 }
        )
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { String(app.settings.port) },
            set: { app.settings.port = Int($0.filter(\.isNumber)) ?? 62031 }
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
