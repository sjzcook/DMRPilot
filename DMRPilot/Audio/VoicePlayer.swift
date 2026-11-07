//
//  VoicePlayer.swift
//  DMRPilot
//
//  8 kHz / 16 bit / 单声道 PCM 的实时播放。
//  AVAudioEngine 负责把 8 kHz 升采样到硬件采样率，再送扬声器。
//
//  设计要点：
//  - 引擎只在第一次 start() 时 attach/connect 一次，之后反复 start/stop 不会重复连接；
//  - 每个 buffer 排进去时 pendingFrames 加、播完回调时减，积压超过 1 秒就丢新包，
//    否则网络抖动之后延迟会一路累积，听起来越来越“慢半拍”；
//  - flush() 用于通话结束，直接丢掉还没播的尾巴，不做淡出。
//

import AVFoundation
import Foundation

@MainActor
final class VoicePlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat?

    /// 后台保活用的第二条通道（循环播静音），详见 `startKeepAlive()`。
    private let keepAlive = AVAudioPlayerNode()
    private var keepAliveAttached = false
    private var keepAliveBuffer: AVAudioPCMBuffer?

    private var isRunning = false
    private var isAttached = false
    private var pendingFrames = 0
    /// 最近一次配置 AVAudioSession 的失败原因，成功时为 nil。
    /// 这段失败以前被静默吞掉，症状就是「有通话但完全没声音」，所以留出来给界面提示。
    private(set) var audioSessionError: String?
    /// 引擎启动失败次数。push 每个语音包都会试着调 start()，
    /// 如果硬件真的起不来，不拦住就会 25 次/秒反复尝试。
    private var startFailures = 0

    /// 队列里积压超过这个采样数就不再入队，避免延迟越拖越长（8000 = 1 秒）
    private let maxPendingFrames = 8000
    private let maxStartFailures = 3

    var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    /// 当前是否有声音在排队（用来驱动 UI 的电平指示）
    var isActive: Bool { isRunning && pendingFrames > 0 }

    init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8000,
            channels: 1,
            interleaved: true
        )
    }

    // MARK: - 生命周期

    func start() {
        guard !isRunning else { return }
        guard startFailures < maxStartFailures else { return }
        guard let format else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // 只用 .playback + .default：`.voiceChat` 这个 mode 是给 .playAndRecord 的，
            // 和 .playback 组合属于非法搭配，setCategory 会抛错 —— 抛错后 session 就停在
            // 系统默认的 soloAmbient（会被响铃/静音键静音），表现正是「连上了、有通话、
            // 却一点声音都没有」。mixWithOthers 让本 App 不打断用户正在听的音乐。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionError = nil
        } catch {
            // 会话起不来时仍然尝试启动引擎，真正的失败会在 engine.start() 暴露
            audioSessionError = error.localizedDescription
        }
        #endif

        if !isAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isAttached = true
        }

        if !keepAliveAttached {
            engine.attach(keepAlive)
            engine.connect(keepAlive, to: engine.mainMixerNode, format: format)
            keepAliveBuffer = Self.silentBuffer(format: format, seconds: 1)
            keepAliveAttached = true
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            isRunning = false
            startFailures += 1
            audioSessionError = "音频引擎启动失败：\(error.localizedDescription)"
            return
        }

        startFailures = 0
        player.volume = volume
        player.play()
        isRunning = true
        startKeepAlive()
    }

    func stop() {
        // 用户主动断开时清掉退避计数，下次连接重新给引擎一次机会
        startFailures = 0

        keepAlive.stop()

        guard isRunning else {
            pendingFrames = 0
            return
        }
        player.stop()
        engine.stop()
        isRunning = false
        pendingFrames = 0

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    // MARK: - 入队

    func enqueue(_ samples: [Int16]) {
        guard isRunning, !samples.isEmpty else { return }
        guard let format else { return }
        guard pendingFrames < maxPendingFrames else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channel = buffer.int16ChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                channel.update(from: base, count: samples.count)
            }
        }

        let count = samples.count
        pendingFrames += count

        player.scheduleBuffer(buffer,
                              at: nil,
                              options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingFrames = max(0, self.pendingFrames - count)
            }
        }

        if !player.isPlaying {
            player.play()
        }
    }

    /// 通话结束时调用：不再等待队列清空，直接丢弃积压
    func flush() {
        guard isRunning else {
            pendingFrames = 0
            return
        }
        player.stop()
        pendingFrames = 0
        player.play()
    }

    // MARK: - 后台保活

    /// 恒定播一条静音，让引擎一直在渲染。
    ///
    /// iOS 只在「真有音频在渲染」的时候才让带 `UIBackgroundModes: audio` 的 App 留在后台。
    /// 守听偏偏是间歇的：连上之后可能几十分钟没人说话，`player` 播完最后一段就空了，
    /// 系统随即把 App 挂起，之后别人再说话就永远收不到——表现正是「切后台就掉线」。
    ///
    /// 这条静音通道是**独立的 player node**，不占用语音那条队列，所以不会给通话加延迟；
    /// 内容全是 0，混进主混音器后听不出任何东西，只是让音频栈保持忙碌。
    private func startKeepAlive() {
        guard let buffer = keepAliveBuffer else { return }
        keepAlive.stop()
        keepAlive.scheduleBuffer(buffer, at: nil, options: [.loops])
        keepAlive.play()
    }

    private static func silentBuffer(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        if let channel = buffer.int16ChannelData?[0] {
            channel.update(repeating: 0, count: Int(frames))
        }
        return buffer
    }
}
