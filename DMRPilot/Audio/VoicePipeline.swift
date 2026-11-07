//
//  VoicePipeline.swift
//  DMRPilot
//
//  语音解码流水线：DMRD 的 33 字节载荷 → AMBE+2 半速率解码 → 8 kHz PCM → 播放。
//
//  每一路通话（src-dst-slot）单独持有一个 DMRVoiceDecoder，因为 halfrate 是强状态的：
//  码本预测器、相位跟踪、增强滤波器都跨帧递推。混用会把两个说话人的状态搅在一起，
//  听起来像机器人抽搐。
//
//  同一时刻只有一路声音会真正出声（后到的接管），这是扫描器的常见行为——两路同时
//  播放只会互相盖住。解码本身对每一路都做，所以统计和通话列表仍然准确。
//
//  性能：一个 DMRD 包解 3 帧、480 采样，25 包/秒。整条链在 0.5–3 ms/包的量级，
//  放在主线程上做是安全的（一帧 SwiftUI 预算 16.7 ms），换来的是完全不用操心
//  跨线程状态——解码器不是 Sendable，播放器是 @MainActor。
//

import Foundation

@MainActor
final class VoicePipeline {

    // MARK: - 状态（对外只读）

    /// 是否有声音正在播放
    private(set) var isPlaying = false
    /// 最近一个包的峰值电平，0…1
    private(set) var level: Float = 0
    /// 最近一帧 Golay(23,12) 纠正的比特数，0 表示空口很干净
    private(set) var lastErrorCount = 0
    /// 已解码的 DMRD 语音包数
    private(set) var decodedPackets = 0
    /// 当前正在出声的通话 key
    private(set) var activeKey: String?

    /// 音频会话/引擎起不来的原因，正常时为 nil。
    var audioError: String? { player.audioSessionError }

    /// 播放链路的实时状态，给日志用（一行）。
    var diagnostics: String { player.diagnostics }

    /// 播放链路自己报告的事件（重建 / 自愈），由上层转写进日志。
    var onEvent: (@MainActor (String) -> Void)? {
        get { player.onEvent }
        set { player.onEvent = newValue }
    }

    /// 0…1
    var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    var isMuted = false {
        didSet {
            guard isMuted != oldValue else { return }
            if isMuted {
                player.flush()
                level = 0
                isPlaying = false
            } else {
                // 解除静音时先把引擎拉回来：发射那几秒里会话 mode 被换过、播放引擎
                // 被系统停掉过，只等下一包 PCM 去重开的话，对方刚好在这时候说完
                // 就再也没有「下一包」了——听感就是「按一下 PTT，这一路就哑了」。
                player.start()
            }
        }
    }

    // MARK: - 内部

    private let player = VoicePlayer()
    private var decoders: [String: DMRVoiceDecoder] = [:]
    private var currentKey: String?
    /// 当前这一路最后一次有语音包的时刻。
    ///
    /// 用来判断「占着播放位的那一路是不是已经死了」。以前别的流进来只会被丢掉，
    /// 万一 currentKey 指向一条再也不会来包的流（发射打断、流号换了、看门狗没触发），
    /// 后面所有语音都会被静默丢掉——听着就是「服务器在推、却一直没有声音」。
    private var lastVoiceAt: Date?

    /// 同时保留的解码器上限。BrandMeister 上一般是单流，给 4 路已经很宽裕。
    private static let maxStreams = 4

    // MARK: - 控制

    /// 连上就把音频栈点起来，不等第一帧语音。
    ///
    /// 以前是收到第一个语音包才 `player.start()`，于是「刚连上、还没人说话、切后台」
    /// 这段时间里音频会话根本没激活过，系统直接把 App 挂起，之后再也收不到任何语音。
    /// 现在上线就起引擎，`VoicePlayer` 里还有一条循环静音通道保活（见 `startKeepAlive`）。
    func startListening() {
        guard !isMuted else { return }
        player.start()
    }

    /// 关掉「语音播放」时调用：引擎和那条静音保活一起停，不留在后台空跑。
    func stopListening() {
        player.stop()
    }

    /// 发射收尾：解除静音，并把播放链路**整条重建**一次。
    ///
    /// 不能只把 `isMuted` 翻回 false 就完了。发射期间会话被重新激活过、第二个引擎
    /// （麦克风）起停过，播放引擎在系统那边已经被停掉过一次；而 `engine.isRunning`
    /// 在这个场景下经常还写着 true —— 它一旦骗人，后面的缓冲就只会堆在队列里不出声。
    /// 所以松手后不做试探，直接重建：一次 PTT 一趟，代价可以忽略。
    func endTransmission(audioEnabled: Bool) {
        isMuted = !audioEnabled
        guard audioEnabled else { return }
        player.resumeAfterPtt()
        isPlaying = player.isActive
    }

    /// 通话开始（收到语音头）
    func begin(key: String) {
        // 换了一路：把上一路还没播完的尾巴丢掉，否则新通话要等旧音频播完才出声
        if let previous = currentKey, previous != key {
            player.flush()
        }

        currentKey = key
        activeKey = key
        lastVoiceAt = Date()
        decoder(for: key).reset()
        level = 0
        if !isMuted {
            player.start()
        }
    }

    /// 通话结束（收到语音结束符）
    func end(key: String) {
        decoders[key] = nil

        guard currentKey == key else { return }
        currentKey = nil
        activeKey = nil
        lastVoiceAt = nil
        level = 0
        isPlaying = false
        player.flush()
    }

    /// 立刻静音：丢掉播放队列里还没播的 PCM，但**保留解码器与统计**。
    ///
    /// 切组时用：旧组已经不在播放范围里了，队列里剩下那几十毫秒不该再放出来。
    /// （和 `reset()` 的区别是不清解码器、不清已解码包数，设置页那个计数不会跳回 0。）
    func flush() {
        player.flush()
        level = 0
        isPlaying = false
    }

    /// 断线 / 重连：整体复位
    func reset() {
        decoders.removeAll()
        currentKey = nil
        activeKey = nil
        lastVoiceAt = nil
        level = 0
        isPlaying = false
        decodedPackets = 0
        lastErrorCount = 0
        player.stop()
    }

    // MARK: - 解码

    /// 送进一个 DMRD 语音突发（27 字节 AMBE，已由 C++ 核心从 33 字节载荷里拆好）。
    ///
    /// 注意这里**不**重置解码器：两个时隙可能同时在通话，包会交错到达，
    /// 如果在“接管”时 reset，一路就会被每包重置、永远出不了声。
    /// 重置只发生在语音头（`begin`）和新建解码器的时候。
    func push(key: String, codec: [UInt8]) {
        let now = Date()
        // 播放位的占位规则见 `shouldTakeOver`：没占位、就是自己、或者占位那一路
        // 已经半秒没来包了，都算「该你出声」。
        if currentKey != key, shouldTakeOver(key, at: now) {
            currentKey = key
            activeKey = key
            level = 0
        }

        let decoder = decoder(for: key)
        let pcm = decoder.decode(codec: codec)
        guard !pcm.isEmpty else { return }

        decodedPackets += 1
        lastErrorCount = decoder.lastErrorCount

        // 静音时仍然解码，但不入队：统计和电平以外的一切照常
        if isMuted {
            level = 0
            isPlaying = false
            return
        }

        // 只有当前选中那一路出声。另一路直接返回，不要动 level——
        // 否则两路交错到达时电平会在真值和 0 之间来回跳。
        guard key == currentKey else { return }

        lastVoiceAt = now
        player.start()
        player.enqueue(pcm)
        level = Self.peakLevel(pcm)
        isPlaying = player.isActive
    }

    // MARK: - 辅助

    /// 送进一包 YSF 语音（5 个 7 字节帧 = 100 ms = 800 采样）。
    ///
    /// 和 DMR 的 `push` 差别只在「帧更小、一包更多」：YSF 每帧 49 bit 且没有
    /// DMR 那层空口 FEC，所以逐帧走 `decode(frame7:)`，攒够一包再入队。
    func pushYsf(key: String, codec: [UInt8]) {
        let now = Date()
        if currentKey != key, shouldTakeOver(key, at: now) {
            currentKey = key
            activeKey = key
            level = 0
        }

        let decoder = decoder(for: key)
        var pcm = [Int16]()
        pcm.reserveCapacity(Self.samplesPerYsfPacket)

        var index = 0
        while index + 7 <= codec.count {
            let frame = Array(codec[index..<(index + 7)])
            let chunk = decoder.decode(frame7: frame)
            if !chunk.isEmpty {
                pcm.append(contentsOf: chunk)
            }
            index += 7
        }
        guard !pcm.isEmpty else { return }

        decodedPackets += 1
        lastErrorCount = decoder.lastErrorCount

        if isMuted {
            level = 0
            isPlaying = false
            return
        }

        guard key == currentKey else { return }

        lastVoiceAt = now
        player.start()
        player.enqueue(pcm)
        level = Self.peakLevel(pcm)
        isPlaying = player.isActive
    }

    /// 一包 YSF 语音的采样数：5 × 160
    private static let samplesPerYsfPacket = 800

    /// 当前占着播放位的那一路多久没来包，就允许别的流接手（秒）。
    ///
    /// DMR 一个通话组同时只有一路语音，两路交错只可能是「上一路还没收尾」。
    /// 半秒（12 个包）足够判死，又不至于把正常的时隙交错误当成换台。
    private static let staleStreamTimeout: TimeInterval = 0.5

    /// 这个流现在能不能出声。
    ///
    /// 以前只判 `currentKey == key`：一旦占位的那一路再也不会来包（发射把它打断、
    /// 服务器换了流号、看门狗没来得及触发），后面所有语音都会被静默丢掉，
    /// 现场看起来就是「服务器还在推，但一直没有声音」，只有断开重连才能恢复。
    private func shouldTakeOver(_ key: String, at now: Date) -> Bool {
        guard let current = currentKey else { return true }
        if current == key { return true }
        guard let last = lastVoiceAt else { return true }
        return now.timeIntervalSince(last) > Self.staleStreamTimeout
    }

    private func decoder(for key: String) -> DMRVoiceDecoder {
        if let existing = decoders[key] { return existing }

        if decoders.count >= Self.maxStreams {
            // 淘汰一路不是当前通话的旧解码器，避免长时间在线把字典撑大
            if let stale = decoders.keys.first(where: { $0 != currentKey }) {
                decoders[stale] = nil
            } else {
                decoders.removeAll()
            }
        }

        let decoder = DMRVoiceDecoder()
        decoders[key] = decoder
        return decoder
    }

    private static func peakLevel(_ pcm: [Int16]) -> Float {
        var peak = 0
        for sample in pcm {
            let magnitude = sample == Int16.min ? 32767 : abs(Int(sample))
            if magnitude > peak { peak = magnitude }
        }
        return min(1, Float(peak) / 32767)
    }
}
