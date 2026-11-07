//
//  VoicePlayer.swift
//  DMRPilot
//
//  8 kHz / 16 bit / 单声道 PCM 的实时播放。
//  AVAudioEngine 负责把 8 kHz 升采样到硬件采样率，再送扬声器。
//
//  设计要点：
//  - 引擎只在重建时 attach/connect 一次，之后反复 start/stop 不会重复连接；
//  - 每个 buffer 排进去时 pendingFrames 加、播完回调时减，积压超过 1 秒就丢新包，
//    否则网络抖动之后延迟会一路累积，听起来越来越「慢半拍」；
//  - flush() 用于通话结束，直接丢掉还没播的尾巴，不做淡出。
//
//  ── 为什么这里有一大段「自愈」逻辑 ──────────────────────────────────
//
//  按下 PTT 时 `PttMicrophone` 会起第二个 AVAudioEngine 去要输入 IO，系统的音频硬件
//  配置随之改变，**第一个（播放）引擎会被停掉**。而 AVAudioEngine 不会自己恢复，
//  所以这里必须能重建。
//
//  踩过的坑：判断「引擎还在不在跑」不能只看标志位。
//    - 第一版看的是自己的 `isRunning`：引擎死了它还写着 true，于是永远不重建；
//    - 第二版改看 `engine.isRunning`：配置变更之后它也**可能仍是 true**，
//      此时渲染图已经断了，排进去的缓冲既不播完也不回调，队列一路堆到上限后
//      每个包都被静默丢掉 —— 现象就是「服务器在推、电平也在动，但一点声音都没有，
//      而且没有任何报错」。
//
//  唯一可靠的判据是「排进去的缓冲到底播完了没有」，也就是 `lastDrainedAt`。
//  队列有积压却长时间没有一个缓冲播完，就判僵尸，整条重建。
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

    /// 重建链路时的诊断行，交给上层写日志。首次启动不记，只有「本来在跑、后来重建」才记。
    var onEvent: (@MainActor (String) -> Void)?

    /// 引擎启动失败次数。push 每个语音包都会试着调 start()，
    /// 如果硬件真的起不来，不拦住就会 25 次/秒反复尝试。
    private var startFailures = 0
    /// 最近一次启动失败的时刻。连续失败达到上限后不再逐包重试，但也不能就此认死：
    /// 来电 / 其他 App 抢占音频硬件之后，等它让出来就应当自己恢复（见 `canAttemptStart`）。
    private var lastStartFailureAt: Date?

    /// 系统报过配置变更、还没重建过。
    private var needsRebuild = false
    private var configObserver: NSObjectProtocol?

    /// 队列里最后一个缓冲**真正播完**的时刻。
    ///
    /// 这是判断「引擎在跑但没有出声」的唯一可靠依据：`isRunning` 和
    /// `engine.isRunning` 都只是各自记的一笔账，配置变更之后可能都还是 true。
    private var lastDrainedAt: Date?
    /// 最近一次整条重建的时刻。用来压掉「重建过程本身引起的」配置变更通知，
    /// 否则重建 → 通知 → 再重建，来回打架，每个包都被丢掉一轮。
    private var lastRebuildAt: Date?

    /// 队列里积压超过这个采样数就不再入队，避免延迟越拖越长（8000 = 1 秒）
    private let maxPendingFrames = 8000
    private let maxStartFailures = 3
    /// 连续失败之后的复试间隔（秒）
    private static let retryInterval: TimeInterval = 5
    /// 有积压、但这么久没有任何一个缓冲播完 → 判定为僵尸引擎（0.6 秒 = 15 个包）。
    private static let stallTimeout: TimeInterval = 0.6
    /// 刚重建完这段时间里的配置变更通知，归属于重建过程本身。
    private static let rebuildGrace: TimeInterval = 0.4

    var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    /// 当前是否**真的**有声音在放（用来驱动 UI 的电平指示 / 播放状态）
    var isActive: Bool { isRunning && engine.isRunning && pendingFrames > 0 && !stalled() }

    /// 给日志用的一行状态。排查「有收帧没声音」时，它比任何猜测都直接。
    var diagnostics: String {
        let pending = pendingFrames
        let drained: String
        if let last = lastDrainedAt {
            drained = String(format: "%.2f 秒前", Date().timeIntervalSince(last))
        } else {
            drained = "从未"
        }
        return "音频引擎 running=\(isRunning)/\(engine.isRunning)"
            + " player=\(player.isPlaying)"
            + " 队列=\(pending) 帧 上次播完=\(drained)"
            + (pending > 0 && stalled() ? "（疑似卡死）" : "")
    }

    init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8000,
            channels: 1,
            interleaved: true
        )

        #if os(iOS)
        // 音频硬件配置一变（另一个引擎要输入 IO、来电、插拔耳机），系统就会把这个引擎
        // 停掉。通知里只记账，真正重建放到下一次 `start()`：变更很可能发生在发射期间，
        // 那一刻不该去动音频硬件。
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
        // 自己刚重建完这几百毫秒里的通知，往往是重建过程本身引起的（重新激活会话 /
        // 麦克风引擎拆输入）。这时候再记一笔「要重建」，下一个包又会整条重建一次，
        // 每个包都白丢一轮；真实的故障由 `stalled()` 兜底，不会漏。
        if let rebuildAt = lastRebuildAt,
           Date().timeIntervalSince(rebuildAt) < Self.rebuildGrace {
            return
        }
        needsRebuild = true
        // 队列里那批 PCM 是按旧采样率排的，播出来会变调，直接丢。
        pendingFrames = 0
        lastDrainedAt = Date()
    }

    // MARK: - 生命周期

    /// 拉起播放引擎（幂等；每个语音包都会调一次，正常路径只是一次布尔判断）。
    ///
    /// **必须能自愈**：发动机被系统停掉之后要能自己起来，见文件头的说明。
    func start() {
        guard format != nil else { return }
        guard canAttemptStart() else { return }

        // 真的在跑就别碰音频硬件：这行每秒要走 25 次。
        if isRunning, engine.isRunning, !needsRebuild, player.isPlaying {
            return
        }

        rebuild(reason: "启动")
    }

    /// 发射结束：把播放链路整条重建一次。
    ///
    /// 这里**故意不去试探**「引擎是不是还活着」。发射期间会话被重新激活过、
    /// 第二个引擎起停过，`engine.isRunning` 在这个场景下经常骗人（true 但没声音）。
    /// 一次 PTT 只花一趟重建的钱，换掉一整类「松手之后再也听不见」的问题。
    func resumeAfterPtt() {
        // 解静音时 didSet 里的 `start()` 可能刚刚重建过，别连着折腾两次。
        if let rebuildAt = lastRebuildAt,
           Date().timeIntervalSince(rebuildAt) < 0.25,
           isRunning, engine.isRunning, player.isPlaying {
            return
        }
        rebuild(reason: "发射结束")
    }

    /// 整条链路重建：停 → 重连 → 起引擎 → player.play()。
    ///
    /// 之所以连 `connect` 也重做：配置变更之后原来的连接格式不再可信
    /// （采样率、通道数都可能变过），重连比去推断哪里坏了省事，也顺手清掉僵尸状态。
    private func rebuild(reason: String) {
        guard let format else { return }
        guard canAttemptStart() else { return }

        let wasRunning = isRunning

        activateSession()

        // `stop()` 只对已经 attach 过的节点安全 —— 没挂上去就调会抛 ObjC 异常。
        if isAttached { player.stop() }
        if keepAliveAttached { keepAlive.stop() }
        if engine.isRunning { engine.stop() }
        pendingFrames = 0
        needsRebuild = false
        lastDrainedAt = nil

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
        audioSessionError = nil
        isRunning = true
        player.volume = volume
        player.play()
        startKeepAlive()

        let now = Date()
        lastRebuildAt = now
        lastDrainedAt = now

        if wasRunning {
            onEvent?("♻️ 播放链路重建（\(reason)）")
        }
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

    /// 队列有积压，却久到不正常地没有一个缓冲播完 → 引擎在跑但没渲染。
    private func stalled() -> Bool {
        guard pendingFrames > 0 else { return false }
        guard let last = lastDrainedAt else { return true }
        return Date().timeIntervalSince(last) > Self.stallTimeout
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
        lastDrainedAt = nil
        lastRebuildAt = nil

        if keepAliveAttached { keepAlive.stop() }

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
        guard !samples.isEmpty, let format else { return }

        // 引擎状态不对就先修，别往死引擎里排 —— 排进去既不播也不回调，
        // 只会把 pendingFrames 堆满，之后每个包都被上限挡回去（永久静音）。
        if !isRunning || !engine.isRunning || needsRebuild || !player.isPlaying {
            start()
            guard isRunning, engine.isRunning else { return }
        }

        // 有积压、却一直没有缓冲播完 → 引擎在跑但没在渲染（配置变更之后的僵尸态，
        // `engine.isRunning` 仍然写着 true）。这是「服务器在推、却没有声音」最隐蔽的
        // 一种：不报错、电平表照动，只有队列在悄悄堆。这里 0.6 秒判一次，直接重建。
        if stalled() {
            // 刚重建过还是不响（硬件被别的 App 占着之类）就别 0.6 秒一次地砸，
            // 隔一会儿再试；这段时间里丢包即可，反正也放不出来。
            if let rebuildAt = lastRebuildAt,
               Date().timeIntervalSince(rebuildAt) < 1.5 {
                return
            }
            rebuild(reason: "队列有积压但没有输出")
            guard isRunning, engine.isRunning else { return }
        }

        if pendingFrames >= maxPendingFrames {
            // 走到这里说明积压是「网络突发」而不是卡死（卡死上面已经处理了）：
            // 丢掉新包即可，旧的一会儿就播下去了。
            return
        }

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
        // 队列本来是空的 → 这批要重新起播，从现在开始算一个完整的判定窗口。
        // 少了这一行，「上一句话在几分钟前」会被 `stalled()` 当成卡死，每通电话
        // 开头都白重建一次。
        if pendingFrames == 0 { lastDrainedAt = Date() }
        pendingFrames += count

        player.scheduleBuffer(buffer,
                              at: nil,
                              options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingFrames = max(0, self.pendingFrames - count)
                // 这一行是整个自愈逻辑的心跳：能走到这里才说明引擎真的在渲染。
                self.lastDrainedAt = Date()
            }
        }

        if !player.isPlaying {
            player.play()
        }
    }

    /// 通话结束时调用：不再等待队列清空，直接丢弃积压
    func flush() {
        pendingFrames = 0
        lastDrainedAt = Date()
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
