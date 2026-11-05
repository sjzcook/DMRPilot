//
//  HalfrateFec.swift
//  DMRPilot
//
//  49 比特帧与 72 比特 DMR 空口帧之间的转换：帧内字段布局、Golay(23,12)+奇偶校验、
//  23 比特扰码、DMR 的 4×18 交织。
//
//  移植自 DroidStar 的 mbe/frame.cc、mbe/fec.cc、mbe/frame_layout.cc。
//

import Foundation

// MARK: - 字段索引

enum HRField {
    static let pitch = 0
    static let voicing = 1
    static let gain = 2
    static let shapeLow = 3
    static let shapeHigh = 4
    static let detail1 = 5  // 5...8 对应 4 个 block
    static let count = 9
}

// MARK: - 帧布局

enum HRFrame {

    /// 7 字节（MSB 优先）→ 49 比特，一比特一字节
    static func bitsFromBytes(_ frame: [UInt8]) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: HRCore.frameBits)
        for i in 0..<HRCore.frameBits {
            bits[i] = (frame[i >> 3] >> (7 - (i & 7))) & 1
        }
        return bits
    }

    /// 49 比特 → 7 字节
    static func bytesFromBits(_ bits: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: HRCore.frameBytes)
        for i in 0..<HRCore.frameBits {
            frame[i >> 3] |= (bits[i] & 1) << (7 - (i & 7))
        }
        return frame
    }

    /// 49 比特 → 9 个参数字段
    static func fieldsFromBits(_ bits: [UInt8]) -> [Int32] {
        var fields = [Int32](repeating: 0, count: HRField.count)
        for f in 0..<HRField.count {
            let width = Int(HRTables.fieldWidth[f])
            var value: UInt32 = 0
            for k in 0..<width {
                let position = Int(HRTables.fieldBitPosition[f * 9 + k])
                value = (value << 1) | UInt32(bits[position] & 1)
            }
            fields[f] = Int32(value)
        }
        return fields
    }

    /// 9 个参数字段 → 49 比特
    static func bitsFromFields(_ fields: [Int32]) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: HRCore.frameBits)
        for f in 0..<HRField.count {
            let width = Int(HRTables.fieldWidth[f])
            let value = UInt32(bitPattern: fields[f])
            for k in 0..<width {
                let position = Int(HRTables.fieldBitPosition[f * 9 + k])
                bits[position] = UInt8((value >> (width - 1 - k)) & 1)
            }
        }
        return bits
    }

    /// 旋转布局 → 标准布局（比特 40..43 循环移位，其余原样）
    static func standardFromRotated(_ rotated: [UInt8]) -> [UInt8] {
        var standard = rotated
        let b40 = rotated[40], b41 = rotated[41], b42 = rotated[42], b43 = rotated[43]
        standard[40] = b43
        standard[41] = b40
        standard[42] = b41
        standard[43] = b42
        return standard
    }
}

// MARK: - FEC

enum HRFec {

    /// DMR 交织：码位 i 落在信道位 4i - 71·floor(i/18)
    @inline(__always)
    static func channelPosition(_ i: Int) -> Int {
        4 * i - 71 * (i / 18)
    }

    /// 12 个数据比特的 11 个校验比特
    static func golay23Parity(_ data: UInt32) -> UInt32 {
        var parity: UInt32 = 0
        for i in 0..<12 {
            if (data >> (11 - i)) & 1 != 0 {
                parity ^= HRTables.golayParity[i]
            }
        }
        return parity
    }

    /// 解 (23,12) 码字（数据在 22..11，校验在 10..0），返回纠正后的 12 位数据
    static func golay23Decode(_ code: UInt32) -> (data: UInt32, errors: Int) {
        var data = (code >> 11) & 0xfff
        let syndrome = (golay23Parity(data) ^ code) & 0x7ff
        let correction = HRTables.golaySyndrome[Int(syndrome)] & 0xfff
        data ^= correction
        let left = (golay23Parity(data) ^ code) & 0x7ff
        return (data, left.nonzeroBitCount + correction.nonzeroBitCount)
    }

    /// 第二段 Golay 的 23 比特扰码，由第一段 12 位数据决定
    static func scrambleMask(_ firstData: UInt32) -> UInt32 {
        var state = firstData << 4
        var mask: UInt32 = 0
        for _ in 0..<23 {
            let value = state &* 173 &+ 13849
            state = value & 0xffff
            mask = (mask << 1) | ((value >> 15) & 1)
        }
        return mask
    }

    /// 72 信道比特 → 49 帧比特。返回纠错总数，第一个码字不可靠时返回 -1
    static func decodeBits(_ bits72: [UInt8], _ bits49: inout [UInt8]) -> Int {
        var code = [UInt8](repeating: 0, count: 72)
        for i in 0..<72 {
            code[i] = bits72[channelPosition(i)] & 1
        }

        var word: UInt32 = 0
        for i in 0..<23 {
            word = (word << 1) | UInt32(code[i])
        }
        let first = golay23Decode(word)
        let corrected0 = (golay23Parity(first.data) & 0x7ff) | (first.data << 11)
        let parity = (corrected0 & 0x7fffff).nonzeroBitCount & 1

        word = 0
        for i in 24..<47 {
            word = (word << 1) | UInt32(code[i])
        }
        let second = golay23Decode(scrambleMask(first.data) ^ word)

        for i in 0..<12 {
            bits49[i] = UInt8((first.data >> (11 - i)) & 1)
        }
        for i in 0..<12 {
            bits49[12 + i] = UInt8((second.data >> (11 - i)) & 1)
        }
        for i in 0..<25 {
            bits49[24 + i] = code[47 + i]
        }

        if first.errors >= 3 && parity != Int(code[23]) {
            return -1
        }
        return second.errors + first.errors
    }

    /// 9 字节空口帧 → 49 比特。返回值同 decodeBits
    static func decodeAirFrame(_ air: [UInt8]) -> (bits: [UInt8], errors: Int) {
        var bits72 = [UInt8](repeating: 0, count: 72)
        for i in 0..<72 {
            bits72[i] = (air[i >> 3] >> (7 - (i & 7))) & 1
        }
        var bits49 = [UInt8](repeating: 0, count: HRCore.frameBits)
        let errors = decodeBits(bits72, &bits49)
        return (bits49, errors)
    }
}
