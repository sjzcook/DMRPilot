//
//  DMRVoicePath.swift
//  DMRPilot
//
//  DMR 语音链路：27 字节 AMBE+2 空中数据 → 3 个 9 字节帧 → halfrate 声码器
//  → 480 个 8 kHz PCM 采样（3 × 20 ms）。
//
//  这 27 字节由 C++ 核心（Core/DMRCore.cpp）从 33 字节 DMRD 载荷里拆出来：
//
//      载荷 0…12       ← 前 108 bit 语音
//      载荷 13 高半字节 ← 接着的 4 bit
//      载荷 19 低半字节 ← 后 108 bit 的头 4 bit
//      载荷 20…32      ← 后 104 bit
//
//  中间的 48 bit（载荷 13 低半字节 + 14…18 + 19 高半字节）是同步字或嵌入信令，
//  不属于语音，所以拆帧时被剔掉。以前这里自己再拆一遍，现在只做「27 → 3 × 9」。
//

import Foundation

struct DMRVoicePath {

    /// 每个 DMRD 语音包解出的采样数（3 帧 × 160）
    static let samplesPerPacket = 3 * HRCore.frameSamples

    /// 27 字节 → 3 个 9 字节空中帧
    static func frames(from codec: [UInt8]) -> [[UInt8]] {
        guard codec.count >= 27 else { return [] }
        return [
            Array(codec[0..<9]),
            Array(codec[9..<18]),
            Array(codec[18..<27]),
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

    /// 返回 480 个 8 kHz 采样；数据不完整时返回空数组
    func decode(codec: [UInt8]) -> [Int16] {
        let frames = DMRVoicePath.frames(from: codec)
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
