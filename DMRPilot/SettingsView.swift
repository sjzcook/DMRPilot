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
            Text("DMR ID 是热点自己的编号。密码在 BrandMeister 自助页 SelfCare → Hotspot Security 设置，不是登录 BrandMeister 网站用的账号密码。\n呼号只在「上报配置包 RPTC」打开时才会用到（写进配置块的前 8 字节），默认关闭时可以不填。")
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

            if app.settings.usesEssid {
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

            Toggle("新版心跳 DMRP", isOn: $app.settings.modernPing)
            Toggle("上报配置包 RPTC（实验性）", isOn: $app.settings.sendConfig)
        } header: {
            Text("服务器")
        } footer: {
            Text("服务器表来自 ds.vu3lvo.com/DMRHosts.txt（Pi-Star 格式），选中后自动填好域名和端口，也可以切到「自定义服务器」手填。\nESSID 后缀按参考实现 DroidStar 的规则换算：登录 ID = DMR ID × 100 + (后缀 − 1)，所以后缀 1 → …00、后缀 2 → …01。上面那行「登录热点 ID」就是要发给服务器的 9 位号码，请和 SelfCare → My Hotspots 里显示的数字逐位对照，不一致就调后缀。留 0 表示直接用 7 位 DMR ID 登录（BrandMeister 不认，会收不到任何语音）。\nBrandMeister 热点标准走 UDP 62031 + 传统心跳 RPTPING。\n「上报配置包 RPTC」默认关闭：参考实现 DroidStar 的握手只有 RPTL → RPTK → 两个 RPTACK，拿到第二个就进入收发状态，全程没有 RPTC。BrandMeister 对格式不合的 302 字节配置包会直接回 MSTCL 关掉会话（现象：连上的一瞬间被踢下线），所以这里默认不发；只有自建 HBLink 或需要在后台登记设备资料时才打开。\n新版心跳 DMRP 对应 MMDVMHost 2024 之后的 55 字节帧，只有服务器明确要求时才打开。\nWebSocket 走 wss，仅部分自建 HBLink 或网关支持。")
        }
    }

    // MARK: - 行为

    private var behaviourSection: some View {
        Section {
            Toggle("断线自动重连", isOn: $app.settings.autoReconnect)

            Toggle("连接后自动呼叫通话组", isOn: $app.settings.autoCallOnConnect)

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
        } header: {
            Text("行为")
        } footer: {
            Text("Homebrew 没有「订阅」指令：连上后先在通话组上发一次静音呼叫，BrandMeister 才会把这个组标成动态订阅，它的语音也才会推下来。\n呼叫时隙要和该组在 SelfCare 里挂的时隙一致——中国区多数 TG 在 TS2。热点页点「确定」切换组时也会自动呼叫一次。\nBrandMeister 的动态订阅静默约 10 分钟会被释放，打开「静默后自动续订」后，App 会在该组连续没有语音时自动再呼叫一次（间隔取上面的值，建议 8 分钟，留出余量）。")
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
                Text("数据来源")
                Spacer()
                Text("api.brandmeister.network/v2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("语音由内置的纯 Swift AMBE+2 半速率解码器还原（移植自 DroidStar 的 halfrate，GPL-3.0），不依赖任何 C/C++ 代码。语音开关与音量在「热点」页。")
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
}
