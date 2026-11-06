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
    /// 当前（或最近一次）说话的人。呼号由 `CallsignDirectory` 另查，这里只有 ID。
    @Published private(set) var currentSpeaker: ActiveSpeaker?

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
        currentSpeaker = nil
        pendingConfirmTalkgroup = nil
        talkgroupAliveAt = nil
        callWatchdog?.cancel()
        callWatchdog = nil
        trafficStat.removeAll()
        trafficTotal = 0
        trafficFiltered = 0
        warnedNoTraffic = false
        lastTrafficReport = Date()

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
            append(.info, "→ 只收听 TG \(value)（本地过滤，其它组不再解码）")
            if state != .online {
                append(.info, "连上之后会自动向 TG \(value) 呼叫一次，BrandMeister 才会把它标成动态订阅")
            }
        } else {
            append(.info, "→ 收听全部通话组")
        }
    }

    // MARK: - 呼叫（激活动态 TG）

    /// 最近一次呼叫的时间与目标，只拦「同一组 3 秒内重复呼叫」，
    /// 换成别的组立刻就能发。
    private var lastCallAt: Date?
    private var lastCallTalkgroup: Int?
    private var callTask: Task<Void, Never>?
    /// 一轮呼叫（头 + 8 个突发 + 尾，约 0.6 秒）还没发完。中途打断会留下一个没有结束符的语音头，
    /// 服务器会把那个时隙占十几秒，所以宁可让这次请求落空。
    private var isCalling = false
    private var dmrSeq: UInt8 = 0
    /// 等回音的看门狗：25 秒没收到目标 TG 的帧就说清原因，别让界面一直沉默。
    private var callWatchdog: Task<Void, Never>?
    /// 刚呼叫过、还在等第一帧回音的 TG。收到它的语音就说明动态订阅真的生效了，
    /// 打一行确认日志——否则用户只能靠「有没有声音」猜。
    private var pendingConfirmTalkgroup: Int?

    /// 收到的帧按「dst@slot」汇总，每 15 秒报一次。
    ///
    /// 这是排查「收不到语音」最关键的一条信息：服务器到底在推什么。
    /// 如果摘要里全是别的组，说明要的组没订阅上；如果摘要里就有它，
    /// 说明订阅是好的，只是那一会儿没人讲话。
    private var trafficStat: [String: Int] = [:]
    private var trafficTotal = 0
    private var trafficFiltered = 0
    private var lastTrafficReport = Date()
    /// 长时间一帧 DMRD 都没收到，只提醒一次，别每 15 秒重复。
    private var warnedNoTraffic = false

    /// 当前 TG 最近一次「有语音下来」或「我们主动续订」的时刻。
    /// 它是续订计时器的基准：超过设置里的分钟数没有任何动静，就再呼叫一次。
    private var talkgroupAliveAt: Date?

    /// 有没有「真的在进行」的通话。
    ///
    /// 不能直接看 `activeCalls`：部分 master 不推语音结束符，那些通话会一直挂在
    /// `isActive == true` 上，把呼叫和续订永久挡住。语音帧是持续刷新的，
    /// 所以「10 秒内没有更新」就当作已经结束。
    private var hasLiveCall: Bool {
        let now = Date()
        return calls.contains { $0.isActive && now.timeIntervalSince($0.updatedAt) < 10 }
    }

    /// 向某个通话组发一次极短的静音 PTT：语音头 → 静音突发 → 结束符。
    ///
    /// Homebrew 没有任何「订阅」指令，服务器只推它认为已经订阅的 TG。
    /// 发一次呼叫能让 BrandMeister 把这个组标成动态订阅，之后它的语音才会下来；
    /// 光把本地过滤器改成这个 TG 是没用的（那就只是「别的组不播」而已）。
    func call(talkgroup: Int) {
        guard talkgroup > 0, talkgroup <= 0xFF_FFFF else { return }
        guard state == .online else {
            // 断线时点「确定」照样会走到这里，给一句明确的交代，别让人以为已经发出去了。
            append(.info, "还没连上服务器：连上后会自动向 TG \(talkgroup) 呼叫一次")
            return
        }

        // 有人正在说话时别抢：插一个语音头进去会把这一句打断。
        if hasLiveCall {
            append(.warning, "TG \(talkgroup) 上还有通话在进行，这次先不呼叫")
            return
        }

        let now = Date()
        if let lastCallAt, lastCallTalkgroup == talkgroup,
           now.timeIntervalSince(lastCallAt) < 3 { return }
        lastCallAt = now
        lastCallTalkgroup = talkgroup

        // 上一轮还没发完（约 0.6 秒），别插队——中途打断会留下半截呼叫。
        guard !isCalling else { return }
        isCalling = true
        talkgroupAliveAt = now

        // 呼叫帧里的源地址必须是「本人 DMR ID」（7 位），不是 9 位热点 ID：
        // DMRD 的 src 字段只有 3 字节（≤16777215），塞 hotspotId 会溢出，
        // 变成一个别人的 DMR ID —— BrandMeister 会当冒用身份整帧丢弃，
        // 表现就是「呼叫发出去了，但这个组永远没有语音下来」。
        let src = activeSettings.dmrId
        let peer = activeSettings.hotspotId
        guard src > 0, src <= 0xFF_FFFF else {
            isCalling = false
            append(.warning, "DMR ID \(src) 不是 7 位编号，不能作为呼叫的源地址")
            return
        }

        let slot = activeSettings.callSlot == 1 ? 1 : 2
        let slotFlag: UInt8 = slot == 2 ? 0x80 : 0x00
        let stream = UInt32.random(in: 1...0xFFFF_FFFE)
        let head = DMRCallCodec.voicePayload(dst: talkgroup, src: src, isTerminator: false)
        let tail = DMRCallCodec.voicePayload(dst: talkgroup, src: src, isTerminator: true)

        append(.info, "→ 呼叫 TG \(talkgroup)（TS\(slot)，DMR ID \(src) → 热点 \(peer)，静音 PTT）")
        append(.info, "BrandMeister 收到这次发射后会把它记为动态订阅，之后该组的语音就会推下来")
        pendingConfirmTalkgroup = talkgroup
        startCallWatchdog(talkgroup)

        callTask?.cancel()
        callTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCalling = false }

            // 1. 语音头：master 认的就是这一帧，动态订阅在这一步建立
            self.sendDmrFrame(src: src, dst: talkgroup, peer: peer,
                              flags: slotFlag | 0x20 | 0x01,
                              streamId: stream,
                              payload: head,
                              label: "DMRD 语音头 → TG \(talkgroup)")

            // 2. 8 个静音突发，每 60ms 一帧（约半秒的真实 PTT）。
            //    只发一帧有些 master 会当噪音丢掉，宁可像一次真的按键。
            //    flags 低 4 位带突发序号 0…5，与 DroidStar 的 `(m_dmrcnt - 1) % 6` 一致。
            for index in 1...8 {
                try? await Task.sleep(nanoseconds: 60_000_000)
                if Task.isCancelled { return }
                let burst = UInt8((index - 1) % 6)
                self.sendDmrFrame(src: src, dst: talkgroup, peer: peer,
                                  flags: slotFlag | burst,
                                  streamId: stream,
                                  payload: DMRCallCodec.silenceBurst(index: index - 1),
                                  label: "DMRD 语音突发 \(index)/8",
                                  quiet: index > 1)
            }
            self.append(.tx, "→ 静音突发 8 帧（每 60ms 一帧）已发完")

            // 3. 结束符：不收尾的话服务器会把这个时隙占十几秒
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return }
            self.sendDmrFrame(src: src, dst: talkgroup, peer: peer,
                              flags: slotFlag | 0x20 | 0x02,
                              streamId: stream,
                              payload: tail,
                              label: "DMRD 结束符")
        }
    }

    /// 呼叫之后等回音的超时。到点还没有该 TG 的帧，就把可能的原因说清楚，
    /// 免得用户只看到「呼叫已发出」然后对着静音的扬声器发呆。
    private func startCallWatchdog(_ talkgroup: Int) {
        callWatchdog?.cancel()
        callWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.pendingConfirmTalkgroup == talkgroup else { return }
            self.pendingConfirmTalkgroup = nil
            self.append(.warning, "25 秒内没收到 TG \(talkgroup) 的语音：订阅可能没建立，或这个组此刻没人说话")
            self.append(.info, "先看下一行「近期流量」：里面有这个组 = 订阅成功、只是没声音；"
                + "只有别的组 = 订阅没生效（换 TS 或换一个正在有人讲的组，如 91 测一下）")
        }
    }

    private func sendDmrFrame(src: Int, dst: Int, peer: Int, flags: UInt8,
                              streamId: UInt32, payload: [UInt8], label: String,
                              quiet: Bool = false) {
        dmrSeq = dmrSeq &+ 1
        let frame = HB.dmrFrame(seq: dmrSeq, src: src, dst: dst, peer: peer,
                                flags: flags, streamId: streamId, payload: payload)
        send(frame, label: label, quiet: quiet)
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

    /// 续订、呼叫相关的设置在连接期间改了也要立刻生效，不必重连。
    func applyBehaviour(_ settings: Settings) {
        let slotChanged = activeSettings.callSlot != settings.callSlot
        activeSettings.autoRenewTalkgroup = settings.autoRenewTalkgroup
        activeSettings.talkgroupRenewMinutes = settings.talkgroupRenewMinutes
        activeSettings.callSlot = settings.callSlot
        activeSettings.autoCallOnConnect = settings.autoCallOnConnect

        // 时隙只在「发出去的那一刻」起作用，改完不重新呼叫等于没改。
        // 这里顺手补一次（并绕开 3 秒节流），用户改完时隙就能直接看结果。
        if slotChanged, state == .online, activeTalkgroup > 0, !isCalling {
            lastCallAt = nil
            append(.info, "时隙已改为 TS\(activeSettings.callSlot == 1 ? 1 : 2)，重新向 TG \(activeTalkgroup) 呼叫一次")
            call(talkgroup: activeTalkgroup)
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
        trafficStat.removeAll()
        trafficTotal = 0
        trafficFiltered = 0
        warnedNoTraffic = false
        lastTrafficReport = Date()
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

        // 呼号是 302 字节配置块的前 8 字节。缺了它多数 master 会回 MSTNAK，
        // 但不要因此把人挡在门外——先连上，被拒再降级上线，日志里会说清楚。
        if !settings.skipConfig && settings.normalizedCallsign.isEmpty {
            append(.warning, "呼号为空：RPTC 的呼号字段会是空格，部分 master 会回 MSTNAK。"
                + "建议在设置里填上与 SelfCare 一致的呼号")
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
            let suffix = String(format: "%02d", settings.essidSuffix ?? 0)
            append(.info, "登录 ID \(settings.hotspotId)（DMR ID \(settings.dmrId) + SSID \(suffix)）")
        } else {
            append(.warning, "没填 ESSID：将以 7 位 DMR ID \(settings.dmrId) 登录。"
                + "BrandMeister 的热点是 9 位 ID（DMR ID + SSID，如 460123401），"
                + "建议填 01 并与 SelfCare → My Hotspots 核对")
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

        // 先发 RPTCL（参考实现 DroidStar 的 send_disconnect）。不发的话 master 要等
        // 会话超时才释放这个热点 ID，这段时间内立刻重连会被判「ID 被占用」。
        if wasActive {
            send(HB.disconnect(id: activeSettings.hotspotId), label: "RPTCL 主动登出")
        }

        state = .offline
        if wasActive { append(.info, "已断开连接") }

        // 给 UDP 一点时间把 RPTCL 真正发出去，再拆 socket；teardown 会立刻取消连接。
        // 若这 0.25 秒里用户又点了连接（state 已不是 offline），就别把新连接拆掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.state == .offline else { return }
            self.teardown()
        }
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
        verifyHotspotRegistration()

        // 连上就向当前 TG 呼叫一次：不发的话服务器不会主动推这个组的语音，
        // 只能听到 SelfCare 里配成 Static TG 的内容。
        if activeSettings.autoCallOnConnect, activeSettings.talkgroup > 0 {
            let talkgroup = activeSettings.talkgroup
            Task { [weak self] in
                // 稍等一下，别和首包心跳挤在一起
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, self.state == .online else { return }
                self.call(talkgroup: talkgroup)
            }
        } else if activeSettings.autoCallOnConnect {
            append(.info, "没有设置通话组，跳过自动呼叫")
        }
    }

    // MARK: - 心跳

    /// 上线后到 BrandMeister 设备库核对一次登录 ID。
    ///
    /// 「后台 My Hotspots 里看不到设备」几乎都是**登录 ID 和 SelfCare 里那台设备不一致**
    /// （最常见的是 SSID 少 / 多了一位），而 master 并不会因此拒绝登录——
    /// 表现就是「显示连接成功，但后台没有、语音也不来」。这里直接把核对结果写进日志。
    private func verifyHotspotRegistration() {
        let id = activeSettings.hotspotId
        let host = activeSettings.host.lowercased()
        let looksLikeBrandMeister = host.contains("brandmeister")

        Task { [weak self] in
            do {
                let device = try await BrandMeisterAPI().device(id)
                guard let self else { return }
                let callsign = device.callsign ?? "未知呼号"
                let master = device.lastKnownMaster.map { String($0) } ?? "未知"
                self.append(.info, "BM 设备库核对：\(id) = \(callsign)，最后连过 master \(master)")
            } catch {
                guard let self else { return }
                if looksLikeBrandMeister {
                    self.append(.warning, "BM 设备库查不到 \(id)：这个 ID 不是已注册热点。"
                        + "去 SelfCare → My Hotspots 核对 9 位 ID 与 ESSID 后缀（密码也要属于这台设备）")
                }
            }
        }
    }

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

        reportTraffic()
        renewTalkgroupIfIdle()
    }

    /// 每 15 秒把「刚收到的帧都是哪些组」汇总成一行。
    ///
    /// 这一行是给排查用的：能看到服务器实际在推什么，就不用在
    /// 「订阅没生效」和「那个组没人说话」之间瞎猜。
    private func reportTraffic() {
        guard trafficTotal > 0 else {
            // 链路是活的（心跳有回），但服务器一帧语音都没推 —— 这本身就是结论：
            // 订阅没建立，或者这一小段时间里真的没人讲话。
            let idle = Date().timeIntervalSince(lastTrafficReport)
            guard idle >= 30, !warnedNoTraffic else { return }
            warnedNoTraffic = true
            lastTrafficReport = Date()
            append(.warning, "30 秒内没收到任何 DMRD 帧：服务器没向这个热点推流量，"
                + "要么订阅没建立，要么这个组在这个时隙上没有活动")
            return
        }
        let elapsed = Date().timeIntervalSince(lastTrafficReport)
        guard elapsed >= 15 else { return }

        // 当前组优先展示：有它没它，一眼就能判断订阅状态。
        let target = activeTalkgroup
        let sorted = trafficStat.sorted { $0.value > $1.value }
        let mine = target > 0 ? sorted.filter { $0.key.hasPrefix("\(target)@") } : []
        let rest = target > 0 ? sorted.filter { !$0.key.hasPrefix("\(target)@") } : sorted

        let items = (mine + rest)
            .prefix(4)
            .map { entry -> String in
                let parts = entry.key.split(separator: "@")
                let dst = parts.first.map { String($0) } ?? entry.key
                let slot = parts.count > 1 ? String(parts[1]) : "?"
                let mark = (target > 0 && dst == String(target)) ? " ← 当前组" : ""
                return "\(dst)(TS\(slot))×\(entry.value)\(mark)"
            }
            .joined(separator: "、")

        let filtered = trafficFiltered > 0 ? "，其中 \(trafficFiltered) 帧不属于当前组已丢弃" : ""
        append(.rx, "近期流量 \(Int(elapsed))s：\(items)，共 \(trafficTotal) 帧\(filtered)")

        trafficStat.removeAll()
        trafficTotal = 0
        trafficFiltered = 0
        warnedNoTraffic = false
        lastTrafficReport = Date()
    }

    /// 动态 TG 的续订。
    ///
    /// BrandMeister 的动态订阅在静默一段时间后会被释放，释放之后服务器就不再推这个组，
    /// 表现是「突然听不到了，但链路还在」。这里在静默超过设置值时补一次静音呼叫，
    /// 让订阅一直续上，不用用户自己去点「确定」。
    private func renewTalkgroupIfIdle() {
        guard state == .online, !isCalling, activeTalkgroup > 0 else { return }
        // 别的组正在通话时先等，否则每 5 秒一条「续订」日志刷满，而 call() 又会自己跳过。
        guard !hasLiveCall else { return }
        // 关掉「连接后自动呼叫」的用户就是不想让 App 自己发射，续订也不该偷偷发。
        guard activeSettings.autoCallOnConnect, activeSettings.autoRenewTalkgroup else { return }

        // 还没有基准时间（刚连上、自动呼叫还没跑）就先记一个，别一上来就补发。
        guard let aliveAt = talkgroupAliveAt else {
            talkgroupAliveAt = Date()
            return
        }

        let minutes = max(1, activeSettings.talkgroupRenewMinutes)
        let idle = Date().timeIntervalSince(aliveAt)
        guard idle >= Double(minutes) * 60 else { return }

        append(.info, "TG \(activeTalkgroup) 已静默 \(Int(idle / 60)) 分钟，自动续订动态订阅")
        call(talkgroup: activeTalkgroup)
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
                // 参考实现 DroidStar 在这里一定发 RPTC，并等第三个 RPTACK 才 CONNECTED_RW。
                // 少这一步 BrandMeister 不会把设备当成已完成配置的热点，语音也就不会推下来。
                guard !activeSettings.skipConfig else {
                    append(.warning, "← RPTACK 鉴权通过，但设置里选择了跳过 RPTC：握手只走两段，"
                        + "BrandMeister 后台不会显示这台设备，也不会推 TG 语音")
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
                // 探针回了 MSTPONG：会话是活的，只是不收 RPTC。先上线，别把用户挡在登录页，
                // 但要把后果说清楚——配置没报上去，后台就没有这台设备，多半也收不到语音。
                configProbed = false
                append(.warning, "← MSTPONG 链路正常，但配置包被拒：先上线，后台可能仍看不到设备")
                append(.info, "如果一直收不到语音，核对：① SelfCare 里这个 9 位 ID 是否存在 ② 呼号是否与登记一致 ③ 是否被别的设备占用")
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

        // 不管属于哪个组，先记一笔「服务器推了什么」，供 `reportTraffic` 汇总。
        trafficStat["\(frame.dst)@\(frame.slot)", default: 0] += 1
        trafficTotal += 1
        warnedNoTraffic = false

        // 链路是活的，但这一帧不属于要听的 TG：计数后丢弃，不进通话列表、不进解码器。
        // 单呼同时认 DMR ID 和 9 位热点 ID —— 有的 master 按热点 ID 寻址。
        guard frame.belongs(toTalkgroup: activeTalkgroup,
                            myId: activeSettings.dmrId,
                            hotspotId: activeSettings.hotspotId) else {
            filteredFrames += 1
            trafficFiltered += 1
            return
        }

        // 呼叫之后的第一个回音：说明动态订阅确实建立了。
        if let pending = pendingConfirmTalkgroup {
            pendingConfirmTalkgroup = nil
            append(.info, "✅ TG \(pending) 的语音已下发，动态订阅生效")
        }
        // 有语音下来就说明订阅还活着，续订计时器从这一刻重新算。
        talkgroupAliveAt = Date()

        let key = "\(frame.src)-\(frame.dst)-\(frame.slot)"
        let now = Date()

        if frame.isVoiceHeader {
            closeCall(key: key, at: now)
            calls.insert(makeCall(frame: frame, key: key, at: now), at: 0)
            trimCalls()
            voice.begin(key: key)
            syncVoiceUI()
            trackSpeaker(frame, at: now, isNewCall: true)
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
            closeSpeaker(frame, at: now)
            return
        }

        // 语音突发：33 字节 AMBE+2 载荷 → 3 帧 → 480 采样
        if !frame.isDataSync {
            voice.push(key: key, payload: frame.payload)
            syncVoiceUI()
            trackSpeaker(frame, at: now, isNewCall: false)
        }

        if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
            calls[index].frames += 1
            calls[index].updatedAt = now
        } else {
            calls.insert(makeCall(frame: frame, key: key, at: now), at: 0)
            trimCalls()
        }
    }

    /// 维护「当前讲话人」。
    ///
    /// 语音头是明确的「换人说话」信号；语音帧只是延续，但如果中间隔了 3 秒以上
    /// （换气、或者 master 没推结束符），也当成新的一句重新计时。
    private func trackSpeaker(_ frame: HB.DmrFrame, at date: Date, isNewCall: Bool) {
        if !isNewCall,
           var speaker = currentSpeaker,
           speaker.src == frame.src,
           speaker.dst == frame.dst,
           speaker.slot == frame.slot,
           speaker.endedAt == nil,
           date.timeIntervalSince(speaker.lastVoiceAt) < 3 {
            speaker.lastVoiceAt = date
            currentSpeaker = speaker
            return
        }

        currentSpeaker = ActiveSpeaker(
            src: frame.src,
            dst: frame.dst,
            slot: frame.slot,
            isPrivate: frame.isPrivate,
            startedAt: date,
            lastVoiceAt: date,
            endedAt: nil
        )
    }

    /// 收到语音结束符：这一句说完了。名字不清掉——界面上还要显示「刚才谁在说」。
    private func closeSpeaker(_ frame: HB.DmrFrame, at date: Date) {
        guard var speaker = currentSpeaker,
              speaker.src == frame.src,
              speaker.slot == frame.slot else { return }
        speaker.lastVoiceAt = max(speaker.lastVoiceAt, date)
        speaker.endedAt = date
        currentSpeaker = speaker
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

    /// `quiet` 用于一次呼叫里的连续突发：帧照发、只记一次日志，
    /// 否则半秒内十行 hexDump 会把人眼能看的日志全冲掉。
    private func send(_ data: Data, label: String, quiet: Bool = false) {
        guard state != .offline else { return }

        txFrames += 1
        if !quiet { append(.tx, "→ \(label)", hex: data.hexDump) }

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
        callTask?.cancel()
        callTask = nil
        callWatchdog?.cancel()
        callWatchdog = nil
        lastCallAt = nil
        lastCallTalkgroup = nil
        isCalling = false
        pendingConfirmTalkgroup = nil
        talkgroupAliveAt = nil
        trafficStat.removeAll()
        trafficTotal = 0
        trafficFiltered = 0

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        webSocketSession?.invalidateAndCancel()
        webSocketSession = nil

        voice.reset()
        syncVoiceUI()
        currentSpeaker = nil

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
