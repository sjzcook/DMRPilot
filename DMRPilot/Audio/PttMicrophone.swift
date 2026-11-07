//
//  PttMicrophone.swift
//  DMRPilot
//
//  按下 PTT 时的麦克风采集：硬件格式（44.1/48 kHz 浮点）→ 8 kHz 单声道 Int16，
//  再切成 20 ms（160 采样）一帧交给编码器。
//
//  为什么是 8 kHz：DMR 的空口帧就是 20 ms、8 kHz 采样进来的 AMBE+2 参数，
//  采样率不对时基音和谱包络全偏，对端听到的是「变了调」的声音。
//
//  ## 为什么分「预热」和「采集」两步
//
//  以前 `start()` 每次都 `setCategory(.playAndRecord)` + `setActive(true)`，
//  `stop()` 又切回 `.playback`。这是**同步阻塞主线程**的音频路由重配：切走时输入
//  IO 单元被整个拆掉，下次按下要重新建一遍，一次 0.3～0.5 秒——用户按下去的那一刻
//  其实卡在音频硬件上，表现就是「按住半天才开始发」。
//
//  现在拆成两步：
//  - `prepareForTalk()`（连接成功时调一次）把分类切成「可录音」并保持住；
//  - `start()`（按下时调）只起引擎，`stop()` 只停引擎。
//
//  分类一直是 playAndRecord，输入单元就不会被拆掉，按下时几乎不用等。
//
//  ## 连 mode 也不换
//
//  以前发射期间会 `setMode(.voiceChat)`（AGC + 降噪）。换 mode 同样会让系统重建
//  IO 单元，而本 App 还有一个播放用的 AVAudioEngine 在跑，它会被顺带停掉 ——
//  这就是「按一下 PTT，接收从此没声音」的开关。DroidStar 的 iOS 实现也只设一次
//  分类，全程不动 mode。增益我们自己加（见 `gain`），不依赖系统那套。
//

import AVFoundation
import Foundation

@MainActor
final class PttMicrophone {

    /// 一帧的采样数（20 ms @ 8 kHz）
    static let frameSamples = 160

    /// 每凑够一帧就回调一次（主线程）
    var onFrame: (@MainActor ([Int16]) -> Void)?
    /// 采集链路的诊断信息（输入格式等），接到日志面板。
    var onEvent: (@MainActor (String) -> Void)?
    /// 当前输入电平，0…1（已含增益）。界面用它判断有没有声音进来。
    private(set) var level: Float = 0

    /// 采集后的线性增益，1 = 原样。由 `Settings.micGainDb` 换算而来，发射中改也立刻生效。
    ///
    /// 放在采集这一段而不是编码后：DMR 的 AMBE 编码器吃的是固定 8 kHz 的 PCM，
    /// 增益加在它前面才会真正改变编码出来的谱包络；放在后面就只能改数字，对端听不出差别。
    ///
    /// 它作用在**自动增益之后**，是给用户的最后一点微调（想更响一点就推上去）。
    var gain: Float = 1

    /// 是否启用采集侧自动增益（`Settings.micAutoGain`）。
    var autoGain: Bool = true

    // MARK: - 自动增益参数
    //
    // 为什么必须自己做：
    // iOS 上唯一会开系统 AGC 的是 `.voiceChat` / `.videoChat` 这些 mode，而换 mode
    // 会让系统重建 IO 单元，把同时在跑的播放引擎一起停掉（就是之前那个
    // 「按一下 PTT 从此没声音」）。所以 mode 不能动，只能自己补。
    //
    // DroidStar 在**播放**侧干了同样的事（`AudioEngine::process_audio`：把每块峰值
    // 拉到 30000），它的采集侧不做是因为桌面/安卓的麦克风电平本来够；iOS 的
    // `.playAndRecord + .default` 在免提距离下比 AMBE 期待的低了十几 dB。

    /// 目标峰值（约 -8.7 dBFS）。低于它才提升；高于它**不衰减**（见 `applyAutoGain`）。
    private static let agcTarget: Float = 12000
    /// 最大提升（+27.6 dB）。再高会把整段底噪一起抬起来，听感变成一片沙。
    private static let agcMaxGain: Float = 24
    /// 噪声门（约 -43 dBFS）：低于它就当作没人在说，增益直接往回收。
    /// 没有这道门，安静间隙里底噪会被放大二十几倍，编码器那边还会把沙沙声当语音。
    private static let agcGate: Float = 220
    /// 每帧最多提升的比例（25%/帧 ≈ 80 ms 到位）。提升太快会让呼吸声一抽一抽的。
    private static let agcAttack: Float = 0.25
    /// 回落比例：噪声门触发时用它，约 3 帧（60 ms）回到 1。
    private static let agcRelease: Float = 0.35

    /// 自动增益当前倍数。逐帧更新，跨帧保留（20 ms 一档，正好是语音包络的时间尺度）。
    ///
    /// 永远 >= 1：**只提不压**。麦克风电平本来就够的时候（峰值已经达到 `agcTarget`）
    /// 保持 1 倍，不去衰减 —— 衰减会直接吃掉用户的音量，「加了 AGC 反而更小」。
    /// 削顶由「提升幅度不超过 target 之内的差额」天然保证，不需要再压。
    private var autoGainValue: Float = 1

    // MARK: - 采集统计（`endPtt` 打日志用）

    /// 本次发射里原始输入的**最大**峰值（自动增益之前）。判断有没有削顶。
    private(set) var lastPeak: Float = 0
    /// 以下四个只在 `stop()` 里结算，统计的是「过了噪声门」的帧（真正有人在说的那些）。
    private(set) var averageInputPeak: Float = 0
    private(set) var averageOutputPeak: Float = 0
    private(set) var averageGain: Float = 1
    private(set) var voicedFrameCount: Int = 0

    private var inputPeakSum: Double = 0
    private var outputPeakSum: Double = 0
    private var gainSum: Double = 0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pending = [Int16]()
    private var running = false
    /// tap 是否装着。`removeTap` 在没装的时候会抛 ObjC 异常（Swift 接不住），
    /// 所以必须自己记账，不能靠「应该装过」来推断。
    private var tapInstalled = false
    /// 目标格式：8 kHz、单声道、16 位（`AVAudioFormat` 的初始化可失败，这里按需解包）
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 8000,
                                             channels: 1,
                                             interleaved: true)

    // MARK: - 权限

    /// 麦克风权限是否已经拿到（同步查询）。
    ///
    /// 按下 PTT 时先用它判断：已经授权就直接开麦，不用绕一圈 `await`，
    /// 少掉一次 runloop 往返，按下那一帧就能发出去。
    static var permissionGranted: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// 首次按下时申请麦克风权限；已经授权过则立即返回 true
    static func requestPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .granted { return true }
        if session.recordPermission == .denied { return false }
        return await withCheckedContinuation { continuation in
            session.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - 音频会话

    /// 会话是否已经切到「可录音」并激活。
    ///
    /// 连接期间保持为 true：`VoicePlayer` 看到它就不会把分类切回 `.playback`，
    /// 否则下一次按 PTT 又要重建输入路由。
    private(set) static var talkSessionReady = false

    /// 把会话切到「可录音 + 免提」并激活（幂等，连接期间只做一次）。
    ///
    /// `mixWithOthers` 保留：以前只有播放链有它，PTT 一开就把别的 App 的音乐掐掉，
    /// 松手切回播放又接不上；统一带上之后前后行为才一致。
    /// 万一某个系统版本不接受这个组合，退回不带 mixWithOthers 的版本——录音本身不能丢。
    private static func applyTalkCategory() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        } catch {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
        }
        try session.setActive(true)
    }

    /// 连接成功后调一次：提前把音频会话切到「可录音」。
    ///
    /// 不装 tap、不起引擎，所以不会真的采集、也不会亮麦克风指示灯；
    /// 只是把最贵的那次路由重配挪到「刚连上、用户还在看界面」的时候做掉。
    func prepareForTalk() {
        guard !Self.talkSessionReady else { return }
        do {
            try Self.applyTalkCategory()
            Self.talkSessionReady = true
        } catch {
            // 预热失败不影响功能：`start()` 会再试一次，并把错误抛给调用方。
        }
    }

    // MARK: - 开关

    /// dB → 线性倍数（`pow(10, db/20)`）。0 dB 正好是 1，也就是完全不改采样。
    nonisolated static func linearGain(db: Double) -> Float {
        Float(pow(10, min(24, max(-12, db)) / 20))
    }

    func start() throws {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        if Self.talkSessionReady {
            // 只是把已经配好的会话重新激活（被电话之类打断过才需要）。
            try session.setActive(true)
        } else {
            try Self.applyTalkCategory()
            Self.talkSessionReady = true
        }

        // **发射期间不换 mode。**
        //
        // 以前这里会 `setMode(.voiceChat)`（AGC + 降噪），松手再换回 `.default`。
        // 问题不在语音质量，在副作用：换 mode 会让系统重建一次 IO 单元，
        // 而本 App 同时还有一个**播放**用的 `AVAudioEngine` 在跑，它会被这次重建
        // 连带停掉（DMR 模式下这正是「按一下 PTT 之后再也没声音」的开关）。
        // DroidStar 的 iOS 实现（iosaudiosession.mm）也只在本机设一次
        // `.playAndRecord + .defaultToSpeaker`，全程不再改 mode。
        // 增益与降噪我们自己处理（见 `gain`），不需要系统那套。

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let target = targetFormat,
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "DMRPilot.PttMicrophone", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "麦克风输入格式不可用（可能是权限被拒绝或没有输入设备）"
            ])
        }
        self.converter = converter
        pending.removeAll(keepingCapacity: true)
        level = 0
        // 每次按下都从 1 倍开始：上一句收尾时的增益不该带进新的一句。
        autoGainValue = 1
        lastPeak = 0
        inputPeakSum = 0
        outputPeakSum = 0
        gainSum = 0
        voicedFrameCount = 0
        averageInputPeak = 0
        averageOutputPeak = 0
        averageGain = 1

        // 输入格式一定要打出来：多声道时 `AVAudioConverter` 会做下混，
        // iPhone 多个麦克风之间如果有相位差，下混会互相抵消 —— 那是「电平莫名很低」
        // 最隐蔽的一种成因，光看峰值数字分辨不出来。
        onEvent?(String(format: "🎙️ 采集格式：%.0f Hz × %d 声道（%@）→ 8000 Hz 单声道 Int16",
                        inputFormat.sampleRate,
                        Int(inputFormat.channelCount),
                        inputFormat.isInterleaved ? "交织" : "非交织"))

        // `target` / `converter` 都先取成局部常量再进闭包：采集回调在别的线程，
        // 直接读主线程隔离的属性会被并发检查挑出来，也没有必要。
        // 装之前先确保没有残留（重复 installTap 会抛 ObjC 异常）。
        removeTapIfNeeded()
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = PttMicrophone.convert(buffer: buffer, using: converter, target: target)
            guard !samples.isEmpty else { return }
            Task { @MainActor in
                self.consume(samples)
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTapIfNeeded()
            self.converter = nil
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        removeTapIfNeeded()
        engine.stop()
        converter = nil
        pending.removeAll(keepingCapacity: false)
        level = 0

        // 结算成平均值。日志要用它，而逐帧除法没必要留在采集路径上。
        // 只统计过了噪声门的帧：把「说话间隙的底噪」也算进去会把平均值拉得没意义。
        if voicedFrameCount > 0 {
            let n = Double(voicedFrameCount)
            averageInputPeak = Float(inputPeakSum / n)
            averageOutputPeak = Float(outputPeakSum / n)
            averageGain = Float(gainSum / n)
        }

        // 会话**不**切回 `.playback`，也**不**换 mode：切分类会把输入 IO 单元拆掉，
        // 下次按下又要重建，那 0.3～0.5 秒就是「按住半天才开始发」；换 mode 则会
        // 重建 IO，把同时在跑的播放引擎一起停掉（见 `start()` 里的说明）。
        // 真正还原放在 `release()`（断开连接时）。
    }

    /// 断开连接时调用：把会话还给纯播放。
    func release() {
        stop()
        Self.talkSessionReady = false
        // 和 `VoicePlayer` 里一致：守听走纯播放，不要留在录音路由上。
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        // 关掉「语音播放」时 VoicePlayer 不会去停会话，这里顺手把会话交还出去，
        // 否则断开之后本 App 还占着音频硬件不放。
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - 内部

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func consume(_ samples: [Int16]) {
        // 引擎没在跑时（守听期间）残留的缓冲区一律丢掉，
        // 否则一按下就先把几帧旧音频发出去。
        guard running else { return }

        pending.append(contentsOf: samples)

        // 按整帧处理，不按「这一批到达的采样」处理：
        // 自动增益要在一帧（20 ms）的峰值上做判断，而 tap 每次给的是 1024 帧
        // （8 kHz 下约 170 采样），跨帧时峰值会算错档。
        while pending.count >= PttMicrophone.frameSamples {
            var frame = Array(pending[0..<PttMicrophone.frameSamples])
            pending.removeFirst(PttMicrophone.frameSamples)

            // 原始峰值先量一次：自动增益要用它判断，诊断日志也用它。
            var rawPeak: Float = 0
            for v in frame {
                let a = abs(Float(v))
                if a > rawPeak { rawPeak = a }
            }
            if rawPeak > lastPeak { lastPeak = rawPeak }

            // 顺序很关键：先自动增益（看原始电平），再乘手动增益。
            // 反过来的话，用户把滑杆推高之后自动增益会立刻把它的效果抵掉。
            if autoGain {
                applyAutoGain(&frame, rawPeak: rawPeak)
            }
            if gain != 1 {
                for i in frame.indices {
                    let scaled = (Float(frame[i]) * gain).rounded()
                    frame[i] = Int16(max(-32768, min(32767, scaled)))
                }
            }

            // 电平表用处理后的采样：表上看到的音量就是对端听到的音量。
            var peak: Float = 0
            for v in frame {
                let a = abs(Float(v))
                if a > peak { peak = a }
            }
            // 满幅约 -6 dB（20000）就打满
            level = min(1, peak / 20000)

            // 统计只在「有人在说」的帧上做（噪声门之外），否则间隙里的底噪会把均值拉偏。
            if rawPeak >= PttMicrophone.agcGate {
                inputPeakSum += Double(rawPeak)
                outputPeakSum += Double(peak)
                gainSum += Double(autoGainValue)
                voicedFrameCount += 1
            }

            onFrame?(frame)
        }
    }

    /// 一帧（160 采样）的自动增益，目标是峰值不低于 `agcTarget`。
    ///
    /// **只提不压**，这一点很重要：早先的版本在输入超过目标时会把增益降到 0.25
    /// 来「防削顶」，结果麦克风电平本来就够的时候被硬压了十几 dB，
    /// 现场表现正是「加了自动增益反而更小」。现在下限锁在 1：
    /// - 峰值低于目标 → 按差额提上来（上限 `agcMaxGain`）；
    /// - 峰值已经高于目标 → 保持 1 倍，原样送编码器。
    /// 这样永远不可能因为增益而削顶（输出峰值 ≤ max(输入峰值, 目标)），
    /// 也就不需要衰减这一路。
    ///
    /// 另外两条节奏：提升慢（`agcAttack`，约 80 ms），噪声门一触发就快回落
    /// （`agcRelease`，约 60 ms）—— 否则一句话说完的间隙里，放大了二十几倍的
    /// 底噪会拖出一段沙沙的尾巴。
    private func applyAutoGain(_ frame: inout [Int16], rawPeak: Float) {
        if rawPeak < PttMicrophone.agcGate {
            // 没人在说：往回收到 1 倍，别把底噪带进下一句的开头。
            autoGainValue = max(1, autoGainValue * PttMicrophone.agcRelease)
        } else {
            let wanted = max(1, min(PttMicrophone.agcMaxGain,
                                    PttMicrophone.agcTarget / rawPeak))
            if wanted < autoGainValue {
                // 突然大声了：立刻松回 1 倍，不能让上一句的放大继续顶着
                autoGainValue = wanted
            } else {
                autoGainValue += (wanted - autoGainValue) * PttMicrophone.agcAttack
            }
        }

        guard autoGainValue != 1 else { return }
        for i in frame.indices {
            let scaled = (Float(frame[i]) * autoGainValue).rounded()
            frame[i] = Int16(max(-32768, min(32767, scaled)))
        }
    }

    /// 把硬件格式的缓冲转成 8 kHz 单声道 Int16
    private nonisolated static func convert(buffer: AVAudioPCMBuffer,
                                            using converter: AVAudioConverter?,
                                            target: AVAudioFormat) -> [Int16] {
        guard let converter else { return [] }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return [] }
        guard let channel = out.int16ChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}
