//
//  DMRVoicePath.swift
//  DMRPilot
//
//  DMR 语音链路：27 字节 AMBE+2 空中数据 → 480 个 8 kHz PCM 采样（3 × 20 ms）。
//
//  这 27 字节由 C++ 核心从 33 字节 DMRD 载荷里拆出来（Core/DMRCore.cpp）：
//
//      载荷 0…12       ← 前 108 bit 语音
//      载荷 13 高半字节 ← 接着的 4 bit
//      载荷 19 低半字节 ← 后 108 bit 的头 4 bit
//      载荷 20…32      ← 后 104 bit
//
//  中间的 48 bit（载荷 13 低半字节 + 14…18 + 19 高半字节）是同步字或嵌入信令，
//  不属于语音。ODTP / Rewind 那条链路更直接：0x0920 的载荷本身就是这 27 字节。
//
//  ── 解码器 ──────────────────────────────────────────────────────────
//
//  解码走 `Core/Vocoder/` 里那套 DroidStar 的 `mbe/halfrate` 原文件，经
//  `Core/HRCore.h` 的 `hrd_*` 接口调用。也就是说**同一份源码、同一组参数**：
//  DroidStar 的 `MBEVocoder::decode_2450x1150()` 第一行就是 `ambe2_decode_packed()`，
//  它最终也落到 `hr_decode_air()`，参数表见 HRCore.cpp 里的 `kDecoderTuning`。
//
//  以前这里是纯 Swift 移植（HalfrateDecoder / Dequant / Synth / Fec，约 1700 行），
//  逐位核对过码本与相位，但浮点舍入、索引顺序这些地方无法在 Windows 上验证，
//  上线后一旦听感不对就得靠猜。换成原文件后这层风险直接消失。
//

import Foundation

enum DMRVoicePath {

    /// 一帧 20 ms 的采样数（160）
    static let samplesPerFrame = Int(HRD_SAMPLES_PER_FRAME)

    /// 一个 DMR 突发（3 帧）的采样数（480）
    static let samplesPerPacket = Int(HRD_SAMPLES_PER_PACKET)

    /// 一个突发需要的 codec 字节数（27 = 3 × 9）
    static let codecBytes = Int(HRD_FRAMES_PER_PACKET) * Int(HRD_AIR_BYTES)

    /// 27 字节 → 3 个 9 字节空中帧。调试 / 日志用，解码本身由核心一次吃掉 27 字节。
    static func frames(from codec: [UInt8]) -> [[UInt8]] {
        guard codec.count >= codecBytes else { return [] }
        return [
            Array(codec[0..<9]),
            Array(codec[9..<18]),
            Array(codec[18..<27]),
        ]
    }
}

/// 有状态的语音解码器：一次通话一个实例，跨帧保留预测器、相位与增强滤波器状态。
///
/// halfrate 是强状态的：混用两路会把两个说话人的状态搅在一起，听起来像机器人抽搐。
/// 所以每一路通话都要有自己的一份（见 VoicePipeline）。
final class DMRVoiceDecoder {

    /// C++ 解码器句柄。`hrd_create()` 只会在内存分配失败时返回 nil。
    private let core = hrd_create()

    /// 最近一个包纠正掉的比特数（三帧之和），0 表示空口很干净
    private(set) var lastErrorCount = 0

    /// 最近一个包的帧类型，见 HRD_KIND_*
    private(set) var lastKind: Int32 = 0

    /// 核心没能建起来（内存耗尽 / 编译期漏了 Vocoder 文件）
    var isAvailable: Bool { core != nil }

    deinit {
        hrd_destroy(core)
    }

    /// 回到开始状态：清掉跨帧预测、合成器相位、擦除计数与高通，调好的参数保留。
    func reset() {
        hrd_reset(core)
        lastErrorCount = 0
        lastKind = 0
    }

    /// 返回 480 个 8 kHz 采样；数据不完整或解码器不可用时返回空数组。
    func decode(codec: [UInt8]) -> [Int16] {
        guard codec.count >= DMRVoicePath.codecBytes, let core = core else { return [] }

        var pcm = [Int16](repeating: 0, count: DMRVoicePath.samplesPerPacket)
        var errors: Int32 = 0

        let kind = codec.withUnsafeBufferPointer { raw in
            hrd_decode_packet(core, raw.baseAddress, &pcm, &errors)
        }

        guard kind != HRD_ERROR else { return [] }

        lastKind = kind
        lastErrorCount = Int(max(0, errors))
        return pcm
    }

    /// 一个 **7 字节**帧（49 bit，无 FEC）→ 160 个采样。
    ///
    /// YSF 的 VD 模式 2：纠错在 `Core/YSFCore.cpp` 解 VCH 时已经做完了
    /// （Golay / 卷积码 / 重复码），到这儿只剩干净的参数，直接进解码器。
    func decode(frame7: [UInt8]) -> [Int16] {
        guard frame7.count >= 7, let core = core else { return [] }

        var pcm = [Int16](repeating: 0, count: DMRVoicePath.samplesPerFrame)
        var errors: Int32 = 0

        let kind = frame7.withUnsafeBufferPointer { raw in
            hrd_decode_plain(core, raw.baseAddress, &pcm, &errors)
        }

        guard kind != HRD_ERROR else { return [] }

        lastKind = kind
        lastErrorCount = Int(max(0, errors))
        return pcm
    }
}
