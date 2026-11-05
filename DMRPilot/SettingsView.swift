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
                TextField("可选", text: $app.settings.callsign)
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
            Text("DMR ID 是热点自己的编号。密码在 BrandMeister 自助页 SelfCare → Hotspot Security 设置，不是登录 BrandMeister 网站用的账号密码。")
        }
    }

    // MARK: - 服务器

    private var serverSection: some View {
        Section {
            HStack {
                Text("服务器")
                Spacer()
                TextField("api.brandmeister.network", text: $app.settings.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("端口")
                Spacer()
                TextField("62031", text: portBinding)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
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
        } header: {
            Text("服务器")
        } footer: {
            Text("BrandMeister 热点标准走 UDP 62031 + 传统心跳 RPTPING。\n新版心跳 DMRP 对应 MMDVMHost 2024 之后的 55 字节帧，只有服务器明确要求时才打开。\nWebSocket 走 wss，仅部分自建 HBLink 或网关支持。")
        }
    }

    // MARK: - 行为

    private var behaviourSection: some View {
        Section {
            Toggle("断线自动重连", isOn: $app.settings.autoReconnect)
        } header: {
            Text("行为")
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
            Text("语音部分不解码：DMR 使用 AMBE+2 编码，解码器受专利限制。本 App 只实现登录、心跳与信令可视化。")
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
}
