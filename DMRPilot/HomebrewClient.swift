//
//  HomebrewClient.swift
//  DMRPilot
//
//  以 MMDVM / Homebrew 热点身份连上 BrandMeister。
//
//  ── 这一层现在只做「管道 + 界面状态」──────────────────────────────
//
//      UDP / WebSocket 收发       ← 这里
//      定时器（心跳 / 发射节拍）  ← 这里
//      音频采集与播放            ← Audio/ 目录
//      握手 / 组帧 / 拆帧        ← Core/DMRCore.cpp（C++，移植自 DroidStar）
//
//  所有字节级的判断都在 C++ 核心里，这里不再自己拼帧、也不再猜「这个包是什么意思」。
//  这一轮重写把以前那些补丁式的东西全删了：
//
//    - 不再有「RPTC 被拒 → 改成不发 → 重连」的自动降级，改成设置里的一个开关；
//    - 不再有 MSTNAK 的三种阶段探测（RPTPING 探针那套），服务器说什么就按什么处理；
//    - 不再用「3 秒没语音帧」猜通话是否结束，改用 DroidStar 的 2 秒收流看门狗；
//    - 「订阅」和「PTT」走同一条发射路径，唯一的区别是语音帧来自静音表还是麦克风。
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

    /// 当前选中的通话组（0 = 不过滤）。它同时是「订阅目标」。
    @Published private(set) var activeTalkgroup = 0
    /// 服务器**实际**在推的通话组。BrandMeister 推的是这台热点被订阅的组，
    /// 常常不等于设置里选的那个（SelfCare 里可能还挂着静态组）。
    @Published private(set) var serverTalkgroup: Int?
    /// 因为「只收听选定组」而被丢掉的帧数。
    @Published private(set) var filteredFrames = 0
    /// 当前（或最近一次）说话的人。呼号由 `CallsignDirectory` 另查。
    @Published private(set) var currentSpeaker: ActiveSpeaker?

    @Published private(set) var isVoicePlaying = false
    @Published private(set) var voiceLevel: Float = 0
    @Published private(set) var voiceErrorCount = 0
    @Published private(set) var voicePackets = 0

    /// 正在按住 PTT 发射
    @Published private(set) var isTransmitting = false
    @Published private(set) var txLevel: Float = 0
    @Published private(set) var txSeconds: Double = 0

    var activeCalls: [LiveCall] { calls.filter { $0.isActive } }
    var recentCalls: [LiveCall] { calls.filter { !$0.isActive } }

    // MARK: - 协议核心

    /// C++ 核心：握手状态机 + 组帧 / 拆帧。
    private let core = dmr_core_create()!

    // MARK: - 内部状态

    private var activeSettings = Settings()
    private var connection: NWConnection?
    private var webSocket: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?

    private var pingTimer: Timer?
    private var tickTimer: Timer?
    private var loginTimer: DispatchWorkItem?
    private var loginToken = 0
    private var loginAttempt = 0
    private var retryWork: DispatchWorkItem?
    private var lastServerPacket: Date?
    /// 会话被拒 / 被关的次数，超过上限就不再自动重连，避免死循环刷屏。
    private var refusals = 0

    /// 只在第一次遇到某个陌生命令字时打日志，避免刷屏。
    private var unknownTags: Set<String> = []

    /// AMBE+2 解码 + 播放
    private let voice = VoicePipeline()

    // MARK: - 收流状态（对齐 DroidStar 的 stream_state）

    private var streamKey: String?
    private var streamLastFrameAt: Date?
    /// DroidStar 的收流看门狗是 100 × 20 ms ≈ 2 秒。
    private let streamTimeout: TimeInterval = 2.0

    // MARK: - 发射状态

    private enum TxKind {
        /// 向某个通话组发一次「静音 PTT」，让服务器记成动态订阅
        case subscribe
        /// 用户按住 PTT
        case ptt
    }

    private var txKind: TxKind = .subscribe
    private var txTimer: Timer?
    private var txBurstsLeft = 0
    private var txStartedAt: Date?
    private var lastSubscribeAt: Date?
    private var lastSubscribeTalkgroup: Int?
    /// 最近一次订阅的时间，用来做续订判断
    private var talkgroupAliveAt: Date?

    private let mic = PttMicrophone()
    private let encoder = HREncoder()
    private var pttFrames = [[Int16]]()

    // MARK: - 流量统计

    private var trafficStat: [String: Int] = [:]
    private var trafficTotal = 0
    private var lastTrafficReport = Date()
    private var warnedNoTraffic = false

    private let pingInterval: TimeInterval = 5
    private let silenceTimeout: TimeInterval = 15
    /// 一次订阅发射发多少个语音突发（60 ms 一个）。12 个 ≈ 0.75 秒，接近真人按一下话筒。
    private let subscribeBursts = 12

    // MARK: - 生命周期

    init() {
        voice.volume = Float(activeSettings.audioVolume)
        // RPTC 里那几项资料字段，DroidStar 是写死的，这里给个正经值。
        dmr_core_set_text(core, DMR_TEXT_LOCATION, "DMRPilot")
        dmr_core_set_text(core, DMR_TEXT_DESCRIPTION, "DMRPilot iOS")
        dmr_core_set_text(core, DMR_TEXT_URL, "https://brandmeister.network")
        dmr_core_set_text(core, DMR_TEXT_SOFTWARE, "20260101")
        dmr_core_set_text(core, DMR_TEXT_PACKAGE, "DMRPilot_iOS")
    }

    deinit {
        dmr_core_destroy(core)
    }

    // MARK: - 通话组

    /// 启动时把设置里的 TG 同步进来。不写日志——还没连过，没必要刷屏。
    func adoptTalkgroup(_ talkgroup: Int) {
        activeTalkgroup = max(0, talkgroup)
        activeSettings.talkgroup = activeTalkgroup
        dmr_core_set_talkgroup(core, UInt32(activeTalkgroup))
    }

    /// 切换收听的通话组。
    ///
    /// Homebrew 没有订阅指令，改这里只是**换目的地址 + 换本地过滤器**；
    /// 真正让 master 认这个组的，是随后那一次发射（`call(talkgroup:)`）。
    func setTalkgroup(_ talkgroup: Int) {
        let value = max(0, talkgroup)
        activeTalkgroup = value
        activeSettings.talkgroup = value
        dmr_core_set_talkgroup(core, UInt32(value))

        filteredFrames = 0
        serverTalkgroup = nil
        trafficStat.removeAll()
        trafficTotal = 0
        warnedNoTraffic = false
        lastTrafficReport = Date()

        // 旧组还挂着的通话要手动收尾：它之后的结束符会被过滤器挡掉。
        endStream(reason: nil)
        let now = Date()
        for index in calls.indices where calls[index].isActive {
            calls[index].isActive = false
            calls[index].updatedAt = now
        }
        currentSpeaker?.endedAt = now
        syncVoiceUI()

        if value > 0 {
            append(.info, "→ 目标 TG \(value)：会向它订阅一次；服务器推别的组时按设置决定播不播")
        } else {
            append(.info, "→ 收听全部通话组")
        }
    }

    // MARK: - 订阅（发一次静音 PTT）

    /// 向某个通话组发一次真实发射，让 BrandMeister 把它记成动态订阅。
    ///
    /// 这就是参考实现里「按一下话筒」那件事：DroidStar 的 `dmr_tgid_changed()`
    /// 只换了目的地址，真正让 master 认这个组的是随后那一帧语音头。
    func call(talkgroup: Int) {
        guard talkgroup > 0, talkgroup <= 0xFF_FFFF else { return }
        guard state == .online else {
            append(.info, "还没连上服务器：连上后会自动向 TG \(talkgroup) 订阅一次")
            return
        }
        guard !isTransmitting, txTimer == nil else {
            append(.info, "正在发射，等这次发完再订阅")
            return
        }

        let now = Date()
        if let last = lastSubscribeAt, lastSubscribeTalkgroup == talkgroup,
           now.timeIntervalSince(last) < 3 {
            return
        }
        lastSubscribeAt = now
        lastSubscribeTalkgroup = talkgroup
        talkgroupAliveAt = now

        let slot = UInt8(activeSettings.callSlot == 1 ? 1 : 2)
        let cc = UInt8(min(15, max(0, activeSettings.colorCode)))
        guard sendHeader(talkgroup: talkgroup, slot: slot, cc: cc) else { return }

        append(.info, "→ 订阅 TG \(talkgroup)（TS\(slot) CC\(cc)，\(subscribeBursts) 个语音突发 + 结束符，约 "
            + String(format: "%.1f", Double(subscribeBursts) * 0.06) + " 秒）")

        txKind = .subscribe
        txBurstsLeft = subscribeBursts
        startTxTimer()
    }

    // MARK: - 按住发射（PTT）

    func beginPtt(talkgroup: Int) {
        guard !isTransmitting else { return }
        guard state == .online else {
            append(.warning, "还没连上服务器，现在按 PTT 发不出去")
            return
        }
        guard talkgroup > 0 else {
            append(.warning, "先在通话组里填一个号码，PTT 才有地方发")
            return
        }
        guard txTimer == nil else {
            append(.warning, "正在订阅发射（约一秒），等它发完再按住 PTT")
            return
        }
        guard activeSettings.dmrId > 0 else {
            append(.warning, "DMR ID 还没设置，发射的源地址会是 0")
            return
        }

        pttFrames.removeAll(keepingCapacity: true)
        encoder.reset()

        // 采集一帧就排队，编码放到发射循环里做——编码要 2～3 ms，塞进采集回调会丢帧
        mic.onFrame = { [weak self] frame in
            guard let self else { return }
            self.pttFrames.append(frame)
            if self.pttFrames.count > 50 {
                self.pttFrames.removeFirst(self.pttFrames.count - 50)
            }
        }

        do {
            try mic.start()
        } catch {
            mic.onFrame = nil
            append(.error, "麦克风打不开：\(error.localizedDescription)")
            append(.info, "去「设置 → DMRPilot → 麦克风」确认权限；模拟器没有麦克风，只能在真机上试")
            return
        }

        let slot = UInt8(activeSettings.callSlot == 1 ? 1 : 2)
        let cc = UInt8(min(15, max(0, activeSettings.colorCode)))
        guard sendHeader(talkgroup: talkgroup, slot: slot, cc: cc) else {
            mic.onFrame = nil
            mic.stop()
            return
        }

        // 半双工：发射期间不播收到的语音，否则麦克风会把扬声器的声音再收进去。
        voice.isMuted = true
        isTransmitting = true
        txSeconds = 0
        txStartedAt = Date()
        append(.tx, "🔴 按住发射 → TG \(talkgroup)（TS\(slot)，CC\(cc)，DMR ID \(activeSettings.dmrId)）")

        txKind = .ptt
        startTxTimer()
    }

    func endPtt() {
        guard isTransmitting else { return }
        isTransmitting = false
        txLevel = 0
        mic.onFrame = nil
        mic.stop()

        if let started = txStartedAt {
            txSeconds = Date().timeIntervalSince(started)
        }
        finishTransmission(label: "⬛ 停止发射")
        voice.isMuted = !activeSettings.audioEnabled
        txStartedAt = nil
    }

    // MARK: - 发射（两条路径共用）

    /// 语音头。成功返回 true。
    private func sendHeader(talkgroup: Int, slot: UInt8, cc: UInt8) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = dmr_core_tx_begin(core, UInt32(talkgroup), slot, cc, &buffer, Int32(buffer.count))
        guard n == 55 else {
            append(.error, "核心没能生成语音头（返回 \(n)）")
            return false
        }
        send(Data(buffer[0..<55]), label: "DMRD 语音头 → TG \(talkgroup)")
        return true
    }

    private func sendBurst(_ codec: [UInt8], quiet: Bool) {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = codec.withUnsafeBufferPointer { pointer in
            dmr_core_tx_burst(core, pointer.baseAddress, &buffer, Int32(buffer.count))
        }
        guard n == 55 else { return }
        send(Data(buffer[0..<55]), label: "DMRD 语音突发", quiet: quiet)
    }

    private func sendSilenceBurst() {
        var codec = [UInt8](repeating: 0, count: 27)
        dmr_core_silence_codec(&codec)
        sendBurst(codec, quiet: true)
    }

    private func startTxTimer() {
        txTimer?.invalidate()
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.txTick() }
        }
        // .common：手指按在按钮上时主 runloop 处于 tracking 模式，默认模式不会触发。
        RunLoop.main.add(timer, forMode: .common)
        txTimer = timer
    }

    private func txTick() {
        switch txKind {
        case .subscribe:
            guard txBurstsLeft > 0 else {
                finishTransmission(label: "→ 订阅发射完成")
                return
            }
            txBurstsLeft -= 1
            sendSilenceBurst()
        case .ptt:
            txLevel = mic.level
            if let started = txStartedAt {
                txSeconds = Date().timeIntervalSince(started)
            }
            var frames = [[Int16]]()
            if pttFrames.count >= 3 {
                frames = Array(pttFrames.prefix(3))
                pttFrames.removeFirst(3)
            } else {
                frames = pttFrames
                pttFrames.removeAll(keepingCapacity: true)
            }
            // 采集还没跟上（刚按下那一刻）就补静音，别让突发序列断掉
            while frames.count < 3 {
                frames.append([Int16](repeating: 0, count: PttMicrophone.frameSamples))
            }
            sendBurst(encoder.encodeBurst(frames), quiet: true)
        }
    }

    /// 收尾：停节拍、发结束符。结束符不发的话服务器会占着这个时隙十几秒。
    private func finishTransmission(label: String) {
        txTimer?.invalidate()
        txTimer = nil

        if dmr_core_tx_active(core) == 1 {
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = dmr_core_tx_end(core, &buffer, Int32(buffer.count))
            if n == 55 {
                send(Data(buffer[0..<55]), label: "DMRD 语音结束符")
                // 再补一帧：丢一个也不会让时隙一直占着
                send(Data(buffer[0..<55]), label: "DMRD 语音结束符（重发）", quiet: true)
            }
        }
        append(.tx, label)
        txKind = .subscribe
        txBurstsLeft = 0
    }

    // MARK: - 语音偏好（界面实时改）

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

    /// 续订、订阅相关的设置在连接期间改了也要立刻生效，不必重连。
    func applyBehaviour(_ settings: Settings) {
        let slotChanged = activeSettings.callSlot != settings.callSlot
        let ccChanged = activeSettings.colorCode != settings.colorCode

        activeSettings.autoRenewTalkgroup = settings.autoRenewTalkgroup
        activeSettings.talkgroupRenewMinutes = settings.talkgroupRenewMinutes
        activeSettings.callSlot = settings.callSlot
        activeSettings.colorCode = settings.colorCode
        activeSettings.autoCallOnConnect = settings.autoCallOnConnect
        activeSettings.followServerTalkgroups = settings.followServerTalkgroups
        activeSettings.sendConfig = settings.sendConfig

        // 时隙和色码都只体现在「发出去的那几帧」里，改完不重新订阅等于没改。
        if slotChanged || ccChanged {
            dmr_core_set_color_code(core, UInt8(min(15, max(0, settings.colorCode))))
        }
        if (slotChanged || ccChanged), state == .online, activeTalkgroup > 0, txTimer == nil {
            lastSubscribeAt = nil
            let cc = min(15, max(0, settings.colorCode))
            let slot = settings.callSlot == 1 ? 1 : 2
            append(.info, "发射参数改为 TS\(slot) / CC\(cc)，重新向 TG \(activeTalkgroup) 订阅一次")
            call(talkgroup: activeTalkgroup)
        }
    }

    private func syncVoiceUI() {
        if isVoicePlaying != voice.isPlaying { isVoicePlaying = voice.isPlaying }
        if voiceLevel != voice.level { voiceLevel = voice.level }
        if voiceErrorCount != voice.lastErrorCount { voiceErrorCount = voice.lastErrorCount }
        if voicePackets != voice.decodedPackets { voicePackets = voice.decodedPackets }
    }

    // MARK: - 连接 / 断开

    func connect(with settings: Settings) {
        // 上一个会话可能还活着。不发 RPTCL 直接重登，master 会看到同一个 ID
        // 的两条连接，通常把新的那条关掉（MSTCL）。
        if state != .offline, connection != nil || webSocket != nil {
            append(.info, "先结束上一个会话（RPTCL），再重新登录")
            sendLogout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.beginConnect(with: settings)
            }
            return
        }
        beginConnect(with: settings)
    }

    private func beginConnect(with settings: Settings) {
        teardown()
        activeSettings = settings

        loginAttempt = 0
        refusals = 0
        unknownTags.removeAll()
        activeTalkgroup = settings.talkgroup
        filteredFrames = 0
        trafficStat.removeAll()
        trafficTotal = 0
        warnedNoTraffic = false
        lastTrafficReport = Date()
        rxFrames = 0
        txFrames = 0
        lastProblem = nil
        serverTalkgroup = nil
        talkgroupAliveAt = nil
        lastSubscribeAt = nil
        lastSubscribeTalkgroup = nil

        voice.reset()
        voice.volume = Float(settings.audioVolume)
        voice.isMuted = !settings.audioEnabled
        syncVoiceUI()

        guard settings.dmrId > 0, !settings.sanitizedPassword.isEmpty else {
            state = .failed("请先在设置里填写 DMR ID 与 Hotspot 密码")
            append(.error, "身份信息不完整：DMR ID 与 Hotspot 密码不能为空")
            return
        }

        if settings.usesEssid && settings.dmrId > 42_949_672 {
            state = .failed("DMR ID 过大：ESSID 需要 7 位 ID，不是 9 位热点 ID")
            append(.error, "ESSID 换算会溢出：DMR ID 应填 7 位编号")
            return
        }

        applyCoreConfiguration(settings)

        state = .connecting
        append(.info, "开始连接 \(settings.host):\(settings.port)（\(settings.transport.short)）")
        append(.info, "登录 ID \(settings.hotspotId)"
            + (settings.hotspotIdOverride >= 10_000_000 ? "（设置里直接指定）" : settings.usesEssid ? "（DMR ID + ESSID 后缀）" : "（没填 ESSID，多数服务器不认）"))
        if settings.sendConfig {
            append(.info, "握手：RPTL → RPTK → RPTC → RPTPING（与参考实现 DroidStar 一致）")
        } else {
            append(.info, "握手：RPTL → RPTK（跳过 RPTC，只给不接受配置包的服务器用）")
        }

        switch settings.transport {
        case .udp: startUDP()
        case .websocket: startWebSocket()
        }
    }

    /// 把设置灌进 C++ 核心。数值和字符串分开传，避免 Swift 侧嵌套 withCString。
    private func applyCoreConfiguration(_ settings: Settings) {
        var setup = dmr_setup_t()
        setup.essid = UInt32(clamping: settings.hotspotId)
        setup.dmr_id = UInt32(clamping: settings.dmrId)
        setup.frequency = 438_800_000
        setup.color_code = UInt8(min(15, max(0, settings.colorCode)))
        setup.send_config = settings.sendConfig ? 1 : 0
        dmr_core_set_params(core, &setup)

        dmr_core_set_text(core, DMR_TEXT_PASSWORD, settings.sanitizedPassword)
        dmr_core_set_text(core, DMR_TEXT_CALLSIGN, settings.normalizedCallsign.isEmpty ? "N0CALL" : settings.normalizedCallsign)
        dmr_core_set_talkgroup(core, UInt32(max(0, settings.talkgroup)))
    }

    func disconnect() {
        let wasActive = (state != .offline)
        if wasActive {
            sendLogout()
            append(.info, "已断开连接")
        }
        state = .offline

        // 给 UDP 一点时间把 RPTCL 真正发出去，再拆 socket。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.state == .offline else { return }
            self.teardown()
        }
    }

    func clearLog() {
        entries.removeAll()
    }

    // MARK: - 传输层

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

    // MARK: - 建链

    private func sendLogin() {
        loginAttempt += 1
        guard loginAttempt <= 3 else {
            fail("服务器连续 3 次没有回应登录请求（RPTL）")
            return
        }
        state = .loggingIn
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = dmr_core_login(core, &buffer, Int32(buffer.count))
        guard n > 0 else {
            fail("协议核心没能生成 RPTL（热点 ID \(activeSettings.hotspotId)）", allowRetry: false)
            return
        }
        append(.info, "→ RPTL 登录请求（第 \(loginAttempt) 次），热点 ID \(activeSettings.hotspotId)")
        send(Data(buffer[0..<Int(n)]), label: "RPTL")
        armLoginTimeout()
    }

    private func sendPing() {
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = dmr_core_ping(core, &buffer, Int32(buffer.count))
        guard n > 0 else { return }
        send(Data(buffer[0..<Int(n)]), label: "RPTPING", quiet: true)
    }

    private func sendLogout() {
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = dmr_core_logout(core, &buffer, Int32(buffer.count))
        guard n > 0 else { return }
        send(Data(buffer[0..<Int(n)]), label: "RPTCL 主动登出")
    }

    // MARK: - 入站分发

    private func handleInbound(_ data: Data) {
        lastServerPacket = Date()

        var result = dmr_result_t()
        let event = data.withUnsafeBytes { raw -> Int32 in
            let pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return dmr_core_receive(core, pointer, Int32(data.count), &result)
        }

        switch event {
        case DMR_EVT_AUTH:
            loginTimer?.cancel()
            state = .authenticating
            append(.info, "← RPTACK 收到挑战盐，→ RPTK 鉴权")
            sendResult(result, label: "RPTK")
            armLoginTimeout()

        case DMR_EVT_CONFIG:
            loginTimer?.cancel()
            state = .configuring
            append(.info, "← RPTACK 鉴权通过，→ RPTC 上报配置（302 字节）")
            sendResult(result, label: "RPTC")
            armLoginTimeout()

        case DMR_EVT_CONNECTED:
            goOnline()

        case DMR_EVT_NAK, DMR_EVT_CLOSED:
            handleRefused(event == DMR_EVT_CLOSED ? "MSTCL" : "MSTNAK")

        case DMR_EVT_PONG:
            append(.rx, "← MSTPONG")

        case DMR_EVT_RX_HEADER, DMR_EVT_RX_VOICE, DMR_EVT_RX_EOT, DMR_EVT_RX_OTHER:
            handleDmrFrame(event: event, result: result)

        default:
            logUnknown(data)
        }
    }

    private func sendResult(_ result: dmr_result_t, label: String) {
        let count = Int(result.out_len)
        guard count > 0 else { return }
        let payload = withUnsafeBytes(of: result.out) { Data(bytes: $0.baseAddress!, count: count) }
        send(payload, label: label)
    }

    /// 服务器拒绝 / 关闭会话。两种情况的处理一样：等几秒重登，超过次数就停下来说清楚。
    private func handleRefused(_ name: String) {
        append(.warning, "← \(name)：服务器拒绝或关闭了这个会话（阶段：\(state.label)）")

        refusals += 1

        guard refusals <= 2 else {
            fail("会话被服务器反复关闭（\(name)）：核对 9 位热点 ID 与 SelfCare 里是否一致；"
                + "如果另一台设备（手机 MMDVM / 盒子）也用这个 ID，先把它断开", allowRetry: false)
            return
        }
        retryLater(after: 5, message: "5 秒后重新登录（第 \(refusals) 次）")
    }

    private func goOnline() {
        loginTimer?.cancel()
        loginTimer = nil
        guard state != .online else { return }

        state = .online
        connectedSince = Date()
        loginAttempt = 0
        refusals = 0
        append(.info, "✅ 已登录，进入在线状态，每 \(Int(pingInterval)) 秒发一次 RPTPING")
        startTimers()
        verifyHotspotRegistration()

        // 连上就向当前 TG 订阅一次：不发的话服务器只会推 SelfCare 里的静态组。
        if activeSettings.autoCallOnConnect, activeSettings.talkgroup > 0 {
            let talkgroup = activeSettings.talkgroup
            Task { [weak self] in
                // 等 2 秒再发射：刚上线时 master 那边可能还没把这个 peer 登记完，
                // 第一帧会被丢掉（DroidStar 是人工按键，天然避开这个窗口）。
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.state == .online, self.txTimer == nil else { return }
                self.call(talkgroup: talkgroup)
            }
        } else if activeSettings.autoCallOnConnect {
            append(.info, "没有设置通话组，跳过自动订阅")
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
        case .loggingIn, .authenticating:
            if loginAttempt < 3 {
                append(.warning, "登录超时，重试")
                sendLogin()
            } else {
                fail("登录超时：检查服务器地址、端口与网络")
            }
        case .configuring:
            fail("服务器没有回应配置包（RPTC）：到「设置 → 服务器」关掉「上报配置包 RPTC」再连一次", allowRetry: false)
        default:
            break
        }
    }

    /// 不判失败、保持「连接中」的延迟重连，UI 不会闪一下红色的失败态。
    private func retryLater(after seconds: Double, message: String) {
        append(.info, message)
        teardown()
        state = .connecting

        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.state != .online else { return }
                self.connect(with: self.activeSettings)
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - 定时器

    private func startTimers() {
        pingTimer?.invalidate()
        let ping = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .online else { return }
                self.sendPing()
            }
        }
        RunLoop.main.add(ping, forMode: .common)
        pingTimer = ping

        tickTimer?.invalidate()
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    private func tick() {
        guard state == .online else { return }

        // 心跳超时 = 链路断了（DroidStar 靠 rxwatchdog 判 STREAM_LOST，这里按整条链路判）
        if let lastServerPacket, Date().timeIntervalSince(lastServerPacket) > silenceTimeout {
            fail("心跳超时：\(Int(silenceTimeout)) 秒没有收到服务器任何数据")
            return
        }

        // 收流看门狗：语音头之后 2 秒没有新帧，就当作这一句结束了。
        // 部分 master 不推结束符，没有这一步通话会永远挂在「讲话中」。
        if let lastFrameAt = streamLastFrameAt, Date().timeIntervalSince(lastFrameAt) > streamTimeout {
            endStream(reason: "语音中断（\(Int(streamTimeout)) 秒没有新帧）")
        }

        reportTraffic()
        renewTalkgroupIfIdle()
    }

    // MARK: - DMR 帧处理

    private func handleDmrFrame(event: Int32, result: dmr_result_t) {
        rxFrames += 1
        lastHeard = Date()

        let src = Int(result.src)
        let dst = Int(result.dst)
        let slot = Int(result.slot)
        let isPrivate = result.is_private != 0
        let key = "\(src)-\(dst)-\(slot)"

        // 服务器实际在推哪个组 —— 这个值经常不等于界面上选的那个。
        if !isPrivate, serverTalkgroup != dst { serverTalkgroup = dst }
        trafficStat["\(dst)@\(slot)", default: 0] += 1
        trafficTotal += 1
        warnedNoTraffic = false

        // 默认跟随服务器：推什么就播什么（DroidStar 的接收侧就是这么做的）。
        // 只有显式关掉「跟随」时才按选中的 TG 过滤。
        if !activeSettings.followServerTalkgroups, activeTalkgroup > 0, !isPrivate, dst != activeTalkgroup {
            filteredFrames += 1
            return
        }

        talkgroupAliveAt = Date()
        streamLastFrameAt = Date()

        switch event {
        case DMR_EVT_RX_HEADER:
            beginStream(key: key, src: src, dst: dst, slot: slot, isPrivate: isPrivate, at: Date())
            append(.rx, "通话开始 \(src) → \(dst)　\(isPrivate ? "单呼" : "组呼")　TS\(slot)")

        case DMR_EVT_RX_EOT:
            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                calls[index].updatedAt = Date()
                calls[index].isActive = false
                append(.rx, "通话结束 \(src) → \(dst)（\(Fmt.duration(calls[index].duration))，\(calls[index].frames) 帧）")
            }
            endStream(reason: nil)

        case DMR_EVT_RX_VOICE:
            if streamKey != key {
                // 没收到语音头（连上时对方已经在说，或头丢了）—— 直接接上。
                beginStream(key: key, src: src, dst: dst, slot: slot, isPrivate: isPrivate, at: Date())
            }
            let codec = withUnsafeBytes(of: result.codec) { Array($0) }
            voice.push(key: key, codec: codec)
            syncVoiceUI()
            trackSpeaker(src: src, dst: dst, slot: slot, isPrivate: isPrivate, at: Date())

            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                calls[index].frames += 1
                calls[index].updatedAt = Date()
            } else {
                calls.insert(makeCall(src: src, dst: dst, slot: slot, isPrivate: isPrivate, key: key), at: 0)
                trimCalls()
            }

        default:
            append(.rx, "← DMRD 控制帧 类型 \(result.data_type)（\(src) → \(dst)）")
        }
    }

    private func beginStream(key: String, src: Int, dst: Int, slot: Int, isPrivate: Bool, at date: Date) {
        if streamKey != key {
            if let previous = streamKey {
                voice.end(key: previous)
            }
            streamKey = key
            // 旧的同 key 通话先收尾，避免同一个流号出现两条「通话中」
            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                calls[index].isActive = false
                calls[index].updatedAt = date
            }
            calls.insert(makeCall(src: src, dst: dst, slot: slot, isPrivate: isPrivate, key: key), at: 0)
            trimCalls()
            voice.begin(key: key)
        }
        streamLastFrameAt = date
        trackSpeaker(src: src, dst: dst, slot: slot, isPrivate: isPrivate, at: date)
        syncVoiceUI()
    }

    private func endStream(reason: String?) {
        if let key = streamKey {
            voice.end(key: key)
        }
        streamKey = nil
        streamLastFrameAt = nil
        if let reason {
            append(.rx, reason)
        }
        currentSpeaker?.endedAt = currentSpeaker?.endedAt ?? Date()
        syncVoiceUI()
    }

    private func trackSpeaker(src: Int, dst: Int, slot: Int, isPrivate: Bool, at date: Date) {
        if var speaker = currentSpeaker,
           speaker.src == src, speaker.dst == dst, speaker.slot == slot, speaker.endedAt == nil,
           date.timeIntervalSince(speaker.lastVoiceAt) < 3 {
            speaker.lastVoiceAt = date
            currentSpeaker = speaker
            return
        }
        currentSpeaker = ActiveSpeaker(src: src, dst: dst, slot: slot, isPrivate: isPrivate,
                                       startedAt: date, lastVoiceAt: date, endedAt: nil)
    }

    private func makeCall(src: Int, dst: Int, slot: Int, isPrivate: Bool, key: String) -> LiveCall {
        let now = Date()
        return LiveCall(id: key, src: src, dst: dst, slot: slot, isPrivate: isPrivate,
                        frames: 1, startedAt: now, updatedAt: now, isActive: true)
    }

    private func trimCalls() {
        if calls.count > 40 {
            calls.removeLast(calls.count - 40)
        }
    }

    private func logUnknown(_ data: Data) {
        guard data.count >= 4,
              let tag = String(bytes: data.prefix(4), encoding: .ascii) else { return }
        guard !unknownTags.contains(tag) else { return }
        unknownTags.insert(tag)
        append(.rx, "← 未处理的命令 \(tag)（\(data.count) 字节），后续同类不再提示", hex: data.hexDump)
    }

    // MARK: - 流量摘要 / 续订

    /// 每 15 秒把「服务器在推哪些组」汇总一行。
    ///
    /// 这一行是排查「收不到语音」最关键的证据：摘要里就有选中的组 = 订阅是好的，
    /// 只是刚才没人说话；全是别的组 = 订阅没落在这个热点上。
    private func reportTraffic() {
        guard trafficTotal > 0 else {
            let idle = Date().timeIntervalSince(lastTrafficReport)
            guard idle >= 30, !warnedNoTraffic else { return }
            warnedNoTraffic = true
            lastTrafficReport = Date()
            append(.warning, "30 秒内没收到任何 DMRD：服务器没向这个热点推流量，"
                + "要么订阅没建立，要么这个组这段时间没人讲话")
            return
        }

        let elapsed = Date().timeIntervalSince(lastTrafficReport)
        guard elapsed >= 15 else { return }

        let target = activeTalkgroup
        let sorted = trafficStat.sorted { $0.value > $1.value }
        let mine = target > 0 ? sorted.filter { $0.key.hasPrefix("\(target)@") } : []
        let rest = target > 0 ? sorted.filter { !$0.key.hasPrefix("\(target)@") } : sorted
        let items = (mine + rest).prefix(4).map { entry -> String in
            let parts = entry.key.split(separator: "@")
            let dst = parts.first.map { String($0) } ?? entry.key
            let slot = parts.count > 1 ? String(parts[1]) : "?"
            let mark = (target > 0 && dst == String(target)) ? " ← 当前组" : ""
            return "\(dst)(TS\(slot))×\(entry.value)\(mark)"
        }.joined(separator: "、")

        let filtered = filteredFrames > 0 ? "，其中累计 \(filteredFrames) 帧按设置丢弃" : ""
        append(.rx, "近期流量 \(Int(elapsed))s：\(items)，共 \(trafficTotal) 帧\(filtered)")

        trafficStat.removeAll()
        trafficTotal = 0
        warnedNoTraffic = false
        lastTrafficReport = Date()
    }

    /// 动态 TG 静默太久会被 BrandMeister 释放，静默超时就再订一次。
    private func renewTalkgroupIfIdle() {
        let target = serverTalkgroup ?? activeTalkgroup
        guard target > 0, state == .online, txTimer == nil else { return }
        guard activeSettings.autoCallOnConnect, activeSettings.autoRenewTalkgroup else { return }

        guard let aliveAt = talkgroupAliveAt else {
            talkgroupAliveAt = Date()
            return
        }
        let minutes = max(1, activeSettings.talkgroupRenewMinutes)
        guard Date().timeIntervalSince(aliveAt) >= Double(minutes) * 60 else { return }

        append(.info, "TG \(target) 已静默 \(Int(Date().timeIntervalSince(aliveAt) / 60)) 分钟，自动续订动态订阅")
        call(talkgroup: target)
    }

    // MARK: - 上线后核对设备

    private func verifyHotspotRegistration() {
        let id = activeSettings.hotspotId
        guard activeSettings.host.lowercased().contains("brandmeister") else { return }

        Task { [weak self] in
            do {
                let device = try await BrandMeisterAPI().device(id)
                guard let self else { return }
                let callsign = device.callsign ?? "未知呼号"
                self.append(.info, "BM 设备库核对：\(id) = \(callsign)")
            } catch {
                guard let self else { return }
                self.append(.warning, "BM 设备库查不到 \(id)：这个 ID 不是已注册热点。"
                    + "去 SelfCare → My Hotspots 看一眼真实的 9 位号码，直接填进「自定义热点 ID」最稳")
            }
        }
    }

    // MARK: - 发送 / 收尾

    private func send(_ data: Data, label: String, quiet: Bool = false) {
        guard state != .offline else { return }
        txFrames += 1
        if !quiet { append(.tx, "→ \(label)", hex: data.hexDump) }

        switch activeSettings.transport {
        case .udp:
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, self.state == .online else { return }
                    self.fail("发送失败：\(error.localizedDescription)")
                }
            })
        case .websocket:
            webSocket?.send(.data(data)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, self.state == .online else { return }
                    self.fail("发送失败：\(error.localizedDescription)")
                }
            }
        }
    }

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
        pingTimer?.invalidate()
        pingTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        loginTimer?.cancel()
        loginTimer = nil
        loginToken += 1
        retryWork?.cancel()
        retryWork = nil

        txTimer?.invalidate()
        txTimer = nil
        txBurstsLeft = 0
        dmr_core_reset(core)

        mic.onFrame = nil
        mic.stop()
        isTransmitting = false
        txLevel = 0
        pttFrames.removeAll(keepingCapacity: false)

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        webSocketSession?.invalidateAndCancel()
        webSocketSession = nil

        voice.reset()
        voice.isMuted = !activeSettings.audioEnabled
        syncVoiceUI()

        streamKey = nil
        streamLastFrameAt = nil
        currentSpeaker = nil
        serverTalkgroup = nil
        talkgroupAliveAt = nil
        trafficStat.removeAll()
        trafficTotal = 0

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
