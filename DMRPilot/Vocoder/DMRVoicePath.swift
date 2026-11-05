//
//  DMRVoicePath.swift
//  DMRPilot
//
//  DMR 语音链路：一个 DMRD 包里的 33 字节载荷 → 3 个 9 字节 AMBE+2 空中帧
//  → halfrate 声码器 → 480 个 8 kHz PCM 采样（3 × 20 ms）。
//
//  拆帧规则移植自 DroidStar 的 dmr.cpp（process_udp 里的 dmr3ambe 重排）：
//  216 个语音比特分布在载荷的 0..13 与 20..32 字节，第 13 字节低半字节是嵌入信令，
//  要换成第 19 字节的低半字节，拼成连续的 27 字节，正好 3 个 72 比特帧。
//

import Foundation

struct DMRVoicePath {

    /// 每个 DMRD 语音包解出的采样数（3 帧 × 160）
    static let samplesPerPacket = 3 * HRCore.frameSamples

    /// 33 字节载荷 → 3 个 9 字节空中帧
    static func unpackFrames(_ payload: [UInt8]) -> [[UInt8]] {
        guard payload.count >= 33 else { return [] }

        var packed = [UInt8](repeating: 0, count: 27)
        for i in 0..<14 {
            packed[i] = payload[i]
        }
        // 第 13 字节的低半字节是嵌入信令，换成载荷第 19 字节的低半字节
        packed[13] &= 0xf0
        packed[13] |= payload[19] & 0x0f
        for i in 0..<13 {
            packed[14 + i] = payload[20 + i]
        }

        return [
            Array(packed[0..<9]),
            Array(packed[9..<18]),
            Array(packed[18..<27]),
        ]
    }
}

/// 有状态的语音解码器：一次通话一个实例，跨帧保留预测器与合成器状态。
final class DMRVoiceDecoder {

    private let decoder = HRDecoder()
    private(set) var lastErrorCount = 0

    func reset() {
        decoder.reset()
        lastErrorCount = 0
    }

    /// 返回 480 个 8 kHz 采样；载荷不合法时返回空数组
    func decode(packet payload: [UInt8]) -> [Int16] {
        let frames = DMRVoicePath.unpackFrames(payload)
        guard !frames.isEmpty else { return [] }

        var output = [Int16]()
        output.reserveCapacity(DMRVoicePath.samplesPerPacket)

        var pcm = [Int16](repeating: 0, count: HRCore.frameSamples)
        for frame in frames {
            let result = HRFec.decodeAirFrame(frame)
            lastErrorCount = result.errors
            decoder.decode(bits: result.bits, pcm: &pcm)
            output.append(contentsOf: pcm)
        }
        return output
    }
}
