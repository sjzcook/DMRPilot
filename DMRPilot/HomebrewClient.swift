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

    /// 当前收听的 TG，0 = 全部。跟着设置走，但允许在热点页当场改。
    @Published private(set) var activeTalkgroup = 0
    /// 因为不属于当前 TG 而被跳过的帧数，用来判断「是没推下来还是被过滤了」。
    @Published private(set) var filteredFrames = 0

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
    /// RPTC 被 MSTNAK 后重登的次数，只给两次机会，避免把真问题拖成「一直重连」。
    private var configRetries = 0
    private var configRetryWork: DispatchWorkItem?
    /// 已经在用 RPTPING 探测「配置被拒」到底是内容问题还是会话已死。
    private var configProbed = false
    /// 在线后被 master 清会话的次数，用来防止两台设备抢同一个 ID 时无限重连。
    private var sessionNaks = 0
    /// RPTL 之后 master 下发的 4 字节挑战盐，RPTK 靠它算 SHA256。
    private var challenge: [UInt8] = []
    /// 标准 SHA256 鉴权被拒后，是否已经用传统明文 RPTK 重试过。
    private var usedLegacyAuth = false

    /// AMBE+2 解码 + 播放
    private let voice = VoicePipeline()

    private let pingInterval: TimeInterval = 5
    private let silenceTimeout: TimeInterval = 15

    init() {
        voice.volume = Float(activeSettings.audioVolume)
    }

    // MARK: - 通话组

    /// 启动时把设置里的 TG 同步进来。不写日志——还没连过，没必要刷屏。
    func adoptTalkgroup(_ talkgroup: Int) {
        activeTalkgroup = max(0, talkgroup)
        activeSettings.talkgroup = activeTalkgroup
    }

    /// 切换收听的 TG（0 = 全部）。不需要重连：Homebrew 的推送内容由服务器决定，
    /// 这里改的是本地播放过滤，顺手把旧 TG 还挂着的通话收尾、解码器复位。
    func setTalkgroup(_ talkgroup: Int) {
        let value = max(0, talkgroup)
        guard value != activeTalkgroup else { return }

        activeTalkgroup = value
        activeSettings.talkgroup = value
        filteredFrames = 0

        // 旧组正在播的音频先掐掉；还标着「通话中」的旧组通话要手动收尾，
        // 因为它之后的结束符会被过滤器挡掉，否则会一直挂在「正在通话」里。
        voice.reset()
        let now = Date()
        for index in calls.indices where calls[index].isActive {
            calls[index].isActive = false
            calls[index].updatedAt = now
        }
        syncVoiceUI()

        if value > 0 {
            append(.info, "→ 只收听 TG \(value)")
            append(.warning, "Homebrew 客户端无法主动改变服务器推送：该 TG 不是 SelfCare 里的 Static TG 时，语音根本不会发下来")
        } else {
            append(.info, "→ 收听全部通话组")
        }
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
        configRetries = 0
        configProbed = false
        sessionNaks = 0
        activeTalkgroup = settings.talkgroup
        filteredFrames = 0
        challenge = []
        usedLegacyAuth = false
        rxFrames = 0
        txFrames = 0
        lastProblem = nil

        voice.reset()
        voice.volume = Float(settings.audioVolume)
        voice.isMuted = !settings.audioEnabled
        syncVoiceUI()

        guard settings.dmrId > 0, !settings.sanitizedPassword.isEmpty else {
            state = .failed("请先在设置里填写 DMR ID 与 Hotspot 密码")
            append(.error, "身份信息不完整：DMR ID 与 Hotspot 密码不能为空")
            return
        }

        // 只有真的要上报配置包时，呼号才是必需的（它是 302 字节配置块的前 8 字节）。
        // 默认不发 RPTC，所以留空也照样能连。
        guard !settings.reportConfig || !settings.normalizedCallsign.isEmpty else {
            state = .failed("请先填写呼号（Callsign），或关闭「上报配置包 RPTC」")
            append(.error, "呼号为空：RPTC 配置块会缺字段，BrandMeister 直接回 MSTNAK")
            return
        }

        if settings.usesEssid && settings.dmrId > 42_949_672 {
            // 再乘 100 就溢出 32 位，master 只会回 MSTNAK。参考实现同样在这一步挡住。
            state = .failed("DMR ID 过大：ESSID 需要 7 位 ID，不是 9 位热点 ID")
            append(.error, "ESSID 换算会溢出：DMR ID 应填 7 位编号")
            return
        }

        state = .connecting
        append(.info, "开始连接 \(settings.host):\(settings.port)（\(settings.transport.short)）")
        if settings.usesEssid {
            append(.info, "热点 ID \(settings.hotspotId)（DMR ID \(settings.dmrId) + ESSID 后缀 \(settings.essidSuffix ?? 0)）")
        }

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
        challenge = []
        append(.info, "→ RPTL 登录请求（第 \(loginAttempt) 次），热点 ID \(activeSettings.hotspotId)")
        send(HB.login(id: activeSettings.hotspotId), label: "RPTL")
        armLoginTimeout()
    }

    /// RPTK：默认走标准 SHA256(挑战盐 ‖ 密码)；被拒回退后用传统明文。
    private func sendRPTK() {
        let password = activeSettings.sanitizedPassword
        if usedLegacyAuth {
            append(.warning, "→ RPTK 传统明文鉴权（兼容模式）")
            send(HB.authLegacy(id: activeSettings.hotspotId, password: password), label: "RPTK")
        } else {
            send(HB.auth(id: activeSettings.hotspotId, challenge: challenge, password: password), label: "RPTK")
        }
    }

    /// MSTNAK：按阶段给不同的解释，别把「ID 不认」和「密码不对」混成一句话。
    private func handleNak() {
        switch state {
        case .loggingIn:
            // RPTL 就被拒：要么这个 ID 不存在/没注册，要么已经有一条会话占着它。
            append(.error, "本次上报热点 ID \(activeSettings.hotspotId)（DMR ID \(activeSettings.dmrId)，ESSID \(activeSettings.essid)）")
            if configRetries > 0 {
                fail("重新登录被拒（MSTNAK）：该热点 ID 已被另一条会话占用，先把其它设备断开（手机 MMDVM / 盒子 / 另一台手机）再连", allowRetry: false)
            } else {
                fail("服务器不认这个热点 ID（MSTNAK）：核对 DMR ID 与 ESSID 后缀是否和 SelfCare 里一致，或该 ID 正被其它设备占用", allowRetry: false)
            }

        case .authenticating where !usedLegacyAuth:
            // 标准挑战应答被拒：先按老 HBlink 的明文格式再试一次，仍拒才算密码错。
            usedLegacyAuth = true
            append(.warning, "标准 SHA256 鉴权被拒（MSTNAK），改用传统明文 RPTK 重试一次")
            sendRPTK()
            armLoginTimeout()

        case .authenticating:
            append(.error, "热点 ID \(activeSettings.hotspotId) 的密码校验未通过；密码长度 \(activeSettings.sanitizedPassword.count)")
            fail("密码不对（MSTNAK）：要填 SelfCare → Hotspot Security 里的 Hotspot 密码，不是 BrandMeister 网站的登录密码", allowRetry: false)

        case .configuring where !configProbed:
            // MSTNAK 在这套协议里有两种含义：① 配置内容被拒；② 这条链路已被 master 判死
            // （官方规范：收不到心跳后，重复器发来的任何包都回 MSTNAK，客户端应重新登录）。
            // 先发一个 RPTPING 当探针：回 MSTPONG 说明链路是好的，只是不接受配置包
            // ——现在的 MMDVMHost 早就不发 RPTC 了，这个包对收发语音没有影响。
            configProbed = true
            append(.warning, "RPTC 被拒绝（MSTNAK）：先发 RPTPING 探测链路是否还活着")
            append(.error, "本次上报：热点 ID \(activeSettings.hotspotId) · 呼号「\(activeSettings.normalizedCallsign)」· 302 字节")
            send(HB.ping(id: activeSettings.hotspotId, modern: false), label: "RPTPING 探测")
            armLoginTimeout()

        case .configuring where configRetries < 2:
            // 探针也被 NAK：会话确实没了，按规范整轮重登（重发同一个 RPTC 是没用的）。
            // 等 5 秒再登，给服务器把旧会话超时清掉的时间。
            configRetries += 1
            configProbed = false
            append(.warning, "会话已被 master 清除，5 秒后重新登录（第 \(configRetries) 次）")

            configRetryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.state != .offline, self.state != .online else { return }
                    self.challenge = []
                    self.loginAttempt = 0
                    self.usedLegacyAuth = false
                    self.sendLogin()
                }
            }
            configRetryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)

        case .configuring:
            let callsign = activeSettings.normalizedCallsign
            let packet = HB.config(id: activeSettings.hotspotId, callsign: callsign)
            append(.error, "最后一次上报的 RPTC（\(packet.count) 字节），可对照官方字段表：")
            append(.error, "RPTC 内容", hex: packet.hexDump)
            append(.error, "排查顺序：① 同一个热点 ID 是否还被别的设备连着（手机 MMDVM、盒子、旧会话）② SelfCare 里这个 ID 是否启用 ③ 呼号是否与登记一致")
            fail("服务器持续拒绝登录（MSTNAK）：该热点 ID 可能正被其它设备占用，或会话已被清除", allowRetry: false)

        case .online:
            // 在线后被清会话（别处用同一个 ID 登录过），按参考实现的做法重新登录。
            // 但要设上限，否则两个设备抢同一个 ID 时会变成无限重连。
            sessionNaks += 1
            if sessionNaks > 2 {
                fail("服务器反复清除会话（MSTNAK）：这个热点 ID 正被另一条连接占用，先把其它设备断开再连", allowRetry: false)
                return
            }
            append(.warning, "会话被 master 清除（MSTNAK），重新登录（第 \(sessionNaks) 次）")
            loginAttempt = 0
            state = .connecting
            sendLogin()

        default:
            append(.rx, "← MSTNAK（当前状态 \(state.label)）")
        }
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
            // 部分 master 不回第三个 RPTACK，只要还在收包就认为链路已通。
            // 但探针发出去了还没回音，说明这个会话是死的，别再自欺欺人地判在线。
            if !configProbed, let lastServerPacket, Date().timeIntervalSince(lastServerPacket) < silenceTimeout {
                goOnline()
            } else if configProbed {
                fail("服务器既拒绝配置包、又不回应心跳：会话已失效，请稍等半分钟再连一次")
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
        configRetries = 0
        configProbed = false
        sessionNaks = 0
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

        send(HB.ping(id: activeSettings.hotspotId, modern: activeSettings.modernPing),
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
                // RPTL 的应答里，第 6…9 字节是 4 字节挑战盐，RPTK 必须做 SHA256(盐 ‖ 密码)。
                guard bytes.count >= 10 else {
                    append(.warning, "RPTACK 只有 \(bytes.count) 字节，拿不到挑战盐")
                    fail("服务器应答异常：RPTACK 长度不足（\(bytes.count) 字节）")
                    return
                }
                challenge = Array(bytes[6..<10])
                state = .authenticating
                append(.info, "← RPTACK 收到挑战盐 \(Data(challenge).hexDump)，→ RPTK 鉴权")
                sendRPTK()
                armLoginTimeout()
            case .authenticating:
                // 配置包（RPTC）是可选的：现代 master 不需要，部分还会因此回 MSTNAK。
                // 默认跳过，直接进入在线状态；只有自建 HBLink 等老 master 才在设置里打开。
                guard activeSettings.reportConfig else {
                    append(.info, "← RPTACK 鉴权通过，直接上线（未上报 RPTC，现代 master 不需要）")
                    goOnline()
                    return
                }
                state = .configuring
                configProbed = false
                let callsign = activeSettings.normalizedCallsign
                let packet = HB.config(id: activeSettings.hotspotId, callsign: callsign)
                append(.info, "← RPTACK 鉴权通过，→ RPTC 上报配置（\(packet.count) 字节，呼号「\(callsign)」）")
                send(packet, label: "RPTC")
                armLoginTimeout()
            case .configuring:
                goOnline()
            default:
                append(.rx, "← RPTACK")
            }

        case "MSTN": // MSTNAK
            handleNak()

        case "MSTC": // MSTCL
            fail("服务器主动断开连接（MSTCL）")

        case "MSTA": // MSTACK —— 老规范里 master 收到 RPTC 回的就是这一帧
            if state == .configuring {
                append(.info, "← MSTACK 配置已接受")
                goOnline()
            } else {
                append(.rx, "← MSTACK")
            }

        case "MSTP", "DMRP":
            if configProbed, state == .configuring {
                // 探针回了 MSTPONG：会话是活的，只是不收 RPTC。语音走 DMRD，配置包可有可无。
                configProbed = false
                append(.info, "← MSTPONG 链路正常：服务器只是不接受配置包，不影响语音收发，直接上线")
                goOnline()
            } else {
                append(.rx, "← 心跳应答")
            }

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

        // 链路是活的，但这一帧不属于要听的 TG：计数后丢弃，不进通话列表、不进解码器。
        guard frame.belongs(toTalkgroup: activeTalkgroup, myId: activeSettings.hotspotId) else {
            filteredFrames += 1
            return
        }

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
        configRetryWork?.cancel()
        configRetryWork = nil

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
