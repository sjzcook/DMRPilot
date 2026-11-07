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
                TextField(app.settings.linkProtocol == .odtp ? "7 位 DMR ID" : "7 位，后缀在下面填",
                          text: idBinding)
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
                Text(app.settings.linkProtocol == .odtp ? "终端密码" : "Hotspot 密码")
                Spacer()
                SecureField("必填", text: $app.settings.password)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("身份")
        } footer: {
            Text(identityFooter)
        }
    }

    /// 身份说明随协议变：ODTP 和 Homebrew 的 ID 位数、密码来源、失败表现都不一样。
    private var identityFooter: String {
        switch app.settings.linkProtocol {
        case .odtp:
            return "ODTP 登录用的是 7 位 DMR ID（不带热点后缀）+ SelfCare 里给这台终端设的密码。规范原文：RewindVersionData 里的 Remote ID 就是密码对应的那个 DMR ID，不能带热点常用的两位后缀。\n密码不是登录 BrandMeister 网站用的账号密码。注意鉴权失败时服务器不回任何包，客户端只能超时，所以连不上先怀疑密码。\n呼号在 ODTP 下不参与握手，可以不填。"
        case .homebrew:
            return "Homebrew 用的是 9 位热点 ID：7 位 DMR ID 后面追加两位别名（4601234 + 01 → 460123401）。这里填 7 位，后缀在下面「服务器」里填，App 会自己算。\n密码在 SelfCare → Hotspot Security 设置，不是登录 BrandMeister 网站用的账号密码。\n呼号只在「上报配置包 RPTC」打开时才会用到（写进配置块的前 8 字节）。这个开关默认打开，所以建议照实填写；关掉之后可以不填。"
        }
    }

    // MARK: - 服务器

    private var serverSection: some View {
        Section {
            HostPickerField(store: app.hostStore, settings: $app.settings)

            Picker("协议", selection: linkProtocolBinding) {
                ForEach(LinkProtocol.allCases) { item in
                    Text(item.title).tag(item)
                }
            }

            HStack {
                Text("端口")
                Spacer()
                TextField("\(app.settings.linkProtocol.defaultPort)", text: portBinding)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }

            // 这些只在 Homebrew 下有含义：ODTP 没有热点后缀、没有时隙/色码，
            // 也不发 RPTC，而且只走 UDP。
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
        } footer: {
            Text("**ODTP（BrandMeister）**：BrandMeister 现在的手机客户端走的就是这条，UDP 54006。登录用 **7 位 DMR ID**（不带热点后缀）+ SelfCare 密码，登录后发一条显式订阅命令，服务器确认即开始推语音。没有时隙、色码、ESSID 这些概念。\n**Homebrew（MMDVM / HBlink）**：UDP 62031，TGIF / FreeDMR / 自建网关走这条。登录 ID 是 **9 位热点 ID**（7 位 DMR ID 后面追加两位别名，DMR ID 4601234 + 后缀 01 → 460123401），请和 SelfCare → My Hotspots 里那串数字逐位对照；不想算就把 9 位号码直接填进「自定义热点 ID」。这个协议**没有订阅指令**，靠连上后发一次静音发射让服务器记住这个组。\n服务器表来自 ds.vu3lvo.com/DMRHosts.txt（Pi-Star 格式，端口一般是 62031）；BrandMeister 的 ODTP 地址形如 4602.master.brandmeister.network:54006，需要手填。\nWebSocket 走 wss，仅部分自建 HBLink 或网关支持。")
        }
    }

    // MARK: - 行为

    private var behaviourSection: some View {
        Section {
            Toggle("断线自动重连", isOn: $app.settings.autoReconnect)

            Toggle(app.settings.linkProtocol == .odtp ? "连接后自动订阅通话组" : "连接后自动呼叫通话组",
                   isOn: $app.settings.autoCallOnConnect)

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
        } footer: {
            Text(behaviourFooter)
        }
    }

    private var behaviourFooter: String {
        let follow = "「跟随服务器下发的通话组」是参考实现 DroidStar 的接收策略：收到帧就直接解，从不按目的地址过滤。服务器推的是这个账号被订阅的组，可能包含 SelfCare 里的静态组——它跟你在上面选的不一样时，按 TG 硬丢帧就会表现成「订阅没建立」，其实语音一直在下来。关掉这个开关才会严格只听选中的那一个组。"
        switch app.settings.linkProtocol {
        case .odtp:
            return "ODTP 的订阅是一条显式命令：鉴权通过后立刻发 SUBSCRIPTION(组呼, TG)，服务器回一个空确认包才开始推语音。点「确定」换组会再订一次。订阅不会自己过期，只要 KEEP_ALIVE 还通就一直有效。\n" + follow
        case .homebrew:
            return "Homebrew 没有「订阅」指令：连上后在通话组上发一次完整 PTT（语音头 + 12 个突发 + 结束符，带嵌入 LC），BrandMeister 才会把这个组标成动态订阅，它的语音也才会推下来。热点页点「确定」切换组时也会自动来一次。\n" + follow + "\n订阅时隙要和该组在 SelfCare 里挂的时隙一致——中国区多数 TG 在 TS2。\nBrandMeister 的动态订阅静默约 10 分钟会被释放，打开「静默后自动续订」后，App 会在该组连续没有语音时自动再发一次（间隔取上面的值，建议 8 分钟，留出余量）。\n色码只写进我们发出去的语音帧（slot type 与嵌入信令 DMREMB）和上报配置包里的资料字段，连接与接收都不需要它：Homebrew 握手没有任何色码校验，收帧也不按色码过滤。"
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
                Text("ODTP (54006) / Homebrew (62031)")
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
                Text("api.brandmeister.network/v2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("两条链路的握手、组帧与拆帧都在内置的 C++ 核心里：Core/RewindCore.cpp 走 ODTP（移植自 BrandMeister DigestPlay 的 RewindClient，GPL-3.0），Core/DMRCore.cpp 走 Homebrew（移植自 DroidStar 的 dmr.cpp，GPL-3.0）。Swift 只负责网络收发、定时器与界面；语音由纯 Swift 的 AMBE+2 半速率解码器还原（移植自 DroidStar 的 halfrate，GPL-3.0）。语音开关与音量在「热点」页。")
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
            set: { app.settings.port = Int($0.filter(\.isNumber)) ?? app.settings.linkProtocol.defaultPort }
        )
    }

    /// 切换协议时同步端口：只有当前端口还是「旧协议的默认值」才跟着换，
    /// 用户自己改过的端口不动。
    private var linkProtocolBinding: Binding<LinkProtocol> {
        Binding(
            get: { app.settings.linkProtocol },
            set: { newValue in
                let old = app.settings.linkProtocol
                app.settings.linkProtocol = newValue
                if app.settings.port == old.defaultPort {
                    app.settings.port = newValue.defaultPort
                }
            }
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
