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
//  - `start()`（按下时调）只切录音模式 + 起引擎，`stop()` 只停引擎。
//
//  分类一直是 playAndRecord，输入单元就不会被拆掉，按下时几乎不用等。
//  收听的音质不受影响：监听走 `.default` 模式，只有发射的这几十秒才换成 `.voiceChat`
//  （AGC + 降噪，窄带语音需要）。换 mode 不换分类，不触发路由变更，比切分类便宜得多。
//

import AVFoundation
import Foundation

@MainActor
final class PttMicrophone {

    /// 一帧的采样数（20 ms @ 8 kHz）
    static let frameSamples = 160

    /// 每凑够一帧就回调一次（主线程）
    var onFrame: (@MainActor ([Int16]) -> Void)?
    /// 当前输入电平，0…1（已含增益）。界面用它判断有没有声音进来。
    private(set) var level: Float = 0

    /// 采集后的线性增益，1 = 原样。由 `Settings.micGainDb` 换算而来，发射中改也立刻生效。
    ///
    /// 放在采集这一段而不是编码后：DMR 的 AMBE 编码器吃的是固定 8 kHz 的 PCM，
    /// 增益加在它前面才会真正改变编码出来的谱包络；放在后面就只能改数字，对端听不出差别。
    var gain: Float = 1

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

        // 录音要 AGC + 降噪，所以只在发射期间把 mode 换成 `.voiceChat`。
        // 换 mode 不换分类，路由和输入单元都还在，不会像切分类那样重建一遍。
        try? session.setMode(.voiceChat)

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

        // 会话**不**切回 `.playback`：切走会把输入 IO 单元拆掉，下次按下又要重建，
        // 那 0.3～0.5 秒就是「按住半天才开始发」。只把录音模式换回收听用的 `.default`，
        // 音量/音色和以前守听时一致。真正还原放在 `release()`（断开连接时）。
        try? AVAudioSession.sharedInstance().setMode(.default)
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

        // 先加增益再排队：电平表、编码器、`onFrame` 拿到的都是同一份放大后的采样，
        // 表上看到的音量就和对端听到的一致。
        let shaped: [Int16]
        if gain == 1 {
            shaped = samples
        } else {
            shaped = samples.map { sample -> Int16 in
                let scaled = (Float(sample) * gain).rounded()
                return Int16(max(-32768, min(32767, scaled)))
            }
        }
        pending.append(contentsOf: shaped)

        var sum: Float = 0
        for v in shaped { sum += Float(v) * Float(v) }
        let rms = Float(sqrt(Double(sum / Float(max(shaped.count, 1)))))
        // 0…1 的近似显示刻度：满幅约 -6 dB 就打满
        level = min(1, rms / 6000)

        while pending.count >= PttMicrophone.frameSamples {
            let frame = Array(pending[0..<PttMicrophone.frameSamples])
            pending.removeFirst(PttMicrophone.frameSamples)
            onFrame?(frame)
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
