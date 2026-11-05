//
//  HomebrewClient.swift
//  DMRPilot
//
//  以 MMDVM / Homebrew 热点身份连上 BrandMeister：
//  登录（RPTL）→ 鉴权（RPTK）→ 上报配置（RPTC）→ 心跳（RPTPING / DMRP），
//  然后持续接收 DMRD 语音数据帧，把信令聚合成本地“通话列表”，
//  同时把 33 字节语音载荷送进纯 Swift 的 AMBE+2 解码器播放出来。
//

import Foundation
import Network

@MainActor
final class HomebrewClient: ObservableObject {

    // MARK: - 连接状态

    enum ConnectionState: Equatable {
        case offline
        case connecting
        case loggingIn
        case authenticating
        case configuring
        case online
        case failed(String)

        var label: String {
            switch self {
            case .offline: return "未连接"
            case .connecting: return "正在连接…"
            case .loggingIn: return "发送登录请求…"
            case .authenticating: return "鉴权中…"
            case .configuring: return "上报热点配置…"
            case .online: return "已在线"
            case .failed: return "连接失败"
            }
        }

        var isBusy: Bool {
            switch self {
            case .connecting, .loggingIn, .authenticating, .configuring:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - 对外状态

    @Published private(set) var state: ConnectionState = .offline
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var calls: [LiveCall] = []
    @Published private(set) var rxFrames = 0
    @Published private(set) var txFrames = 0
    @Published private(set) var connectedSince: Date?
    @Published private(set) var lastHeard: Date?
    @Published private(set) var lastProblem: String?
    @Published var isLoggingEnabled = true

    // 语音解码状态（驱动 UI 的电平条与统计）
    @Published private(set) var isVoicePlaying = false
    @Published private(set) var voiceLevel: Float = 0
    @Published private(set) var voiceErrorCount = 0
    @Published private(set) var voicePackets = 0

    var activeCalls: [LiveCall] { calls.filter { $0.isActive } }
    var recentCalls: [LiveCall] { calls.filter { !$0.isActive } }

    // MARK: - 内部状态

    private var activeSettings = Settings()
    private var connection: NWConnection?
    private var webSocket: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?
    private var keepAliveTimer: Timer?
    private var loginTimer: DispatchWorkItem?
    private var loginToken = 0
    private var loginAttempt = 0
    private var retryWork: DispatchWorkItem?
    private var lastServerPacket: Date?

    /// AMBE+2 解码 + 播放
    private let voice = VoicePipeline()

    private let pingInterval: TimeInterval = 5
    private let silenceTimeout: TimeInterval = 15

    init() {
        voice.volume = Float(activeSettings.audioVolume)
    }

    // MARK: - 语音偏好

    /// 用户在界面上改了开关/音量时调用，需要立刻生效而不必重连
    func applyAudioPreference(_ settings: Settings) {
        activeSettings.audioEnabled = settings.audioEnabled
        activeSettings.audioVolume = settings.audioVolume
        voice.volume = Float(settings.audioVolume)
        voice.isMuted = !settings.audioEnabled
        if !settings.audioEnabled {
            voiceLevel = 0
            isVoicePlaying = false
        }
    }

    /// 每个语音包都会调用，所以只在值真的变了才写 @Published——
    /// 否则 25 包/秒 × 4 个属性 = 每秒 100 次 objectWillChange，白白刷新整个界面。
    private func syncVoiceUI() {
        if isVoicePlaying != voice.isPlaying { isVoicePlaying = voice.isPlaying }
        if voiceLevel != voice.level { voiceLevel = voice.level }
        if voiceErrorCount != voice.lastErrorCount { voiceErrorCount = voice.lastErrorCount }
        if voicePackets != voice.decodedPackets { voicePackets = voice.decodedPackets }
    }

    // MARK: - 连接 / 断开

    func connect(with settings: Settings) {
        teardown()
        activeSettings = settings
        loginAttempt = 0
        rxFrames = 0
        txFrames = 0
        lastProblem = nil

        voice.reset()
        voice.volume = Float(settings.audioVolume)
        voice.isMuted = !settings.audioEnabled
        syncVoiceUI()

        guard settings.dmrId > 0, !settings.password.isEmpty else {
            state = .failed("请先在设置里填写 DMR ID 与 Hotspot 密码")
            append(.error, "身份信息不完整：DMR ID 与 Hotspot 密码不能为空")
            return
        }

        state = .connecting
        append(.info, "开始连接 \(settings.host):\(settings.port)（\(settings.transport.short)）")

        switch settings.transport {
        case .udp:
            startUDP()
        case .websocket:
            startWebSocket()
        }
    }

    func disconnect() {
        let wasActive = (state != .offline)
        teardown()
        state = .offline
        if wasActive { append(.info, "已断开连接") }
    }

    func clearLog() {
        entries.removeAll()
    }

    // MARK: - UDP 传输

    private func startUDP() {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: activeSettings.port)) else {
            fail("端口无效：\(activeSettings.port)")
            return
        }

        let newConnection = NWConnection(host: NWEndpoint.Host(activeSettings.host), port: port, using: parameters)
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.handleUDPState(newState) }
        }
        newConnection.start(queue: .main)
        receiveUDP()
    }

    private func receiveUDP() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.handleInbound(data)
                }
                if let error {
                    self.fail("接收失败：\(error.localizedDescription)")
                    return
                }
                self.receiveUDP()
            }
        }
    }

    private func handleUDPState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            append(.info, "UDP 通道就绪")
            sendLogin()
        case .waiting(let error):
            append(.warning, "等待网络：\(error.localizedDescription)")
        case .failed(let error):
            fail("连接失败：\(error.localizedDescription)")
        case .cancelled:
            break
        default:
            break
        }
    }

    // MARK: - WebSocket 传输

    private func startWebSocket() {
        let path = activeSettings.wsPath.hasPrefix("/") ? activeSettings.wsPath : "/" + activeSettings.wsPath
        let urlString = "wss://\(activeSettings.host):\(activeSettings.port)\(path)"
        guard let url = URL(string: urlString) else {
            fail("WebSocket 地址无效：\(urlString)")
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        webSocketSession = session

        let task = session.webSocketTask(with: url)
        webSocket = task
        task.resume()

        append(.info, "WebSocket 连接 \(urlString)")
        receiveWebSocket()

        // URLSessionWebSocketTask 没有 ready 回调，等握手完成再发登录帧
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .connecting else { return }
                self.sendLogin()
            }
        }
    }

    private func receiveWebSocket() {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.fail("WebSocket 断开：\(error.localizedDescription)")
                case .success(let message):
                    switch message {
                    case .data(let data):
                        self.handleInbound(data)
                    case .string(let text):
                        self.append(.warning, "收到文本帧：\(text)")
                    @unknown default:
                        break
                    }
                    self.receiveWebSocket()
                }
            }
        }
    }

    // MARK: - 登录状态机

    private func sendLogin() {
        loginAttempt += 1
        guard loginAttempt <= 3 else {
            fail("服务器连续 3 次未响应登录请求")
            return
        }

        state = .loggingIn
        append(.info, "→ RPTL 登录请求（第 \(loginAttempt) 次）")
        send(HB.login(id: activeSettings.dmrId), label: "RPTL")
        armLoginTimeout()
    }

    private func armLoginTimeout() {
        loginToken += 1
        let token = loginToken
        loginTimer?.cancel()

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.loginToken == token else { return }
                self.loginTimedOut()
            }
        }
        loginTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func loginTimedOut() {
        switch state {
        case .configuring:
            // 部分 master 不回第三个 RPTACK，只要还在收包就认为链路已通
            if let lastServerPacket, Date().timeIntervalSince(lastServerPacket) < silenceTimeout {
                goOnline()
            } else {
                fail("配置阶段超时，服务器无响应")
            }
        case .loggingIn, .authenticating:
            if loginAttempt < 3 {
                append(.warning, "登录超时，重试")
                sendLogin()
            } else {
                fail("登录超时：检查服务器地址、端口与网络")
            }
        default:
            break
        }
    }

    private func goOnline() {
        loginTimer?.cancel()
        loginTimer = nil
        guard state != .online else { return }

        state = .online
        connectedSince = Date()
        loginAttempt = 0
        append(.info, "✅ 已登录，进入在线状态，每 \(Int(pingInterval)) 秒心跳")
        startKeepAlive()
    }

    // MARK: - 心跳

    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        keepAliveTimer = timer
    }

    private func tick() {
        guard state == .online else { return }

        if let lastServerPacket, Date().timeIntervalSince(lastServerPacket) > silenceTimeout {
            fail("心跳超时：\(Int(silenceTimeout)) 秒未收到服务器数据")
            return
        }

        send(HB.ping(id: activeSettings.dmrId, modern: activeSettings.modernPing),
             label: activeSettings.modernPing ? "DMRP" : "RPTPING")
    }

    // MARK: - 入站分发

    private func handleInbound(_ data: Data) {
        lastServerPacket = Date()
        let bytes = [UInt8](data)

        guard let tag = HB.tag(bytes) else {
            append(.rx, "无法识别 \(bytes.count) 字节数据包", hex: data.hexDump)
            return
        }

        switch tag {
        case "RPTA": // RPTACK
            loginTimer?.cancel()
            loginTimer = nil
            switch state {
            case .loggingIn:
                state = .authenticating
                append(.info, "← RPTACK 登录通过，→ RPTK 鉴权")
                send(HB.auth(id: activeSettings.dmrId, password: activeSettings.password), label: "RPTK")
                armLoginTimeout()
            case .authenticating:
                state = .configuring
                append(.info, "← RPTACK 鉴权通过，→ RPTC 上报配置")
                send(HB.config(id: activeSettings.dmrId, callsign: activeSettings.callsign), label: "RPTC")
                armLoginTimeout()
            case .configuring:
                goOnline()
            default:
                append(.rx, "← RPTACK")
            }

        case "MSTN": // MSTNAK
            fail("服务器拒绝登录（MSTNAK）：DMR ID 与 Hotspot 密码不匹配，或该 ID 已被占用", allowRetry: false)

        case "MSTC": // MSTCL
            fail("服务器主动断开连接（MSTCL）")

        case "MSTP", "DMRP":
            append(.rx, "← 心跳应答")

        case "DMRD":
            handleDmrFrame(bytes)

        default:
            append(.rx, "← 未知命令 \(tag)（\(bytes.count) 字节）", hex: data.hexDump)
        }
    }

    // MARK: - DMRD → 通话聚合

    private func handleDmrFrame(_ bytes: [UInt8]) {
        guard let frame = HB.parseDmr(bytes) else {
            append(.warning, "DMRD 帧长度不足（\(bytes.count) 字节）")
            return
        }

        rxFrames += 1
        lastHeard = Date()
        if case .configuring = state { goOnline() }

        let key = "\(frame.src)-\(frame.dst)-\(frame.slot)"
        let now = Date()

        if frame.isVoiceHeader {
            closeCall(key: key, at: now)
            calls.insert(makeCall(frame: frame, key: key, at: now), at: 0)
            trimCalls()
            voice.begin(key: key)
            syncVoiceUI()
            append(.rx, "通话开始 \(frame.src) → \(frame.dst)　\(frame.isPrivate ? "单呼" : "组呼")　TS\(frame.slot)")
            return
        }

        if frame.isVoiceTerminator {
            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                calls[index].updatedAt = now
                calls[index].isActive = false
                append(.rx, "通话结束 \(frame.src) → \(frame.dst)（\(Fmt.duration(calls[index].duration))，\(calls[index].frames) 帧）")
            }
            voice.end(key: key)
            syncVoiceUI()
            return
        }

        // 语音突发：33 字节 AMBE+2 载荷 → 3 帧 → 480 采样
        if !frame.isDataSync {
            voice.push(key: key, payload: frame.payload)
            syncVoiceUI()
        }

        if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
            calls[index].frames += 1
            calls[index].updatedAt = now
        } else {
            calls.insert(makeCall(frame: frame, key: key, at: now), at: 0)
            trimCalls()
        }
    }

    private func makeCall(frame: HB.DmrFrame, key: String, at date: Date) -> LiveCall {
        LiveCall(
            id: key,
            src: frame.src,
            dst: frame.dst,
            slot: frame.slot,
            isPrivate: frame.isPrivate,
            frames: 1,
            startedAt: date,
            updatedAt: date,
            isActive: true
        )
    }

    private func closeCall(key: String, at date: Date) {
        guard let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) else { return }
        calls[index].updatedAt = date
        calls[index].isActive = false
    }

    private func trimCalls() {
        if calls.count > 40 {
            calls.removeLast(calls.count - 40)
        }
    }

    // MARK: - 发送

    private func send(_ data: Data, label: String) {
        guard state != .offline else { return }

        txFrames += 1
        append(.tx, "→ \(label)", hex: data.hexDump)

        switch activeSettings.transport {
        case .udp:
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.fail("发送失败：\(error.localizedDescription)") }
            })
        case .websocket:
            webSocket?.send(.data(data)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.fail("发送失败：\(error.localizedDescription)") }
            }
        }
    }

    // MARK: - 收尾 / 重连

    private func fail(_ message: String, allowRetry: Bool = true) {
        append(.error, message)
        lastProblem = message
        teardown()
        state = .failed(message)

        guard allowRetry, activeSettings.autoReconnect else { return }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, case .failed = self.state else { return }
                self.append(.info, "自动重连…")
                self.connect(with: self.activeSettings)
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func teardown() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        loginTimer?.cancel()
        loginTimer = nil
        loginToken += 1
        retryWork?.cancel()
        retryWork = nil

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        webSocketSession?.invalidateAndCancel()
        webSocketSession = nil

        voice.reset()
        syncVoiceUI()

        connectedSince = nil
        lastServerPacket = nil
        loginAttempt = 0
    }

    // MARK: - 日志

    private func append(_ kind: LogEntry.Kind, _ text: String, hex: String? = nil) {
        guard isLoggingEnabled else { return }
        var list = entries
        list.insert(LogEntry(kind: kind, text: text, hex: hex), at: 0)
        if list.count > 400 {
            list.removeLast(list.count - 400)
        }
        entries = list
    }
}
