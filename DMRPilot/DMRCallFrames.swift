//
//  DMRCallFrames.swift
//  DMRPilot
//
//  「呼叫」= 向某个通话组发一次极短的 PTT：
//
//      Voice LC Header  →  一个静音语音突发  →  Voice Terminator
//
//  BrandMeister 把热点收到的这次呼叫当作「有人在这个 TG 上发射」，
//  于是把它标记成动态订阅，之后这个组的语音才会推下来。
//  Homebrew 协议本身没有「订阅」指令，这是唯一能让服务器改推某个 TG 的办法。
//
//  语音头的 33 字节不是拼字符串，要三层编码：
//
//      LC(9 字节) ──RS(12,9)──▶ 12 字节 ──BPTC(196,96)──▶ 33 字节
//
//  外加 slot type 的 Golay(20,8) 和数据同步字。全部逐行移植自 MMDVMHost：
//  RS129.cpp / BPTC19696.cpp / Hamming.cpp / Golay2087.cpp / Sync.cpp。
//  算法已用 Python 复现并做过 encode→decode 往返验证（12 字节完全一致）。
//

import Foundation

enum DMRCallCodec {

    // MARK: - GF(256)

    /// 本原多项式 x^8 + x^4 + x^3 + x^2 + 1（0x11D），与 RS129.cpp 的 EXP_TABLE 对上。
    private static let gfExp: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 512)
        var value = 1
        for i in 0..<255 {
            table[i] = UInt8(value)
            value <<= 1
            if value & 0x100 != 0 { value ^= 0x11D }
        }
        for i in 255..<512 { table[i] = table[i - 255] }
        return table
    }()

    private static let gfLog: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<255 { table[Int(gfExp[i])] = UInt8(i) }
        return table
    }()

    private static func gfMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return gfExp[Int(gfLog[Int(a)]) + Int(gfLog[Int(b)])]
    }

    // MARK: - RS(12,9)

    /// 9 字节 LC → 4 字节校验。第 4 个字节是移位留下的，不用。
    private static func rsParity(_ message: [UInt8]) -> [UInt8] {
        let poly: [UInt8] = [64, 56, 14, 1]
        var parity = [UInt8](repeating: 0, count: 4)

        for raw in message {
            let dbyte = raw ^ parity[3]
            var j = 3
            while j > 0 {
                parity[j] = parity[j - 1] ^ gfMultiply(poly[j], dbyte)
                j -= 1
            }
            parity[0] = gfMultiply(poly[0], dbyte)
        }

        return parity
    }

    // MARK: - Golay(20,8)（slot type 用）

    /// ENCODING_TABLE_2087 是线性码，256 项可以由 8 个基向量 XOR 出来，
    /// 所以只存基向量（已用脚本核对过全表 == 基向量组合）。
    private static let golayBasis: [UInt16] = [
        0xB08E, 0xE093, 0x70A9, 0x60DC, 0x7036, 0xD06C, 0x90D9, 0xA03D
    ]

    private static func golayParity(_ value: UInt8) -> UInt16 {
        var result: UInt16 = 0
        for bit in 0..<8 where (value >> UInt8(bit)) & 1 != 0 {
            result ^= golayBasis[bit]
        }
        return result
    }

    // MARK: - BPTC(196,96)

    /// 12 字节（LC + RS 校验）→ 33 字节语音头负载（还差同步字与 slot type，由调用方补）。
    private static func bptcEncode(_ block: [UInt8]) -> [UInt8] {
        var data = [Bool](repeating: false, count: 96)
        for i in 0..<12 {
            for bit in 0..<8 {
                data[i * 8 + bit] = (block[i] >> UInt8(7 - bit)) & 1 != 0
            }
        }

        // 每行 15 bit，行首那个 R(3) 位空着，数据 11 bit（首行 8 bit）
        var deinter = [Bool](repeating: false, count: 196)
        let rows: [(Int, Int)] = [
            (4, 11), (16, 26), (31, 41), (46, 56), (61, 71),
            (76, 86), (91, 101), (106, 116), (121, 131)
        ]
        var position = 0
        for (start, end) in rows {
            for index in start...end {
                deinter[index] = data[position]
                position += 1
            }
        }

        // 每行 Hamming(15,11)
        for row in 0..<9 {
            hamming15113(&deinter, base: row * 15 + 1)
        }

        // 每列 Hamming(13,9)
        for column in 0..<15 {
            var col = [Bool](repeating: false, count: 13)
            for index in 0..<13 {
                col[index] = deinter[column + 1 + index * 15]
            }
            hamming1393(&col)
            for index in 0..<13 {
                deinter[column + 1 + index * 15] = col[index]
            }
        }

        // 交织：raw[(a * 181) % 196] = deinter[a]
        var raw = [Bool](repeating: false, count: 196)
        for a in 0..<196 {
            raw[(a * 181) % 196] = deinter[a]
        }

        // 打包成 33 字节：中间那两个 bit 跨在 byte12 高 2 位与 byte20 低 2 位上
        var out = [UInt8](repeating: 0, count: 33)
        for i in 0..<12 { out[i] = pack(raw, at: i * 8) }

        let crossing = pack(raw, at: 96)
        out[12] = (out[12] & 0x3F) | (crossing & 0xC0)
        out[20] = (out[20] & 0xFC) | ((crossing >> 4) & 0x03)

        for i in 0..<12 { out[21 + i] = pack(raw, at: 100 + i * 8) }

        return out
    }

    private static func pack(_ bits: [Bool], at offset: Int) -> UInt8 {
        var value: UInt8 = 0
        for i in 0..<8 {
            value = (value << 1) | (bits[offset + i] ? 1 : 0)
        }
        return value
    }

    private static func xor(_ values: [Bool]) -> Bool {
        var result = false
        for value in values { result = result != value }
        return result
    }

    private static func hamming15113(_ d: inout [Bool], base: Int) {
        d[base + 11] = xor([d[base], d[base + 1], d[base + 2], d[base + 3],
                            d[base + 5], d[base + 7], d[base + 8]])
        d[base + 12] = xor([d[base + 1], d[base + 2], d[base + 3], d[base + 4],
                            d[base + 6], d[base + 8], d[base + 9]])
        d[base + 13] = xor([d[base + 2], d[base + 3], d[base + 4], d[base + 5],
                            d[base + 7], d[base + 9], d[base + 10]])
        d[base + 14] = xor([d[base], d[base + 1], d[base + 2], d[base + 4],
                            d[base + 6], d[base + 7], d[base + 10]])
    }

    private static func hamming1393(_ d: inout [Bool]) {
        d[9] = xor([d[0], d[1], d[3], d[5], d[6]])
        d[10] = xor([d[0], d[1], d[2], d[4], d[6], d[7]])
        d[11] = xor([d[0], d[1], d[2], d[3], d[5], d[7], d[8]])
        d[12] = xor([d[0], d[2], d[4], d[5], d[8]])
    }

    // MARK: - 语音头 / 结束符

    /// 同步字与保留位掩码。
    ///
    /// **必须用 MS（移动台）那一组。** 热点在 MMDVM 里是 simplex（`duplex = false`），
    /// 参考实现 DroidStar 的 `addDMRDataSync(..., 0)` / `addDMRAudioSync(..., 0)` 走的也是 MS 分支。
    /// 之前这里用了基站（BS）的数据同步字 `0D FF 57 D7 5D F5 D0`，等于告诉对端
    /// 「这是一台中继台发的」—— 对端按 BS 解调，拿到的 LC 是坏的，这次呼叫在别人耳朵里
    /// 根本不存在，动态订阅自然也不会建立。
    private static let dataSync: [UInt8] = [0x0D, 0x5D, 0x7F, 0x77, 0xFD, 0x75, 0x70]
    private static let audioSync: [UInt8] = [0x07, 0xF7, 0xD5, 0xDD, 0x57, 0xDF, 0xD0]
    private static let syncMask: [UInt8] = [0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0]

    /// 语音头（`isTerminator == false`）或带 LC 的结束符的 33 字节负载。
    ///
    /// LC 布局（DMRLC::getData）：
    ///     [0] FLCO（0x00 组呼 / 0x03 单呼）  [1] FID  [2] 服务选项
    ///     [3…5] 目的地址（TG 或对方 ID）     [6…8] 源地址
    static func voicePayload(dst: Int,
                             src: Int,
                             isTerminator: Bool,
                             colorCode: UInt8 = 1) -> [UInt8] {
        var lc = [UInt8](repeating: 0, count: 9)
        lc[0] = 0x00                                            // FLCO：组呼
        lc[1] = 0x00                                            // FID：ETSI
        lc[2] = 0x00                                            // 服务选项
        lc[3] = UInt8((dst >> 16) & 0xFF)
        lc[4] = UInt8((dst >> 8) & 0xFF)
        lc[5] = UInt8(dst & 0xFF)
        lc[6] = UInt8((src >> 16) & 0xFF)
        lc[7] = UInt8((src >> 8) & 0xFF)
        lc[8] = UInt8(src & 0xFF)

        let parity = rsParity(lc)
        // 头与结束符的校验字节要各自异或一个常数，接收端靠它区分帧类型
        let mask: UInt8 = isTerminator ? 0x99 : 0x96
        let block = lc + [parity[2] ^ mask, parity[1] ^ mask, parity[0] ^ mask]

        var out = bptcEncode(block)

        // slot type：高 4 位色码，低 4 位数据类型（1 = 语音头，2 = 结束符）
        let dataType: UInt8 = isTerminator ? 2 : 1
        let slotType = ((colorCode << 4) & 0xF0) | (dataType & 0x0F)
        let check = golayParity(slotType)
        let low = UInt8(check & 0xFF)
        let high = UInt8(check >> 8)

        out[12] = (out[12] & 0xC0) | ((slotType >> 2) & 0x3F)
        out[13] = (out[13] & 0x0F) | ((slotType << 6) & 0xC0) | ((low >> 2) & 0x30)
        out[19] = (out[19] & 0xF0) | ((low >> 2) & 0x0F)
        out[20] = (out[20] & 0x03) | ((low << 6) & 0xC0) | ((high >> 2) & 0x3C)

        // 同步字只覆盖掩码为 1 的那些位，slot type 的位要留着
        for i in 0..<7 {
            out[13 + i] = (out[13 + i] & ~syncMask[i]) | dataSync[i]
        }

        return out
    }

    /// 一个静音语音突发（33 字节），按突发序号决定该放「同步字」还是「嵌入信令」。
    ///
    /// 底料是 MMDVMHost 的 `DMR_SILENCE_DATA`，它**不含同步字**（第 13…19 字节是
    /// `60 00 00 00 00 00 01` 这类残值）。DMR 把一个超帧拆成 6 个突发：
    ///
    ///     n = (m_dmrcnt − 1) % 6
    ///     n == 0 → 这 7 个字节放音频同步字（flags 低 4 位 0x10）
    ///     n != 0 → 放嵌入信令 DMREMB（色码 + LCSS），flags 低 4 位就是 n
    ///
    /// 对应 DroidStar 的 `encode_data()` / `get_emb_data()`。之前这里不看序号，
    /// 一律写同步字：对端会在不该有同步的位置读到同步，整段语音解不出来。
    static func silenceBurst(index: Int, colorCode: Int = 1) -> [UInt8] {
        var out = rawSilence
        let n = ((index % 6) + 6) % 6

        if n == 0 {
            for i in 0..<7 {
                out[13 + i] = (out[13 + i] & ~syncMask[i]) | audioSync[i]
            }
            return out
        }

        // DMREMB[0] = 色码 << 4 | LCSS << 1，DMREMB[1] = 0（静音，没有嵌入 LC）
        let emb0 = UInt8((colorCode << 4) & 0xF0)
        let emb1: UInt8 = 0x00
        out[13] = (out[13] & 0xF0) | ((emb0 >> 4) & 0x0F)
        out[14] = (out[14] & 0x0F) | ((emb0 << 4) & 0xF0)
        out[15] = 0x00
        out[16] = 0x00
        out[17] = 0x00
        out[18] = (out[18] & 0xF0) | ((emb1 >> 4) & 0x0F)
        out[19] = (out[19] & 0x0F) | ((emb1 << 4) & 0xF0)
        return out
    }

    private static let rawSilence: [UInt8] = [
        0xB9, 0xE8, 0x81, 0x52, 0x61, 0x73, 0x00, 0x2A, 0x6B, 0xB9, 0xE8,
        0x81, 0x52, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x73, 0x00,
        0x2A, 0x6B, 0xB9, 0xE8, 0x81, 0x52, 0x61, 0x73, 0x00, 0x2A, 0x6B
    ]
}

// MARK: - DMRD 出站帧

extension HB {

    /// 55 字节标准 DMRD 帧，与 MMDVMHost `CDMRNetwork::write` 逐字节一致。
    ///
    /// ```
    /// 0..3   "DMRD"
    /// 4      seq
    /// 5..7   src（3 字节）
    /// 8..10  dst（3 字节）
    /// 11..14 peer（4 字节，热点自己的 ID）
    /// 15     flags：slot(0x80) | 单呼(0x40) | dataSync(0x20) | 数据类型
    /// 16..19 streamId（**4 字节**，不是 2 字节）
    /// 20..52 payload（33 字节）
    /// 53     BER
    /// 54     RSSI
    /// ```
    ///
    /// 之前这里写成「53 字节、streamId 2 字节、payload 从 18 开始」，整体错位 2 字节：
    /// master 按偏移 20 取载荷，读到的就是错位的 LC，语音头解析失败，动态订阅建不起来。
    static func dmrFrame(seq: UInt8,
                         src: Int,
                         dst: Int,
                         peer: Int,
                         flags: UInt8,
                         streamId: UInt32,
                         payload: [UInt8]) -> Data {
        var buffer = [UInt8](repeating: 0, count: 55)

        buffer[0] = 0x44    // D
        buffer[1] = 0x4D    // M
        buffer[2] = 0x52    // R
        buffer[3] = 0x44    // D
        buffer[4] = seq

        buffer[5] = UInt8((src >> 16) & 0xFF)
        buffer[6] = UInt8((src >> 8) & 0xFF)
        buffer[7] = UInt8(src & 0xFF)

        buffer[8] = UInt8((dst >> 16) & 0xFF)
        buffer[9] = UInt8((dst >> 8) & 0xFF)
        buffer[10] = UInt8(dst & 0xFF)

        buffer[11] = UInt8((peer >> 24) & 0xFF)
        buffer[12] = UInt8((peer >> 16) & 0xFF)
        buffer[13] = UInt8((peer >> 8) & 0xFF)
        buffer[14] = UInt8(peer & 0xFF)

        buffer[15] = flags

        buffer[16] = UInt8((streamId >> 24) & 0xFF)
        buffer[17] = UInt8((streamId >> 16) & 0xFF)
        buffer[18] = UInt8((streamId >> 8) & 0xFF)
        buffer[19] = UInt8(streamId & 0xFF)

        for i in 0..<min(33, payload.count) {
            buffer[20 + i] = payload[i]
        }

        buffer[53] = 0      // BER
        buffer[54] = 0      // RSSI

        return Data(buffer)
    }
}
