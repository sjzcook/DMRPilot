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
    /// 最近一次启动失败的时刻。连续失败达到上限后不再逐包重试，但也不能就此认死：
    /// 来电 / 其他 App 抢占音频硬件之后，等它让出来就应当自己恢复（见 `start()`）。
    private var lastStartFailureAt: Date?

    /// 系统报过配置变更、还没重建过。
    ///
    /// `engine.isRunning` 在配置变更之后不一定立刻变 false（有时会滞后一拍），
    /// 只靠它判断会出现「看着还在跑、其实早就不出声了」，所以再让通知兜一层。
    private var needsRebuild = false
    private var configObserver: NSObjectProtocol?

    /// 队列里积压超过这个采样数就不再入队，避免延迟越拖越长（8000 = 1 秒）
    private let maxPendingFrames = 8000
    private let maxStartFailures = 3
    /// 连续失败之后的复试间隔（秒）
    private static let retryInterval: TimeInterval = 5

    var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    /// 当前是否有声音在排队（用来驱动 UI 的电平指示）
    var isActive: Bool { isRunning && engine.isRunning && pendingFrames > 0 }

    init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8000,
            channels: 1,
            interleaved: true
        )

        #if os(iOS)
        // 音频硬件配置一变（PTT 切 mode、另一个引擎要输入 IO、来电、插拔耳机），
        // 系统就会把这个引擎停掉。通知里只记账，真正重建放到下一次 `start()`：
        // 变更很可能发生在发射期间，那一刻不该去动音频硬件。
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
        #endif
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        needsRebuild = true
        // 队列里那批 PCM 是按旧采样率排的，播出来会变调，直接丢。
        pendingFrames = 0
    }

    // MARK: - 生命周期

    /// 拉起播放引擎（幂等；每个语音包都会调一次，正常路径只是一次 `engine.isRunning` 判断）。
    ///
    /// **必须能自愈**。`AVAudioEngine` 在音频硬件配置变化时会被系统停掉，而它**不会**
    /// 自己起来：按下 PTT 时 `PttMicrophone` 把会话 mode 从 `.default` 换成 `.voiceChat`
    /// （松手再换回来），同时另一个引擎开始要输入 IO —— 这两件事都会触发配置变更，
    /// 结果就是播放引擎停住。以前这里第一行是 `guard !isRunning else { return }`，
    /// 而 `isRunning` 只由我们自己改，于是状态还写着「在跑」、`start()` 直接返回，
    /// 队列里再也进不去任何 PCM：**接收中按一下 PTT，之后就永远没声音，只能重连**。
    func start() {
        guard let format else { return }
        guard canAttemptStart() else { return }

        // 引擎还活着、也没报过配置变更：只把 player 补起来
        //（`flush()` 之后会出现「引擎在跑、player 停了」）。
        if engine.isRunning && !needsRebuild {
            if !player.isPlaying { player.play() }
            isRunning = true
            return
        }

        // 走到这里说明要重建：要么第一次启动，要么引擎被系统停掉了。
        activateSession()

        if isAttached {
            // 之前正常跑过 → 是配置变更或系统停摆。旧队列里的 PCM 是按旧采样率排的，
            // 放出来会变调；节点上的连接格式也不再保证有效，全部丢掉重来。
            player.stop()
            keepAlive.stop()
            engine.stop()
            pendingFrames = 0
        }
        needsRebuild = false

        if !isAttached {
            engine.attach(player)
            isAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        if !keepAliveAttached {
            engine.attach(keepAlive)
            keepAliveBuffer = Self.silentBuffer(format: format, seconds: 1)
            keepAliveAttached = true
        }
        engine.connect(keepAlive, to: engine.mainMixerNode, format: format)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            isRunning = false
            startFailures += 1
            lastStartFailureAt = Date()
            audioSessionError = "音频引擎启动失败：\(error.localizedDescription)"
            return
        }

        startFailures = 0
        lastStartFailureAt = nil
        isRunning = true
        player.volume = volume
        player.play()
        startKeepAlive()
    }

    /// 是否允许再试一次启动。
    ///
    /// 连续失败 `maxStartFailures` 次之后先停手（避免 25 次/秒地砸硬件），但每隔
    /// `retryInterval` 仍给一次机会：来电、别的 App 抢占音频硬件这类失败都是暂时的，
    /// 等对方让出来就该自己恢复，而不是「这一路从此再也没声音」。
    private func canAttemptStart() -> Bool {
        guard startFailures >= maxStartFailures else { return true }
        guard let last = lastStartFailureAt else { return true }
        return Date().timeIntervalSince(last) >= Self.retryInterval
    }

    /// 会话激活。分类由 `PttMicrophone` 托管（连接期间一直是 `.playAndRecord`），
    /// 这里只保证它还活着 —— 被电话之类打断过才需要重新 `setActive`。
    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if PttMicrophone.talkSessionReady {
            // 连接期间会话已经被 PTT 预热成 .playAndRecord 了，这里只要保证它还活着。
            // 千万别再切回 `.playback`：切回去下次按 PTT 又要重新激活一次路由，
            // 那 0.3～0.5 秒就是用户感觉到的「按住半天才开始发」。
            do {
                try session.setActive(true)
                audioSessionError = nil
            } catch {
                audioSessionError = error.localizedDescription
            }
        } else {
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
        }
        #endif
    }

    func stop() {
        // 用户主动断开时清掉退避计数，下次连接重新给引擎一次机会
        startFailures = 0
        lastStartFailureAt = nil
        needsRebuild = false

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
        // 连接期间会话由 PTT 那边托管（一直保持「可录音」），这里不要再关：
        // 关了下次按下 PTT 又要重新激活一次，那点时间就是「按住半天才开始发」。
        // 真正交还音频硬件放在 `PttMicrophone.release()`（断开连接时）。
        if !PttMicrophone.talkSessionReady {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        #endif
    }

    // MARK: - 入队

    func enqueue(_ samples: [Int16]) {
        // 引擎被系统停掉时排进去的缓冲不会播、也不会回调，只会一直占着 pendingFrames。
        guard isRunning, engine.isRunning, !samples.isEmpty else { return }
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
        pendingFrames = 0
        // 引擎没在跑时 `player.play()` 没有意义（引擎停止状态下还可能抛 ObjC 异常，
        // Swift 接不住）。重建交给下一次 `start()`。
        guard isRunning, engine.isRunning else { return }
        player.stop()
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
