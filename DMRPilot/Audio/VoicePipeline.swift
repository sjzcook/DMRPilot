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
            }
        }
    }

    // MARK: - 内部

    private let player = VoicePlayer()
    private var decoders: [String: DMRVoiceDecoder] = [:]
    private var currentKey: String?

    /// 同时保留的解码器上限。BrandMeister 上一般是单流，给 4 路已经很宽裕。
    private static let maxStreams = 4

    // MARK: - 控制

    /// 通话开始（收到语音头）
    func begin(key: String) {
        // 换了一路：把上一路还没播完的尾巴丢掉，否则新通话要等旧音频播完才出声
        if let previous = currentKey, previous != key {
            player.flush()
        }

        currentKey = key
        activeKey = key
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
        level = 0
        isPlaying = false
        player.flush()
    }

    /// 断线 / 重连：整体复位
    func reset() {
        decoders.removeAll()
        currentKey = nil
        activeKey = nil
        level = 0
        isPlaying = false
        decodedPackets = 0
        lastErrorCount = 0
        player.stop()
    }

    // MARK: - 解码

    /// 送进一个 DMRD 语音突发。
    ///
    /// 注意这里**不**重置解码器：两个时隙可能同时在通话，包会交错到达，
    /// 如果在“接管”时 reset，一路就会被每包重置、永远出不了声。
    /// 重置只发生在语音头（`begin`）和新建解码器的时候。
    func push(key: String, payload: [UInt8]) {
        // 没有当前通话时（比如刚连上就撞进通话中间），由第一个到达的流占位
        if currentKey == nil {
            currentKey = key
            activeKey = key
        }

        let decoder = decoder(for: key)
        let pcm = decoder.decode(packet: payload)
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

        player.start()
        player.enqueue(pcm)
        level = Self.peakLevel(pcm)
        isPlaying = player.isActive
    }

    // MARK: - 辅助

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
