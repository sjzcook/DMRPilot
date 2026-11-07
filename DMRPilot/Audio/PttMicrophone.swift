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
//  录音会话用 `.voiceChat` 模式：iPhone 的默认录音链带 AGC 与降噪，对窄带语音
//  更合适；如果换成 `.measurement` 关掉处理，音量会明显偏小。
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
    /// 目标格式：8 kHz、单声道、16 位（`AVAudioFormat` 的初始化可失败，这里按需解包）
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 8000,
                                             channels: 1,
                                             interleaved: true)

    // MARK: - 权限

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

    // MARK: - 开关

    /// dB → 线性倍数（`pow(10, db/20)`）。0 dB 正好是 1，也就是完全不改采样。
    nonisolated static func linearGain(db: Double) -> Float {
        Float(pow(10, min(24, max(-12, db)) / 20))
    }

    func start() throws {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let target = targetFormat else { return }

        let converter = AVAudioConverter(from: inputFormat, to: target)
        self.converter = converter
        pending.removeAll(keepingCapacity: true)
        level = 0

        // `target` / `converter` 都先取成局部常量再进闭包：采集回调在别的线程，
        // 直接读主线程隔离的属性会被并发检查挑出来，也没有必要。
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = PttMicrophone.convert(buffer: buffer, using: converter, target: target)
            guard !samples.isEmpty else { return }
            Task { @MainActor in
                self.consume(samples)
            }
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        pending.removeAll(keepingCapacity: false)
        level = 0
        // 把会话还成播放配置（和 VoicePlayer 里一致），否则守听时扬声器可能还挂在
        // 录音路由上。这里不做 setActive(false)：那会把播放引擎一起停掉。
        try? AVAudioSession.sharedInstance().setCategory(.playback,
                                                        mode: .voiceChat,
                                                        options: [.mixWithOthers])
    }

    // MARK: - 内部

    private func consume(_ samples: [Int16]) {
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
