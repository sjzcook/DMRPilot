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

    /// 手上是不是还握着一条会话：UDP socket / WebSocket 还在，或者状态不是 offline。
    ///
    /// 换协议、换呼叫类型时要判断的是这个，而不是 `state`——`disconnect()` 会立刻把状态
    /// 置成 `.offline`，但真正拆 socket 还要等 0.25 秒把 RPTCL 发出去；那段时间里
    /// `state == .offline` 却仍然连着，只看状态会漏判。
    var hasSession: Bool {
        connection != nil || webSocket != nil || state != .offline
    }

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
    /// 显式切组之后锁定的收听目标：只有这个组的语音会被播放，其它组的下行帧直接丢掉。
    /// 0 = 不锁，按「跟随服务器下发」的设置来。
    ///
    /// 为什么需要它：BrandMeister 的 Homebrew 通道**没有退订指令**，换组之后 master
    /// 还会继续把旧组推下来（直到动态订阅静默超时），协议层停不掉，只能本地丢掉。
    @Published private(set) var listenLock = 0
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

    /// 日志页的「清空」：内存里已经结束的记录扔掉，正在说的那句保持不动；
    /// 落盘的 SQLite 表也一起清掉（否则日志页一刷新又都回来了）。
    func clearCallLog() {
        calls.removeAll { !$0.isActive }
        CallLogStore.shared.clear()
    }

    // MARK: - 协议核心

    /// C++ 核心：握手状态机 + 组帧 / 拆帧。
    private let core = dmr_core_create()!
    /// BrandMeister 的 ODTP / Rewind 核心。和 `core` 是两套互不相通的协议，
    /// 同一时刻只用其中一个，由 `settings.linkProtocol` 决定。
    private let rw = rw_core_create()!
    /// YSF（System Fusion）反射器核心。首页右上角模式切到 YSF 时走这一条，
    /// 和 DMR 的 `core` / `rw` 也是互斥的。
    private let ysf = ysf_core_create()!

    // MARK: - 内部状态

    private var activeSettings = Settings()

    /// 当前是否走 BrandMeister 的 ODTP（Rewind）而不是 Homebrew。
    /// ODTP 没有时隙、没有色码，订阅是显式命令；Homebrew 三者都要自己凑。
    ///
    /// YSF 模式下这两个分支都必须让位：YSF 既没有 DMR ID 鉴权，也没有订阅概念，
    /// 一旦被当成 ODTP 处理就会去发 KEEP_ALIVE，把状态机搅乱。
    private var isYsf: Bool { activeSettings.homeMode == .ysf }
    private var isOdtp: Bool { !isYsf && activeSettings.linkProtocol == .odtp }
    private var isHomebrew: Bool { !isYsf && activeSettings.linkProtocol != .odtp }
    private var connection: NWConnection?
    private var webSocket: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?

    private var pingTimer: Timer?
    private var tickTimer: Timer?
    /// 锁屏卡片 / 灵动岛的 1 秒节拍（见 `syncLiveActivity()`）。
    private var liveTimer: Timer?
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
    /// YSF 当前这一路的「源 / 目的呼号」。
    ///
    /// 包头里那两段字段不可靠（有的反射器留空或填网关呼号），DCH 又只在 FN=0/1 才带，
    /// 所以解出非空值就记下来，后面没带信令的包继续用，流的键也从这里拼。
    private var ysfSource = ""
    private var ysfDest = ""
    /// 每次连接只打一次「第一包 YSF 语音」的体检结论（见 `handleYsfFrame`）。
    /// 排查「有收帧没声音」时，这一行能直接分辨是解码出了静音，还是根本没走到解码。
    private var ysfProbeLogged = false

    /// 按下 PTT 的那一刻，本地是不是正在收一路语音。
    ///
    /// 用来判断「本来在收听，被我这一句话打断之后要不要把订阅重新挂回去」
    /// （见 `restoreReceptionAfterPtt`）。不看这个的话，每次松手都补一次订阅太吵。
    private var receivingBeforePtt = false

    // MARK: - 发射状态

    private enum TxKind {
        /// 向某个通话组发一次「静音 PTT」，让服务器记成动态订阅（仅 Homebrew 需要）
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
    /// 忙着发射时被推迟的订阅目标：结束符发完后补一次（换组时旧组已退，不能漏订）。
    private var pendingSubscribeTalkgroup: Int?
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
    private var audioErrorReported = false

    private let pingInterval: TimeInterval = 5
    private let silenceTimeout: TimeInterval = 15
    /// 一次订阅发射发多少个语音突发（60 ms 一个）。12 个 ≈ 0.75 秒，接近真人按一下话筒。
    private let subscribeBursts = 12

    // MARK: - 生命周期

    init() {
        voice.volume = Float(activeSettings.audioVolume)
        // 播放链路自己做的自愈（重建 / 队列卡死）都写进日志：现场复现「没声音」时，
        // 这几行能直接分辨是引擎被系统停了、还是根本没走到解码。
        voice.onEvent = { [weak self] text in
            self?.append(.info, text)
        }
        // RPTC 里那几项资料字段，DroidStar 是写死的，这里给个正经值。
        dmr_core_set_text(core, DMR_TEXT_LOCATION, "EasyDMR")
        dmr_core_set_text(core, DMR_TEXT_DESCRIPTION, "EasyDMR iOS")
        dmr_core_set_text(core, DMR_TEXT_URL, "https://brandmeister.network")
        dmr_core_set_text(core, DMR_TEXT_SOFTWARE, "20260101")
        dmr_core_set_text(core, DMR_TEXT_PACKAGE, "EasyDMR_iOS")

        rw_core_set_version(rw, "EasyDMR 1.0")
        // YSF 的组呼目的地址就是 "ALL"（反射器按它分发到所有接入的电台）
        ysf_core_set_destination(ysf, "ALL")
    }

    deinit {
        dmr_core_destroy(core)
        rw_core_destroy(rw)
        ysf_core_destroy(ysf)
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
    /// 前后不同时是一次完整的「换台」：停掉正在播的旧组、退掉旧组订阅、向新组订阅一次，
    /// 并把本地过滤器收紧到新组（`listenLock`），此后旧组的语音一律不再播放。
    ///
    /// Homebrew 没有订阅指令，改这里只是**换目的地址 + 换本地过滤器**；
    /// 真正让 master 认这个组的，是随后那一次发射（`call(talkgroup:)`）。
    func setTalkgroup(_ talkgroup: Int) {
        let value = max(0, talkgroup)

        // YSF 没有通话组：界面已经隐藏了选择器，这里只更新一下记录，不发任何东西。
        if isYsf {
            activeTalkgroup = value
            activeSettings.talkgroup = value
            return
        }
        let previous = activeTalkgroup
        let changed = previous != value

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
        // 解码队列里可能还排着旧组几十毫秒的 PCM，清掉队列，切完立刻静音。
        // （解码器和统计保留：设置页那个「已解码 N 包」不该因为换台归零。）
        voice.flush()
        let now = Date()
        for index in calls.indices where calls[index].isActive {
            closeCall(index, at: now)
        }
        currentSpeaker?.endedAt = now
        syncVoiceUI()

        // 换台：先退掉旧组的订阅，再把收听范围锁到新组。
        if changed {
            cancelSubscription(for: previous)
            // ODTP 的 CANCELLING 是「退订全部」：刚退完必须让后面那次 `call()` 真的发出去。
            // `call()` 有一条 3 秒去重（`lastSubscribeAt`），A→B→A 这样快速来回切的时候
            // 第二次回 A 会被它挡掉 —— 退订发了、订阅没发，等于**一个组都不剩**，
            // 现场就是「切了一下组，从此收不到任何东西」。这里把去重记录清掉。
            if isOdtp {
                lastSubscribeAt = nil
                lastSubscribeTalkgroup = nil
            }
        }
        listenLock = value

        if value > 0 {
            append(.info, "→ 目标 TG \(value)：已切换，其它组的语音不再播放")
        } else {
            append(.info, "→ 收听全部通话组")
        }
    }

    /// 换组时把旧组的订阅退掉。
    ///
    /// ODTP 有真正的 `CANCELLING`（退订全部），发出去之后 master 就不再推旧组；
    /// Homebrew 协议里没有退订，动态订阅只能等服务器静默释放（约 10 分钟），
    /// 这段时间旧组照样会推下来——`listenLock` 会在本地把它丢掉，一声都不放。
    private func cancelSubscription(for previous: Int) {
        guard previous > 0 else { return }
        guard state == .online else {
            append(.info, "旧组 TG \(previous)：还没连上，服务器那边没有要退的订阅")
            return
        }

        if isOdtp {
            var buffer = [UInt8](repeating: 0, count: 32)
            let n = rw_core_cancel(rw, &buffer, Int32(buffer.count))
            guard n > 0 else { return }
            send(Data(buffer[0..<Int(n)]), label: "CANCELLING（退订全部）")
            append(.info, "→ 已退订旧组 TG \(previous)（ODTP CANCELLING）")
        } else {
            append(.info, "旧组 TG \(previous)：Homebrew 没有退订指令，"
                + "服务器要等动态订阅静默超时才释放，本地从现在起不再播放它")
        }
    }

    // MARK: - 订阅（发一次静音 PTT）

    /// 向某个通话组发一次真实发射，让 BrandMeister 把它记成动态订阅。
    ///
    /// 这就是参考实现里「按一下话筒」那件事：DroidStar 的 `dmr_tgid_changed()`
    /// 只换了目的地址，真正让 master 认这个组的是随后那一帧语音头。
    func call(talkgroup: Int) {
        // YSF 是「连上就收全部」的反射器，没有组可以订阅，也不该白发一次静音发射。
        guard !isYsf else { return }
        guard talkgroup > 0, talkgroup <= 0xFF_FFFF else { return }
        guard state == .online else {
            append(.info, "还没连上服务器：连上后会自动向 TG \(talkgroup) 订阅一次")
            return
        }
        guard !isTransmitting, txTimer == nil else {
            // 正在发射（订阅那 0.75 秒的静音 PTT，或者用户正在说话）：记下来，
            // 等结束符发完再补订。换组时这一步很关键 —— 旧组已经退了，
            // 新组订不上就等于两头都听不到。
            pendingSubscribeTalkgroup = talkgroup
            append(.info, "正在发射，等这次发完再向 TG \(talkgroup) 订阅")
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

        // ODTP 有真正的订阅命令，不需要「发一次静音发射」来让服务器记事。
        if isOdtp {
            sendSubscribe(talkgroup: talkgroup)
            return
        }

        let slot = UInt8(activeSettings.callSlot == 1 ? 1 : 2)
        let cc = UInt8(min(15, max(0, activeSettings.colorCode)))
        guard sendHeader(destination: talkgroup, slot: slot, cc: cc) else { return }

        append(.info, "→ 订阅 TG \(talkgroup)（TS\(slot) CC\(cc)，\(subscribeBursts) 个语音突发 + 结束符，约 "
            + String(format: "%.1f", Double(subscribeBursts) * 0.06) + " 秒）")

        txKind = .subscribe
        txBurstsLeft = subscribeBursts
        startTxTimer()
    }

    // MARK: - 按住发射（PTT）

    /// 开始一次按住发射。
    ///
    /// `destination` 是这一次的目的地址：组呼是通话组号（TG），单呼是对方 7 位 DMR ID。
    /// 两者在协议上只差 LC 的 FLCO，所以这里不分支，只把 `isPrivate` 一路传到建帧那一层。
    func beginPtt(destination: Int, isPrivate: Bool = false) {
        guard !isTransmitting else { return }

        // 记下「按之前到底有没有在收听」：收尾后要用它决定要不要把订阅重新挂回去。
        // 这一行必须放在最前面 —— 下面的 `voice.isMuted = true` 不会动 `streamKey`，
        // 但发射过程里对方有可能推结束符，晚了就判断不出来了。
        receivingBeforePtt = streamKey != nil

        // YSF 没有通话组、没有时隙色码：走另一条更短的发射路径。
        if isYsf {
            beginYsfPtt()
            return
        }

        guard state == .online else {
            append(.warning, "还没连上服务器，现在按 PTT 发不出去")
            return
        }
        guard destination > 0 else {
            append(.warning, isPrivate
                   ? "先填对方的 DMR ID，单呼才有地方发"
                   : "先在通话组里填一个号码，PTT 才有地方发")
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
        // 增益在采集端做（见 `PttMicrophone.consume`），这里只把设置里的 dB 换算过去。
        mic.gain = PttMicrophone.linearGain(db: activeSettings.micGainDb)
        mic.autoGain = activeSettings.micAutoGain

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
            append(.info, "去「设置 → EasyDMR → 麦克风」确认权限；模拟器没有麦克风，只能在真机上试")
            return
        }

        let slot = UInt8(activeSettings.callSlot == 1 ? 1 : 2)
        let cc = UInt8(min(15, max(0, activeSettings.colorCode)))
        guard sendHeader(destination: destination, slot: slot, cc: cc, isPrivate: isPrivate) else {
            mic.onFrame = nil
            mic.stop()
            return
        }

        // 半双工：发射期间不播收到的语音，否则麦克风会把扬声器的声音再收进去。
        voice.isMuted = true
        isTransmitting = true
        txSeconds = 0
        txStartedAt = Date()
        append(.tx, "🔴 按住发射 → " + Self.destinationText(destination, isPrivate: isPrivate) + "（"
            + (isOdtp ? "ODTP" : "TS\(slot) CC\(cc)")
            + "，DMR ID \(activeSettings.dmrId)）")

        txKind = .ptt
        startTxTimer()
    }

    func endPtt() {
        guard isTransmitting else { return }
        isTransmitting = false
        txLevel = 0
        mic.onFrame = nil
        mic.stop()

        // 采集电平体检。这一行是用来分流「对端说声音小」的：
        // - 输入峰值只有一两百（-45 dBFS 以下）→ 麦克风几乎没收到声，是遮挡 / 路由问题，
        //   再大的增益也救不回来（`hint` 会提示）；
        // - 输入峰值正常（-30~-20 dBFS）而自动增益已经顶到 ×24 —— 说明增益给足了，
        //   对端还嫌小就是编码器那侧的电平标定偏了（`HREncoder.calibrateIfNeeded`）。
        // 手动增益没算进「补到」那一项，它是在自动增益之后叠加的用户微调。
        let peak = Double(mic.lastPeak)
        let auto = mic.lastAutoGain
        let inputDb = peak > 1 ? 20 * log10(peak / 32768) : -120
        let outputDb = inputDb + 20 * log10(Double(auto))
        let hint = peak < 200 ? "，麦克风几乎没收到声音（检查是否被遮挡 / 外接设备占用）" : ""
        append(.info, String(format: "🎙️ 采集电平：输入峰值 %.0f（%.0f dBFS），自动增益 ×%.1f → 约 %.0f dBFS%@",
                             peak, inputDb, auto, outputDb, hint))

        if let started = txStartedAt {
            txSeconds = Date().timeIntervalSince(started)
        }
        finishTransmission(label: "⬛ 停止发射")
        // 发射把对方的呼叫打断了，服务器那边这条连接可能就不再推语音了 —— 收尾时
        // 把收听重新挂回去（只在「按之前确实在收」的时候做）。
        restoreReceptionAfterPtt()
        // 解静音 + 把播放链路整条重建。只翻 `isMuted` 是不够的：发射期间播放引擎
        // 被系统停过一次，`engine.isRunning` 常常还写着 true（僵尸态），
        // 缓冲排进去既不出声也不回调，队列堆满之后每个包都被静默丢掉。
        voice.endTransmission(audioEnabled: activeSettings.audioEnabled)
        append(.info, "🎧 收尾检查：\(voice.diagnostics)")
        txStartedAt = nil
    }

    /// 发射结束后把「收听」重新挂回去。
    ///
    /// 现场：有人讲话时按一下 PTT，松手之后既没有声音、也不再有任何新帧（`rxFrames`、
    /// 通话列表全停住）。本地这条收流链路**不依赖发射状态**（`rw_core_tx_*` 只发不算，
    /// `handleInbound` / `handleDmrFrame` 里也没有任何 `isTransmitting` 分支），
    /// 所以只剩两种可能：
    ///
    /// 1. 帧真的没来 —— 终端在 BrandMeister 上是一条半双工会话，我们这句话把对方的
    ///    呼叫顶掉之后，服务器不再往这条连接推语音；
    /// 2. 帧来了但被本地按 dst 丢掉 —— 见 `handleDmrFrame` 里 `dst > 0` 那条注释。
    ///
    /// 第 1 种只能靠「重新订阅」救：ODTP 的订阅是显式命令，一个包就能挂回去，
    /// 服务器回一个空确认而已，不会打断正在进行的呼叫。Homebrew 没有订阅指令，
    /// 重新挂要靠一次真实的静音发射（0.75 秒），代价太大，这里不做，只留日志。
    private func restoreReceptionAfterPtt() {
        guard receivingBeforePtt else { return }
        receivingBeforePtt = false
        guard state == .online else { return }

        if isOdtp {
            // 收听范围优先用 `listenLock`（用户点过的那一组），它才是服务器实际在推的。
            let target = listenLock > 0 ? listenLock : activeTalkgroup
            guard target > 0 else { return }
            guard sendSubscribe(talkgroup: target) else { return }
            append(.info, "↺ 发射结束，重新向 TG \(target) 订阅一次（把收听挂回来）")
        } else if isHomebrew {
            append(.info, "↺ 发射结束：Homebrew 没有订阅指令，如果对方之后不再出声，"
                + "等服务器下发或手动点一次通话组重新订阅")
        }
    }

    // MARK: - 发射（两条路径共用）

    // MARK: - YSF 发射

    /// YSF 的按住发射：语音头 → 每 100 ms 一包（5 帧）→ 结束符。
    ///
    /// 和 DMR 的 60 ms / 3 帧不同，YSF 的包本来就是 5 帧 100 ms，
    /// 所以节拍也要跟着改（见 `startTxTimer(interval:)`）。
    private func beginYsfPtt() {
        guard state == .online else {
            append(.warning, "还没连上反射器，现在按 PTT 发不出去")
            return
        }
        guard txTimer == nil else {
            append(.warning, "上一次发射还没收尾，等它发完再按")
            return
        }
        guard !activeSettings.ysfCallsign.isEmpty else {
            append(.warning, "呼号还没填，YSF 发不出呼号")
            return
        }

        pttFrames.removeAll(keepingCapacity: true)
        encoder.reset()
        mic.gain = PttMicrophone.linearGain(db: activeSettings.micGainDb)
        mic.autoGain = activeSettings.micAutoGain

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
            append(.info, "去「设置 → EasyDMR → 麦克风」确认权限；模拟器没有麦克风，只能在真机上试")
            return
        }

        guard sendYsfHeader() else {
            mic.onFrame = nil
            mic.stop()
            return
        }

        voice.isMuted = true
        isTransmitting = true
        txSeconds = 0
        txStartedAt = Date()

        txKind = .ptt
        append(.tx, "🔴 按住发射 → YSF（呼号 \(activeSettings.ysfCallsign)，目的 ALL）")
        startTxTimer(interval: 0.10)
    }

    /// YSF 语音头（155 字节）。
    private func sendYsfHeader() -> Bool {
        var buffer = [UInt8](repeating: 0, count: Int(YSF_PACKET_BYTES))
        let n = ysf_core_tx_begin(ysf, &buffer, Int32(buffer.count))
        guard n == Int(YSF_PACKET_BYTES) else {
            append(.error, "核心没能生成 YSF 语音头（返回 \(n)）")
            return false
        }
        send(Data(buffer[0..<Int(n)]), label: "YSF 语音头")
        return true
    }

    /// 一包 YSF 语音：5 帧 PCM → 5 × 7 字节 AMBE → 155 字节。
    private func sendYsfPacket(_ frames: [[Int16]]) {
        var codec = [UInt8]()
        codec.reserveCapacity(Int(YSF_CODEC_BYTES))
        for index in 0..<Int(YSF_CODEC_FRAMES) {
            let pcm = index < frames.count
                ? frames[index]
                : [Int16](repeating: 0, count: PttMicrophone.frameSamples)
            codec.append(contentsOf: encoder.encodeStandardFrame(pcm))
        }

        var buffer = [UInt8](repeating: 0, count: Int(YSF_PACKET_BYTES))
        let n = codec.withUnsafeBufferPointer { pointer in
            ysf_core_tx_voice(ysf, pointer.baseAddress, &buffer, Int32(buffer.count))
        }
        guard n == Int(YSF_PACKET_BYTES) else { return }
        send(Data(buffer[0..<Int(n)]), label: "YSF 语音包", quiet: true)
    }

    /// 语音头。成功返回 true。
    private func sendHeader(destination: Int, slot: UInt8, cc: UInt8, isPrivate: Bool = false) -> Bool {
        if isOdtp {
            var buffer = [UInt8](repeating: 0, count: 32)
            let flag: Int32 = isPrivate ? 1 : 0
            let n = rw_core_tx_header(rw, UInt32(destination), flag, &buffer, Int32(buffer.count))
            guard n > 0 else { return false }
            send(Data(buffer[0..<Int(n)]),
                 label: "DMR 语音头 → " + Self.destinationText(destination, isPrivate: isPrivate),
                 quiet: true)

            // 规范：语音头/结束符可以重复 2～3 次，但**必须用同一个序号**（服务器按序号去重）。
            // 所以第 2、3 次走 tx_header_again，而不是重新生成一个包。
            for _ in 0..<2 {
                let again = rw_core_tx_header_again(rw, UInt32(destination), flag, &buffer, Int32(buffer.count))
                guard again > 0 else { break }
                send(Data(buffer[0..<Int(again)]), label: "DMR 语音头（同序号重发）", quiet: true)
            }
            append(.tx, "→ 语音头 → " + Self.destinationText(destination, isPrivate: isPrivate)
                + "（ODTP，连发 3 次、同一序号）")
            return true
        }

        var buffer = [UInt8](repeating: 0, count: 64)
        let n = dmr_core_tx_begin(core, UInt32(destination), slot, cc,
                                  isPrivate ? 1 : 0, &buffer, Int32(buffer.count))
        guard n == 55 else {
            append(.error, "核心没能生成语音头（返回 \(n)）")
            return false
        }
        send(Data(buffer[0..<55]),
             label: "DMRD 语音头 → " + Self.destinationText(destination, isPrivate: isPrivate))
        return true
    }

    /// 日志里怎么称呼这次发射的目的地址：组呼写 `TG 46001`，单呼写 `单呼 4600002`。
    static func destinationText(_ destination: Int, isPrivate: Bool) -> String {
        isPrivate ? "单呼 \(destination)" : "TG \(destination)"
    }

    private func sendBurst(_ codec: [UInt8], quiet: Bool) {
        if isOdtp {
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = codec.withUnsafeBufferPointer { pointer in
                rw_core_tx_audio(rw, pointer.baseAddress, &buffer, Int32(buffer.count))
            }
            guard n > 0 else { return }
            send(Data(buffer[0..<Int(n)]), label: "DMR 语音帧", quiet: quiet)
            // 每 83 帧（约 5 秒）插一次 KEEP_ALIVE：发射期间也要维持会话，
            // 否则长按超过服务器的心跳窗口就会被踢。
            if rw_core_tx_count(rw) % 83 == 0 {
                sendPing()
            }
            return
        }

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

    private func startTxTimer(interval: TimeInterval = 0.06) {
        txTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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

            if isYsf {
                // 一包 5 帧；采集还没跟上就补静音，别让包序列断掉。
                let need = Int(YSF_CODEC_FRAMES)
                var frames = [[Int16]]()
                if pttFrames.count >= need {
                    frames = Array(pttFrames.prefix(need))
                    pttFrames.removeFirst(need)
                } else {
                    frames = pttFrames
                    pttFrames.removeAll(keepingCapacity: true)
                }
                sendYsfPacket(frames)
                return
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

        if isYsf {
            var buffer = [UInt8](repeating: 0, count: Int(YSF_PACKET_BYTES))
            let n = ysf_core_tx_end(ysf, &buffer, Int32(buffer.count))
            if n == Int(YSF_PACKET_BYTES) {
                send(Data(buffer[0..<Int(n)]), label: "YSF 语音结束符")
            }
            append(.tx, label)
            txKind = .subscribe
            txBurstsLeft = 0
            return
        }

        if isOdtp {
            var buffer = [UInt8](repeating: 0, count: 32)
            let n = rw_core_tx_end(rw, &buffer, Int32(buffer.count))
            if n > 0 {
                // 结束符同样按规范重复一次：原样重发同一段字节，序号自然相同。
                let packet = Data(buffer[0..<Int(n)])
                send(packet, label: "DMR 语音结束符")
                send(packet, label: "DMR 语音结束符（同序号重发）", quiet: true)
            }
            append(.tx, label)
            txBurstsLeft = 0
            flushPendingSubscribe()
            return
        }

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
        flushPendingSubscribe()
    }

    /// 发射结束后补一次被推迟的订阅（`call` 在忙着的时候只会记下来）。
    private func flushPendingSubscribe() {
        guard let pending = pendingSubscribeTalkgroup else { return }
        pendingSubscribeTalkgroup = nil
        // 走到这里 txTimer 已经是 nil，call 会直接发新的订阅。
        call(talkgroup: pending)
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
            // 关掉语音就同时把引擎和静音保活停掉，否则后台会一直空跑音频栈白耗电。
            voice.stopListening()
        } else if state == .online {
            // 重新打开时立刻把引擎点起来，不用等下一帧语音（后台保活也靠它）。
            voice.startListening()
        }
    }

    /// 麦克风增益改了立刻生效：通话中调滑杆，下一次采集就按新系数放大，不必重连、不必松手。
    func applyMicGain(_ settings: Settings) {
        activeSettings.micGainDb = settings.micGainDb
        activeSettings.micAutoGain = settings.micAutoGain
        mic.gain = PttMicrophone.linearGain(db: settings.micGainDb)
        mic.autoGain = settings.micAutoGain
    }

    /// 续订、订阅相关的设置在连接期间改了也要立刻生效，不必重连。
    func applyBehaviour(_ settings: Settings) {
        let slotChanged = activeSettings.callSlot != settings.callSlot
        let ccChanged = activeSettings.colorCode != settings.colorCode

        // 用户重新打开「跟随服务器下发」= 又想听到服务器推的所有组，解除切组时的锁定。
        if !activeSettings.followServerTalkgroups, settings.followServerTalkgroups {
            listenLock = 0
        }

        activeSettings.autoRenewTalkgroup = settings.autoRenewTalkgroup
        activeSettings.talkgroupRenewMinutes = settings.talkgroupRenewMinutes
        activeSettings.callSlot = settings.callSlot
        activeSettings.colorCode = settings.colorCode
        activeSettings.autoCallOnConnect = settings.autoCallOnConnect
        activeSettings.followServerTalkgroups = settings.followServerTalkgroups
        activeSettings.sendConfig = settings.sendConfig

        // 时隙和色码都只体现在「发出去的那几帧」里，改完不重新订阅等于没改。
        // ODTP 没有时隙 / 色码，这两项对它没有意义。
        if slotChanged || ccChanged {
            dmr_core_set_color_code(core, UInt8(min(15, max(0, settings.colorCode))))
        }
        if isHomebrew, (slotChanged || ccChanged), state == .online, activeTalkgroup > 0, txTimer == nil {
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

        // YSF 是另一套协议：呼号登录、没有鉴权 / 配置包 / 订阅，校验项也完全不同。
        if settings.homeMode == .ysf {
            beginYsfConnect(settings)
            return
        }

        guard settings.dmrId > 0, !settings.sanitizedPassword.isEmpty else {
            state = .failed("请先在设置里填写 DMR ID 与密码")
            append(.error, "身份信息不完整：DMR ID 与 BM密码 不能为空（"
                + (settings.linkProtocol == .odtp ? "ODTP 用 7 位 DMR ID + SelfCare 里给这台终端设的 BM密码" : "Homebrew 用 9 位热点 ID + Hotspot Security 密码")
                + "）")
            return
        }

        if settings.linkProtocol == .odtp, settings.dmrId > 0xFF_FFFF {
            state = .failed("ODTP 要用 7 位 DMR ID")
            append(.error, "现在填的 \(settings.dmrId) 是 9 位，像热点 ID。ODTP 登录要的是 7 位 DMR ID（不带后缀），请改「DMR ID」那一栏")
            return
        }

        let trimmedHost = settings.host.trimmingCharacters(in: .whitespaces)
        if trimmedHost.isEmpty {
            state = .failed("服务器地址是空的")
            append(.error, "去「设置 → 服务器」选一台服务器，或手填域名（不要带 https:// 和端口）")
            return
        }
        // 常见误填：把 REST 接口的域名写到服务器里，那个域名上没有 54006 / 62031。
        if trimmedHost.lowercased().hasPrefix("api.brandmeister") {
            state = .failed("服务器填成了 api.brandmeister.network")
            append(.error, "这是查询接口的域名，上面没有热点端口。ODTP 请填 <地区>.master.brandmeister.network（如 4601.master.brandmeister.network），端口 54006")
            return
        }

        if settings.usesEssid && settings.dmrId > 42_949_672 {
            state = .failed("DMR ID 过大：ESSID 需要 7 位 ID，不是 9 位热点 ID")
            append(.error, "ESSID 换算会溢出：DMR ID 应填 7 位编号")
            return
        }

        applyCoreConfiguration(settings)

        state = .connecting

        if settings.linkProtocol == .odtp {
            append(.info, "开始连接 \(settings.host):\(settings.port)（ODTP / Rewind）")
            append(.info, "登录 ID \(settings.dmrId)（ODTP 用 7 位 DMR ID，不带热点后缀）")
            append(.info, "握手：KEEP_ALIVE → CHALLENGE → AUTHENTICATION → SUBSCRIPTION")
        } else {
            append(.info, "开始连接 \(settings.host):\(settings.port)（\(settings.transport.short)）")
            append(.info, "登录 ID \(settings.hotspotId)"
                + (settings.hotspotIdOverride >= 10_000_000 ? "（设置里直接指定）" : settings.usesEssid ? "（DMR ID + ESSID 后缀）" : "（没填 ESSID，多数服务器不认）"))
            if settings.sendConfig {
                append(.info, "握手：RPTL → RPTK → RPTC → RPTPING（与参考实现 DroidStar 一致）")
            } else {
                append(.info, "握手：RPTL → RPTK（跳过 RPTC，只给不接受配置包的服务器用）")
            }
        }

        // ODTP 只走 UDP（Rewind 就是 UDP 协议），WebSocket 只可能是 Homebrew 网关。
        if settings.linkProtocol == .odtp || settings.transport == .udp {
            startUDP()
        } else {
            startWebSocket()
        }
    }

    // MARK: - YSF 连接

    /// YSF 反射器的连接准备。和 DMR 那套比少了「ID + 密码 + 配置包 + 订阅」四件事，
    /// 只要求一个呼号：登录包就是 "YSFP" + 呼号，服务器回一个 14 字节的包就算上线。
    private func beginYsfConnect(_ settings: Settings) {
        let callsign = settings.ysfCallsign
        guard !callsign.isEmpty else {
            state = .failed("YSF 需要呼号")
            append(.error, "YSF 用呼号登录（最长 10 个字符），去「设置 → 身份」把呼号填上")
            return
        }

        let host = settings.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            state = .failed("服务器地址是空的")
            append(.error, "回首页点「服务器」挑一个 YSF 反射器，或手填域名（不要带 https:// 和端口）")
            return
        }
        guard settings.port > 0, settings.port < 65_536 else {
            state = .failed("端口无效：\(settings.port)")
            append(.error, "YSF 反射器的端口就是服务器列表里那个数字（常见 42000）")
            return
        }

        ysf_core_set_callsign(ysf, callsign)
        ysf_core_set_destination(ysf, "ALL")
        ysf_core_reset(ysf)

        state = .connecting
        append(.info, "开始连接 \(host):\(settings.port)（YSF 反射器）")
        append(.info, "登录呼号 \(callsign)（YSF 用呼号，不是 DMR ID）")
        append(.info, "握手：YSFP → 服务器回 14 字节（YSF 没有鉴权、没有配置包、也没有订阅）")

        // YSF 只有 UDP，没有 WebSocket 网关那回事。
        startUDP()
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

        // ODTP 的身份是「7 位 DMR ID + SelfCare 密码」，没有热点后缀的概念
        rw_core_set_identity(rw, UInt32(clamping: settings.dmrId), settings.sanitizedPassword)

        // YSF 的身份只有一个呼号（心跳、登出、每个发包的源字段都用它）
        ysf_core_set_callsign(ysf, settings.ysfCallsign)
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
            fail(isYsf ? "YSF 反射器连续 3 次没有回应 YSFP"
                       : isOdtp ? "服务器连续 3 次没有回应 KEEP_ALIVE（ODTP）"
                                : "服务器连续 3 次没有回应登录请求（RPTL）")
            return
        }
        state = .loggingIn

        if isYsf {
            var buffer = [UInt8](repeating: 0, count: 16)
            let n = ysf_core_login(ysf, &buffer, Int32(buffer.count))
            guard n == 14 else {
                fail("协议核心没能生成 YSFP 登录包（呼号 \(activeSettings.ysfCallsign)）", allowRetry: false)
                return
            }
            append(.info, "→ YSFP 登录（第 \(loginAttempt) 次），呼号 \(activeSettings.ysfCallsign)")
            send(Data(buffer[0..<14]), label: "YSFP")
            armLoginTimeout()
            return
        }

        if isOdtp {
            var buffer = [UInt8](repeating: 0, count: 128)
            let n = rw_core_keepalive(rw, &buffer, Int32(buffer.count))
            guard n > 0 else {
                fail("协议核心没能生成 KEEP_ALIVE（DMR ID \(activeSettings.dmrId)）", allowRetry: false)
                return
            }
            append(.info, "→ KEEP_ALIVE 登录（第 \(loginAttempt) 次），DMR ID \(activeSettings.dmrId)")
            send(Data(buffer[0..<Int(n)]), label: "KEEP_ALIVE")
            armLoginTimeout()
            return
        }

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
        if isYsf {
            var buffer = [UInt8](repeating: 0, count: 16)
            let n = ysf_core_ping(ysf, &buffer, Int32(buffer.count))
            guard n == 14 else { return }
            // YSF 的心跳就是再发一次 YSFP，和登录包一模一样；每 5 秒一条会把日志刷满，静默发。
            send(Data(buffer[0..<14]), label: "YSFP", quiet: true)
            return
        }

        if isOdtp {
            var buffer = [UInt8](repeating: 0, count: 128)
            let n = rw_core_keepalive(rw, &buffer, Int32(buffer.count))
            guard n > 0 else { return }
            send(Data(buffer[0..<Int(n)]), label: "KEEP_ALIVE", quiet: true)
            return
        }

        var buffer = [UInt8](repeating: 0, count: 16)
        let n = dmr_core_ping(core, &buffer, Int32(buffer.count))
        guard n > 0 else { return }
        send(Data(buffer[0..<Int(n)]), label: "RPTPING", quiet: true)
    }

    private func sendLogout() {
        if isYsf {
            // 不发 YSFU 的话，反射器要等心跳超时才把呼号从在列表里摘掉，
            // 这段时间别人看到你还是「在线」。
            var buffer = [UInt8](repeating: 0, count: 16)
            let n = ysf_core_logout(ysf, &buffer, Int32(buffer.count))
            guard n > 0 else { return }
            send(Data(buffer[0..<Int(n)]), label: "YSFU 登出")
            return
        }

        if isOdtp {
            var buffer = [UInt8](repeating: 0, count: 32)
            let n = rw_core_close(rw, &buffer, Int32(buffer.count))
            guard n > 0 else { return }
            send(Data(buffer[0..<Int(n)]), label: "REWIND CLOSE")
            return
        }

        var buffer = [UInt8](repeating: 0, count: 16)
        let n = dmr_core_logout(core, &buffer, Int32(buffer.count))
        guard n > 0 else { return }
        send(Data(buffer[0..<Int(n)]), label: "RPTCL 主动登出")
    }

    // MARK: - 入站分发

    private func handleInbound(_ data: Data) {
        lastServerPacket = Date()

        if isYsf {
            handleYsfInbound(data)
            return
        }

        if isOdtp {
            handleRewindInbound(data)
            return
        }

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

    // MARK: - YSF 入站

    /// 把 C 结构体里的定长呼号字段转成字符串（去掉尾部空格与 0）。
    private static func ysfText<T>(_ field: T) -> String {
        var value = field
        return withUnsafeBytes(of: &value) { raw in
            let bytes = raw.prefix(10).prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private func handleYsfInbound(_ data: Data) {
        var result = ysf_result_t()
        let event = data.withUnsafeBytes { raw -> Int32 in
            let pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return ysf_core_receive(ysf, pointer, Int32(data.count), &result)
        }

        switch event {
        case YSF_EVT_CONNECTED:
            append(.info, "← 收到反射器回应，YSF 链路已建立")
            goOnline()

        case YSF_EVT_PONG:
            // 反射器的心跳回应，每 5 秒一次，不刷日志。
            break

        case YSF_EVT_RX_HEADER, YSF_EVT_RX_VOICE, YSF_EVT_RX_END, YSF_EVT_RX_OTHER:
            handleYsfFrame(event: event, result: result)

        default:
            logUnknown(data)
        }
    }

    // MARK: - YSF 帧处理

    /// YSF 的一包 = 5 个 20 ms 帧（100 ms）。语音头 / 结束符由 FICH 的 FI 字段区分，
    /// 源 / 目的呼号在语音头的 DCH 里（后续帧的 DCH 只在 FN=0/1 时带目的 / 源）。
    ///
    /// 和 DMR 的差别：没有时隙、没有数字 ID，所以 `src / dst` 一律填 0，
    /// 呼号放在 `name`，目的呼号放在 `channel`（界面优先显示这两个）。
    private func handleYsfFrame(event: Int32, result: ysf_result_t) {
        rxFrames += 1
        lastHeard = Date()
        streamLastFrameAt = Date()
        talkgroupAliveAt = Date()

        let source = Self.ysfText(result.src)
        let dest = Self.ysfText(result.dst)
        let gateway = Self.ysfText(result.gw)

        // 呼号有两个来源：包头里的 10 字节字段（每包都有），以及语音头 / VD2 的 DCH
        // （只有 FN=0 带目的、FN=1 带源）。包头那两段在真实反射器上常常是空的或者干脆
        // 填成网关呼号——参考实现 DroidStar 读包头时也只取 GW——所以「解出非空值就记住」，
        // 后面那些没带信令的包沿用它，界面上的呼号才不会一句一句地闪成空白。
        if !source.isEmpty { ysfSource = source }
        if !dest.isEmpty { ysfDest = dest }

        // 一句话里这个键必须**保持不变**。
        //
        // 之前是每包都用当时的 src/dst 现算，而 src/dst 会随着「这一包的 DCH 有没有解出来」
        // 在「包头值 / DCH 值 / 空」之间来回跳（FN=0 改目的、FN=1 改源，其余帧只留包头值）。
        // 键一变，`beginStream` 就把上一路 `voice.end()` 掉再 `voice.begin()`：
        // 解码器被清、播放队列被 `flush()`，一句话里每秒清好几次 —— 症状正是
        // 「收帧在涨、当前讲话人也有，但一点声音都听不到」。
        // 现在只在语音头（或者中途加入的第一个语音包）定一次键，之后整句沿用。
        let headerKey = "ysf-\(source)-\(dest)"
        let key = streamKey ?? "ysf-\(ysfSource)-\(ysfDest)"

        switch event {
        case YSF_EVT_RX_HEADER:
            // 语音头这一包的 DCH 里是完整的「目的 + 源」，以它为准重定名字。
            ysfSource = source
            ysfDest = dest
            beginStream(key: headerKey, src: 0, dst: 0, slot: 1, isPrivate: false, at: Date(),
                        name: source, channel: dest)
            append(.rx, "YSF 通话开始 \(source) → \(dest)（网关 \(gateway)）")

        case YSF_EVT_RX_END:
            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                closeCall(index, at: Date())
                append(.rx, "YSF 通话结束 \(ysfSource)（\(Fmt.duration(calls[index].duration))，\(calls[index].frames) 包）")
            }
            endStream(reason: nil)
            ysfSource = ""
            ysfDest = ""

        case YSF_EVT_RX_VOICE:
            if streamKey != key {
                // 连上时对方已经在说，或者语音头丢了：直接用这一包接上。
                beginStream(key: key, src: 0, dst: 0, slot: 1, isPrivate: false, at: Date(),
                            name: ysfSource, channel: ysfDest)
            }
            let codec = withUnsafeBytes(of: result.codec) { raw in
                Array(raw.prefix(Int(YSF_CODEC_BYTES)))
            }
            voice.pushYsf(key: key, codec: codec)
            reportAudioErrorOnce()
            syncVoiceUI()

            // 第一包语音打一行体检：FI/DT/FN 说明这一包被当成了什么，解出电平说明
            // 声码器有没有真的出声（0% = 解出来是静音，几秒后还是 0 就是解码链的问题；
            // 有电平却没声音，问题就在播放这一段）。
            if !ysfProbeLogged {
                ysfProbeLogged = true
                append(.info, "YSF 语音包：FI=\(result.fi) DT=\(result.dt) FN=\(result.fn)/\(result.ft)，"
                    + "codec \(codec.count) 字节，解出电平 \(Int(voice.level * 100))%")
            }
            trackSpeaker(src: 0, dst: 0, slot: 1, isPrivate: false, at: Date(),
                         name: ysfSource, channel: ysfDest)

            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                calls[index].frames += 1
                calls[index].updatedAt = Date()
            } else {
                calls.insert(makeCall(src: 0, dst: 0, slot: 1, isPrivate: false, key: key,
                                      name: ysfSource, channel: ysfDest), at: 0)
                trimCalls()
            }

        default:
            // 数据帧（DT=1）与全速率语音（DT=3）不处理：后者要另一套 4400 bps 声码器。
            append(.rx, "← YSF 控制帧 FI=\(result.fi) DT=\(result.dt)，不解码")
        }
    }

    // MARK: - ODTP / Rewind 入站

    /// BrandMeister 的 ODTP 分支。和 Homebrew 的差别集中在三处：
    /// 登录是 KEEP_ALIVE → CHALLENGE → AUTHENTICATION → 空 KEEP_ALIVE，
    /// 订阅是显式 SUBSCRIPTION 命令，语音帧直接就是 27 字节 AMBE（不用拆 LC / 反交织）。
    private func handleRewindInbound(_ data: Data) {
        var result = rw_result_t()
        let event = data.withUnsafeBytes { raw -> Int32 in
            let pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return rw_core_receive(rw, pointer, Int32(data.count), &result)
        }

        switch event {
        case RW_EVT_AUTH:
            loginTimer?.cancel()
            state = .authenticating
            let count = Int(result.out_len)
            if count > 0 {
                let payload = withUnsafeBytes(of: result.out) { Data(bytes: $0.baseAddress!, count: count) }
                append(.info, "← 收到挑战盐，→ AUTHENTICATION（\(count) 字节：18 字节头 + SHA256(盐‖密码)）")
                send(payload, label: "AUTHENTICATION")
                // 参考实现 RewindClient 回完 AUTHENTICATION 后 `continue` 回到循环顶部，
                // 也就是**紧接着再发一个 KEEP_ALIVE**，然后等服务器的空 KEEP_ALIVE。
                // 规范说鉴权成功服务器会主动回空 KEEP_ALIVE，多发一次心跳没有副作用，
                // 还能兜住那些只在你下次心跳时才确认的 master。
                sendPing()
            }
            armLoginTimeout()

        case RW_EVT_AUTH_REJECTED:
            // 服务器连发三次挑战盐 = 它不认我们算出来的摘要。
            loginTimer?.cancel()
            fail("密码不对：服务器连续三次要求重新鉴权（ODTP 的 SHA256 摘要没通过）。\n"
                + "请核对「设置 → 身份」里的 BM密码，它是 SelfCare → Hotspot Security 里给这个 DMR ID 设的，"
                + "不是 BrandMeister 网站登录密码", allowRetry: false)

        case RW_EVT_AUTHENTICATED:
            loginTimer?.cancel()
            state = .configuring
            append(.info, "← 鉴权通过")
            if activeSettings.talkgroup > 0 {
                _ = sendSubscribe(talkgroup: activeSettings.talkgroup)
                // 订阅确认也可能永远不来（组没权限时服务器直接沉默），必须挂超时，
                // 否则界面会一直停在「配置中」。
                armLoginTimeout()
            } else {
                append(.warning, "还没有选通话组：ODTP 必须先订阅才会收到语音，去「首页」选一个组")
                goOnline()
            }

        case RW_EVT_SUBSCRIBED:
            goOnline()

        case RW_EVT_PONG:
            // 心跳应答，平时静默：每 5 秒打一行会把日志刷满。
            // 但登录阶段收到 KEEP_ALIVE 就说明状态机没跟上（服务器认为已鉴权），必须留痕。
            if state != .online {
                append(.rx, "← 收到 KEEP_ALIVE（当前阶段 \(state.label)，不是鉴权确认）")
            }

        case RW_EVT_REDIRECT:
            let count = Int(result.out_len)
            let target = withUnsafeBytes(of: result.payload) { raw -> String in
                guard count > 0, let base = raw.baseAddress else { return "" }
                return String(bytes: UnsafeRawBufferPointer(start: base, count: count), encoding: .utf8) ?? ""
            }
            append(.warning, "← 服务器要求重定向到 \(target)")
            fail("这台 master 把连接指到了 \(target)。请到「设置 → 服务器」把地址改成它再连", allowRetry: false)

        case RW_EVT_REPORT:
            let count = Int(result.out_len)
            let text = withUnsafeBytes(of: result.payload) { raw -> String in
                guard count > 0, let base = raw.baseAddress else { return "" }
                return String(bytes: UnsafeRawBufferPointer(start: base, count: count), encoding: .utf8) ?? ""
            }
            append(.info, "← 服务器：\(text)")

        case RW_EVT_FAILURE:
            // R3ABM 的头文件里没定义 FailureCode 结构体，实测前两字节是小端错误码。
            var code = 0
            if result.out_len >= 2 {
                let raw = withUnsafeBytes(of: result.payload) { Array($0.prefix(2)) }
                code = Int(raw[0]) | (Int(raw[1]) << 8)
            }
            append(.warning, "← 服务器返回失败码 \(code)（订阅被拒 / 会话不被允许）")
            if state == .configuring {
                fail("服务器拒绝了订阅（失败码 \(code)）：这个 DMR ID 可能没被授权收这个通话组，"
                    + "或者账号还没在 SelfCare 里给这个组开放", allowRetry: false)
            }

        case RW_EVT_CLOSED:
            handleRefused("REWIND CLOSE")

        case RW_EVT_RX_HEADER, RW_EVT_RX_VOICE, RW_EVT_RX_EOT:
            var frame = dmr_result_t()
            frame.src = result.src
            frame.dst = result.dst
            // ODTP 没有时隙概念，服务器自己决定走哪个时隙；界面上统一按 TS2 显示
            frame.slot = 2
            frame.is_private = result.is_private
            frame.codec = result.codec

            let mirror: Int32
            switch event {
            case RW_EVT_RX_HEADER:
                mirror = DMR_EVT_RX_HEADER
                frame.data_type = 1
            case RW_EVT_RX_EOT:
                mirror = DMR_EVT_RX_EOT
                frame.data_type = 2
            default:
                mirror = DMR_EVT_RX_VOICE
            }
            // 复用 Homebrew 的通话列表 / 电平 / 流量统计逻辑
            handleDmrFrame(event: mirror, result: frame)

        default:
            logUnknownRewind(data)
        }
    }

    /// ODTP 的包是二进制，按 ASCII 前缀打日志会出来一串乱码。
    /// 这里按「包类型」去重记录 —— 类型号直接对着 Rewind.h 查得到。
    private func logUnknownRewind(_ data: Data) {
        guard data.count >= 10 else { return }
        let bytes = [UInt8](data.prefix(10))
        let type = Int(bytes[8]) | (Int(bytes[9]) << 8)
        let tag = String(format: "RW%04X", type)
        guard !unknownTags.contains(tag) else { return }
        unknownTags.insert(tag)
        append(.rx, "← 未处理的 Rewind 包类型 0x\(String(format: "%04X", type))（\(data.count) 字节），后续同类不再提示",
               hex: data.hexDump)
    }

    /// ODTP 订阅：发 SUBSCRIPTION(type=7 组呼)，服务器回一个空的同类型包表示成功。
    @discardableResult
    private func sendSubscribe(talkgroup: Int) -> Bool {
        guard talkgroup > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = rw_core_subscribe(rw, UInt32(talkgroup), &buffer, Int32(buffer.count))
        guard n > 0 else { return false }
        send(Data(buffer[0..<Int(n)]), label: "SUBSCRIPTION TG \(talkgroup)")
        append(.info, "→ 已订阅 TG \(talkgroup)（ODTP 显式订阅，等服务器确认）")
        lastSubscribeAt = Date()
        lastSubscribeTalkgroup = talkgroup
        talkgroupAliveAt = Date()
        return true
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
            fail("会话被服务器反复关闭（\(name)）："
                + (isOdtp
                   ? "核对这个 7 位 DMR ID 是否已在 SelfCare 注册为终端、密码是否是它自己的；同一个 ID 不能同时登两台设备"
                   : "核对 9 位热点 ID 与 SelfCare 里是否一致；如果另一台设备（手机 MMDVM / 盒子）也用这个 ID，先把它断开"),
                allowRetry: false)
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
        append(.info, "✅ 已登录，进入在线状态，每 \(Int(pingInterval)) 秒发一次"
            + (isYsf ? " YSFP" : isOdtp ? " KEEP_ALIVE" : " RPTPING"))
        startTimers()

        // 提前把音频会话切到「可录音」并保持住（不启动采集，不会亮麦克风指示灯）。
        // 这一步以前是塞在按下 PTT 时才做的：同步重配音频路由要 0.3～0.5 秒，
        // 表现就是「按住 PTT 半天才开始发」。挪到上线这一刻，用户感觉不到。
        mic.prepareForTalk()

        // 连上就把音频栈点起来（含循环静音保活），不要等第一帧语音。
        // 否则「刚连上还没人说话就切后台」这段里引擎没渲染过音频，系统会把 App 挂起，
        // 之后别人再说话就收不到了——这就是以前「后台听不到」的根因。
        voice.startListening()

        // YSF 没有订阅、没有设备库可核对（那套是 BrandMeister 的 REST 接口）。
        guard !isYsf else { return }

        verifyHotspotRegistration()

        // ODTP 的订阅在鉴权通过时就已经发了，这里不能再补一次。
        guard !isOdtp else { return }

        // Homebrew 没有订阅指令：真让 master 记住这个组的是「发一次真实发射」。
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
        case .loggingIn:
            if loginAttempt < 3 {
                append(.warning, "登录超时，重试 (\(loginAttempt)/3)")
                sendLogin()
            } else {
                fail(isOdtp
                     ? "服务器没有回应 KEEP_ALIVE：地址/端口要写 <地区>.master.brandmeister.network:54006，且这个 7 位 DMR ID 必须已在 SelfCare 里注册为终端"
                     : "登录超时：检查服务器地址、端口与网络")
            }
        case .authenticating:
            if loginAttempt < 3 {
                append(.warning, "鉴权超时，重试 (\(loginAttempt)/3)")
                sendLogin()
            } else {
                fail(isOdtp
                     ? "鉴权失败：ODTP 的密码错了服务器**不会回任何包**（规范如此），所以只能超时。请核对 SelfCare 里这台终端的密码"
                     : "鉴权超时：密码或热点 ID 可能不对")
            }
        case .configuring:
            if isOdtp {
                fail("服务器没有确认订阅（SUBSCRIPTION）：确认这个通话组对当前 DMR ID 开放", allowRetry: false)
            } else {
                fail("服务器没有回应配置包（RPTC）：到「设置 → 服务器」关掉「上报配置包 RPTC」再连一次", allowRetry: false)
            }
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

        // 锁屏卡片 / 灵动岛：单独一个 1 秒的节拍，不挂在 `tick()` 上——
        // `tick()` 只在在线时跑，而卡片也需要反映「正在连接」「已断开」这些中间态。
        liveTimer?.invalidate()
        let live = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncLiveActivity() }
        }
        RunLoop.main.add(live, forMode: .common)
        liveTimer = live
        syncLiveActivity()
    }

    /// 每秒把当前状态喂给 Live Activity；节流与重建逻辑都在控制器里。
    private func syncLiveActivity() {
        guard #available(iOS 16.1, *) else { return }
        LiveActivityController.shared.sync(hotspot: self, settings: activeSettings)
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

        trafficStat["\(dst)@\(slot)", default: 0] += 1
        trafficTotal += 1
        warnedNoTraffic = false

        // 播放范围：显式切过组就只听那一个（listenLock），否则按「跟随服务器下发」的设置来。
        // 默认跟随是 DroidStar 的接收侧做法——BM 推的是这台热点被订阅的全部组，
        // 其中还包括 SelfCare 里配的静态组。但用户既然点了某一组，就该只听到这一组，
        // 旧组的语音必须立刻停掉（Homebrew 退不掉订阅，只能在这里丢帧）。
        //
        // `dst > 0` 这个条件不能省：ODTP 的语音帧本身不带地址（0x0920 只有 27 字节
        // AMBE），目的地址靠最近一个 Full LC（0x0911）补进核心里。连上时对方已经在讲、
        // 或者那条 LC 丢了，`dst` 就是 0 —— 这时按 dst 丢弃会把**整条流**吞掉，
        // 界面上表现为「在收（包有进来）但什么都没发生」，或者干脆像「不再接收」。
        let target = listenLock > 0
            ? listenLock
            : (activeSettings.followServerTalkgroups ? 0 : activeTalkgroup)
        if !isPrivate, target > 0, dst > 0, dst != target {
            filteredFrames += 1
            return
        }

        // 服务器实际在推哪个组 —— 这个值经常不等于界面上选的那个。
        // 放在过滤之后：被丢掉的旧组不该再刷新「服务器下发 TG x」那一行。
        if !isPrivate, dst > 0, serverTalkgroup != dst { serverTalkgroup = dst }

        talkgroupAliveAt = Date()
        streamLastFrameAt = Date()

        switch event {
        case DMR_EVT_RX_HEADER:
            beginStream(key: key, src: src, dst: dst, slot: slot, isPrivate: isPrivate, at: Date())
            append(.rx, "通话开始 \(src) → \(dst)　\(isPrivate ? "单呼" : "组呼")　TS\(slot)")

        case DMR_EVT_RX_EOT:
            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                closeCall(index, at: Date())
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
            reportAudioErrorOnce()
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

    /// 音频会话起不来时只在日志里提示一次，避免每个语音包刷一条。
    private func reportAudioErrorOnce() {
        guard !audioErrorReported, let error = voice.audioError else { return }
        audioErrorReported = true
        append(.warning, "⚠️ \(error)")
        append(.warning, "有语音包进来但放不出声：先看手机侧边静音键 / 音量，再确认没有别的 App 占用麦克风或通话通道")
    }

    private func beginStream(key: String, src: Int, dst: Int, slot: Int, isPrivate: Bool, at date: Date,
                             name: String? = nil, channel: String? = nil) {
        if streamKey != key {
            if let previous = streamKey {
                voice.end(key: previous)
            }
            streamKey = key
            // 旧的同 key 通话先收尾，避免同一个流号出现两条「通话中」
            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                closeCall(index, at: date)
            }
            calls.insert(makeCall(src: src, dst: dst, slot: slot, isPrivate: isPrivate, key: key,
                                  name: name, channel: channel), at: 0)
            trimCalls()
            voice.begin(key: key)
        }
        streamLastFrameAt = date
        trackSpeaker(src: src, dst: dst, slot: slot, isPrivate: isPrivate, at: date,
                     name: name, channel: channel)
        syncVoiceUI()
    }

    private func endStream(reason: String?) {
        if let key = streamKey {
            voice.end(key: key)
            // 有些 master 不推结束符，靠看门狗收尾。这时这条通话在 `calls` 里
            // 还挂着 isActive，不手动收掉就永远进不了「刚刚结束」。
            if let index = calls.firstIndex(where: { $0.id == key && $0.isActive }) {
                closeCall(index, at: Date())
            }
        }
        streamKey = nil
        streamLastFrameAt = nil
        if let reason {
            append(.rx, reason)
        }
        currentSpeaker?.endedAt = currentSpeaker?.endedAt ?? Date()
        syncVoiceUI()
    }

    private func trackSpeaker(src: Int, dst: Int, slot: Int, isPrivate: Bool, at date: Date,
                              name: String? = nil, channel: String? = nil) {
        if var speaker = currentSpeaker,
           speaker.src == src, speaker.dst == dst, speaker.slot == slot, speaker.endedAt == nil,
           speaker.name == name,
           date.timeIntervalSince(speaker.lastVoiceAt) < 3 {
            speaker.lastVoiceAt = date
            speaker.name = name
            speaker.channel = channel
            currentSpeaker = speaker
            return
        }
        currentSpeaker = ActiveSpeaker(src: src, dst: dst, slot: slot, isPrivate: isPrivate,
                                       startedAt: date, lastVoiceAt: date, endedAt: nil,
                                       name: name, channel: channel)
    }

    private func makeCall(src: Int, dst: Int, slot: Int, isPrivate: Bool, key: String,
                          name: String? = nil, channel: String? = nil) -> LiveCall {
        let now = Date()
        return LiveCall(id: key, src: src, dst: dst, slot: slot, isPrivate: isPrivate,
                        frames: 1, startedAt: now, updatedAt: now, isActive: true,
                        name: name, channel: channel)
    }

    /// 把一条通话从「进行中」收掉，并落进本地日志库。
    ///
    /// 收尾有五个入口（收到结束符、看门狗超时、切组、断线、同流号重开），
    /// 全走这一条路才不会出现「首页显示已结束、日志里却没有」。
    /// 落库是幂等的（唯一键 src+dst+slot+开始时间），重复调用不会写出两条。
    private func closeCall(_ index: Int, at date: Date) {
        guard calls.indices.contains(index), calls[index].isActive else { return }
        calls[index].isActive = false
        calls[index].updatedAt = max(date, calls[index].startedAt)
        CallLogStore.shared.record(calls[index])
    }

    private func trimCalls() {
        // 这里裁的只是**内存**里的列表（首页只用前 8 条）。
        // 每一句在收尾时都已经写进 SQLite 了，日志页读的是库，不受这里影响。
        if calls.count > 200 {
            calls.removeLast(calls.count - 200)
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
        // YSF 的流量统计不是按「组@时隙」记的（没有时隙、没有组号），这里不报，
        // 否则安静下来 30 秒就会冒出一条「没收到任何 DMRD」的误导性提醒。
        guard !isYsf else { return }

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

        let filtered = filteredFrames > 0 ? "，其中累计 \(filteredFrames) 帧不是当前组被丢弃" : ""
        append(.rx, "近期流量 \(Int(elapsed))s：\(items)，共 \(trafficTotal) 帧\(filtered)")

        trafficStat.removeAll()
        trafficTotal = 0
        warnedNoTraffic = false
        lastTrafficReport = Date()
    }

    /// 动态 TG 静默太久会被 BrandMeister 释放，静默超时就再订一次。
    /// ODTP 的订阅是账号级的，登着就一直有效，不需要这套续订。
    private func renewTalkgroupIfIdle() {
        guard !isOdtp, !isYsf else { return }
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
        // ODTP 用的是 7 位 DMR ID，BM 设备库里那条 9 位热点记录跟它对不上，
        // 查了只会误导，直接跳过。YSF 连的是反射器，跟 BM 更没关系。
        guard !isOdtp, !isYsf else { return }

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
        liveTimer?.invalidate()
        liveTimer = nil
        if #available(iOS 16.1, *) {
            LiveActivityController.shared.end()
        }
        loginTimer?.cancel()
        loginTimer = nil
        loginToken += 1
        retryWork?.cancel()
        retryWork = nil

        txTimer?.invalidate()
        txTimer = nil
        txBurstsLeft = 0
        dmr_core_reset(core)
        rw_core_reset(rw)
        ysf_core_reset(ysf)

        mic.onFrame = nil
        // 断开才真正拆 tap、把会话还成纯播放；发射收尾只 `stop()`，不动会话。
        mic.release()
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
        receivingBeforePtt = false
        ysfSource = ""
        ysfDest = ""
        ysfProbeLogged = false
        currentSpeaker = nil
        // 断线时还挂着的通话要收尾，否则它既不在「当前讲话人」也不在「刚刚结束」，
        // 等于从界面上消失了。
        let closedAt = Date()
        for index in calls.indices where calls[index].isActive {
            closeCall(index, at: closedAt)
        }
        serverTalkgroup = nil
        talkgroupAliveAt = nil
        pendingSubscribeTalkgroup = nil
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
