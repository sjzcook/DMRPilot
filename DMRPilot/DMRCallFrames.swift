//
//  DMRCallFrames.swift
//  DMRPilot
//
//  「订阅」= 向某个通话组发一次极短的 PTT（就是 DroidStar 里按一下话筒）：
//
//      Voice LC Header → 6 个语音突发（一个完整超帧，带嵌入 LC）→ Voice Terminator
//
//  BrandMeister 把热点收到的这次发射当作「有人在这个 TG 上说话」，
//  于是把它标记成动态订阅，之后这个组的语音才会推下来。
//  Homebrew 协议本身没有「订阅」指令，这是唯一能让服务器改推某个 TG 的办法。
//
//  为什么必须是一个「完整」的超帧：DMR 的语音头只带一次 LC，接收端/服务器若错过
//  那一帧，就只能靠语音突发里的嵌入信令（每 4 个突发拼回一整段 LC）恢复。
//  参考实现 DroidStar 的 `encode_data()` 每个突发都会写嵌入 LC + `DMREMB`，
//  这里照抄：突发 1…4 带 LC 分片，突发 5 只有 EMB。
//
//  语音头的 33 字节不是拼字符串，要三层编码：
//
//      LC(9 字节) ──RS(12,9)──▶ 12 字节 ──BPTC(196,96)──▶ 33 字节
//
//  外加 slot type 的 Golay(20,8) 和数据同步字。全部逐行移植自 MMDVMHost：
//  RS129.cpp / BPTC19696.cpp / Hamming.cpp / Golay2087.cpp / Sync.cpp。
//
//  注意：**不要只做 encode→decode 往返验证**。编解码两端一起写错时往返照样“通过”，
//  这里就踩过——RS 反馈抽头错了一级，往返一致，但发到空口上整段 LC 都是坏的。
//  正确的验证方式是把 33 字节输出和参考实现逐字节比对（tools/dmr_ref.py 是
//  DroidStar dmr.cpp 的 Python 复刻，已验证语音头/结束符/6 个突发全部一致）。
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
    ///
    /// 逐行对应 MMDVMHost / DroidStar 的 `CRS129::encode`：反馈抽头是
    /// **`parity[NPAR-1]`，也就是 `parity[2]`**，循环只到 `j = 2`，
    /// `parity[3]` 恒为 0。
    ///
    /// 这里曾经写成「反馈取 `parity[3]`、循环从 `j = 3` 开始」，等于多算了一级、
    /// 还把上一轮的余数又异或进 `dbyte`。结果是三个校验字节全错：
    /// 语音头里 12 字节的 RS 码字对不上，接收端 RS 解码失败，这段呼叫在别人耳朵里
    /// 根本不存在（对端只看到一堆无法纠错的 LC）。已用 Python 逐字节比对
    /// DroidStar 的实现确认修正后完全一致。
    private static func rsParity(_ message: [UInt8]) -> [UInt8] {
        let poly: [UInt8] = [64, 56, 14, 1]
        var parity = [UInt8](repeating: 0, count: 4)

        for raw in message {
            let dbyte = raw ^ parity[2]
            var j = 2
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

    // MARK: - 嵌入 LC（语音突发里的信令）

    /// QR(16,7) 编码表，等价于 DroidStar / MMDVM 的 `ENCODING_TABLE_1676`。
    /// 7 bit 信息（色码 + LCSS）→ 16 bit 系统码，写进每个突发的嵌入信令 `DMREMB`。
    ///
    /// 没有这张表，`DMREMB` 就只是裸的 7 个信息位、缺 9 位校验，对端按 DMR 规范
    /// 解嵌入信令时校验失败，会认为这一串突发「没有信令」——色码与 LC 分片全部丢失。
    private static let qr1676: [UInt16] = [
        0x0000, 0x0273, 0x04E5, 0x0696, 0x09C9, 0x0BBA, 0x0D2C, 0x0F5F,
        0x11E2, 0x1391, 0x1507, 0x1774, 0x182B, 0x1A58, 0x1CCE, 0x1EBD,
        0x21B7, 0x23C4, 0x2552, 0x2721, 0x287E, 0x2A0D, 0x2C9B, 0x2EE8,
        0x3055, 0x3226, 0x34B0, 0x36C3, 0x399C, 0x3BEF, 0x3D79, 0x3F0A,
        0x411E, 0x436D, 0x45FB, 0x4788, 0x48D7, 0x4AA4, 0x4C32, 0x4E41,
        0x50FC, 0x528F, 0x5419, 0x566A, 0x5935, 0x5B46, 0x5DD0, 0x5FA3,
        0x60A9, 0x62DA, 0x644C, 0x663F, 0x6960, 0x6B13, 0x6D85, 0x6FF6,
        0x714B, 0x7338, 0x75AE, 0x77DD, 0x7882, 0x7AF1, 0x7C67, 0x7E14,
        0x804F, 0x823C, 0x84AA, 0x86D9, 0x8986, 0x8BF5, 0x8D63, 0x8F10,
        0x91AD, 0x93DE, 0x9548, 0x973B, 0x9864, 0x9A17, 0x9C81, 0x9EF2,
        0xA1F8, 0xA38B, 0xA51D, 0xA76E, 0xA831, 0xAA42, 0xACD4, 0xAEA7,
        0xB01A, 0xB269, 0xB4FF, 0xB68C, 0xB9D3, 0xBBA0, 0xBD36, 0xBF45,
        0xC151, 0xC322, 0xC5B4, 0xC7C7, 0xC898, 0xCAEB, 0xCC7D, 0xCE0E,
        0xD0B3, 0xD2C0, 0xD456, 0xD625, 0xD97A, 0xDB09, 0xDD9F, 0xDFEC,
        0xE0E6, 0xE295, 0xE403, 0xE670, 0xE92F, 0xEB5C, 0xEDCA, 0xEFB9,
        0xF104, 0xF377, 0xF5E1, 0xF792, 0xF8CD, 0xFABE, 0xFC28, 0xFE5B,
    ]

    /// Hamming(16,11,4)：11 个信息位 → 后面补 5 个校验位（`encode16114`）。
    private static func hamming16114(_ d: inout [Bool], base: Int) {
        d[base + 11] = xor([d[base], d[base + 1], d[base + 2], d[base + 3],
                            d[base + 5], d[base + 7], d[base + 8]])
        d[base + 12] = xor([d[base + 1], d[base + 2], d[base + 3], d[base + 4],
                            d[base + 6], d[base + 8], d[base + 9]])
        d[base + 13] = xor([d[base + 2], d[base + 3], d[base + 4], d[base + 5],
                            d[base + 7], d[base + 9], d[base + 10]])
        d[base + 14] = xor([d[base], d[base + 1], d[base + 2], d[base + 4],
                            d[base + 6], d[base + 7], d[base + 10]])
        d[base + 15] = xor([d[base], d[base + 2], d[base + 5], d[base + 6],
                            d[base + 8], d[base + 9], d[base + 10]])
    }

    /// 9 字节 LC → 128 bit 嵌入信令块（DroidStar `encode_embedded_data()`）。
    ///
    /// 128 bit 分两次交给 6 个突发：突发 1…4 各带走 32 bit，突发 5 不带（LCSS=0）。
    /// 这样即使接收端丢了语音头，也能从语音突发里把「谁发给哪个组」拼回来。
    private static func embeddedLC(dst: Int, src: Int) -> [Bool] {
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

        var data = [Bool](repeating: false, count: 128)

        // 5 bit CRC：9 字节求和 mod 31，塞进第 2…6 行的最后一个信息位
        var crc = 0
        for byte in lc { crc += Int(byte) }
        crc %= 31
        data[42] = (crc & 0x10) != 0
        data[58] = (crc & 0x08) != 0
        data[74] = (crc & 0x04) != 0
        data[90] = (crc & 0x02) != 0
        data[106] = (crc & 0x01) != 0

        // 72 个信息位铺进 7 行：前两行 11 位，其余每行 10 位
        var source: [Bool] = []
        for byte in lc {
            for bit in 0..<8 { source.append((byte >> UInt8(7 - bit)) & 1 != 0) }
        }
        let rows: [(Int, Int)] = [(0, 11), (16, 11), (32, 10), (48, 10),
                                  (64, 10), (80, 10), (96, 10)]
        var cursor = 0
        for (start, count) in rows {
            for offset in 0..<count {
                data[start + offset] = source[cursor]
                cursor += 1
            }
        }

        for row in 0..<7 { hamming16114(&data, base: row * 16) }

        // 列校验：第 8 行是前 7 行逐列异或
        for column in 0..<16 {
            var parity = false
            for row in 0..<7 { parity = parity != data[row * 16 + column] }
            data[112 + column] = parity
        }

        // 按列读出，得到最终 128 bit 顺序
        var raw = [Bool](repeating: false, count: 128)
        var index = 0
        for position in 0..<128 {
            raw[position] = data[index]
            index += 16
            if index > 127 { index -= 127 }
        }
        return raw
    }

    /// 把 128 bit 里属于第 `index` 个突发的那 32 bit 写进载荷，返回 LCSS。
    ///
    /// LCSS 是「这是第几段 LC」：1 = 第一段，2 = 第二段，3 = 中间段，0 = 没有 LC。
    /// 顺序不能反：LCSS 最后写，因为它和 LC 分片共用第 13…19 字节的位。
    private static func applyEmbeddedFragment(_ out: inout [UInt8],
                                              bits: [Bool],
                                              index: Int) -> UInt8 {
        guard (1..<5).contains(index) else {
            out[14] &= 0xF0
            out[15] = 0x00
            out[16] = 0x00
            out[17] = 0x00
            out[18] &= 0x0F
            return 0
        }

        let piece = index - 1
        var block = [Bool](repeating: false, count: 40)
        for i in 0..<32 { block[4 + i] = bits[piece * 32 + i] }

        let b0 = pack(block, at: 0)
        let b1 = pack(block, at: 8)
        let b2 = pack(block, at: 16)
        let b3 = pack(block, at: 24)
        let b4 = pack(block, at: 32)

        out[14] = (out[14] & 0xF0) | (b0 & 0x0F)
        out[15] = b1
        out[16] = b2
        out[17] = b3
        out[18] = (out[18] & 0x0F) | (b4 & 0xF0)

        switch piece {
        case 0: return 1
        case 3: return 2
        default: return 3
        }
    }

    /// 嵌入信令 `DMREMB`：色码 + LCSS，再用 QR(16,7) 补 9 位校验。
    private static func applyEmbeddedSignalling(_ out: inout [UInt8],
                                                colorCode: UInt8,
                                                lcss: UInt8) {
        let info = ((colorCode << 4) & 0xF0) | ((lcss << 1) & 0x06)
        let code = qr1676[Int((info >> 1) & 0x7F)]
        let emb0 = UInt8(code >> 8)
        let emb1 = UInt8(code & 0xFF)

        out[13] = (out[13] & 0xF0) | ((emb0 >> 4) & 0x0F)
        out[14] = (out[14] & 0x0F) | ((emb0 << 4) & 0xF0)
        out[18] = (out[18] & 0xF0) | ((emb1 >> 4) & 0x0F)
        out[19] = (out[19] & 0x0F) | ((emb1 << 4) & 0xF0)
    }

    /// 一次呼叫的 6 个语音突发 —— 正好一个超帧，等价于 DroidStar 的 `encode_data()`。
    ///
    /// DMR 把一个超帧拆成 6 个突发（每 60ms 一个）：
    ///
    ///     第 0 个 → 第 13…19 字节放音频同步字（出站 flags 低 4 位 0x10）
    ///     第 1…4 个 → 嵌入 LC 分片（LCSS 1 / 3 / 3 / 2）
    ///     第 5 个 → 只有 EMB（LCSS 0），不带 LC
    ///
    /// 底料是 MMDVMHost 的 `DMR_SILENCE_DATA`（不含同步字）。之前这里一律写同步字、
    /// 而且不带嵌入 LC，等于发出一串「没有信令的静音」：对端能收到载波，却拼不出
    /// 这一串属于哪个组，动态订阅看起来就像没建立。
    static func voiceBursts(talkgroup: Int, src: Int, colorCode: UInt8 = 1) -> [[UInt8]] {
        let bits = embeddedLC(dst: talkgroup, src: src)
        var bursts: [[UInt8]] = []

        for index in 0..<6 {
            var out = rawSilence
            if index == 0 {
                for i in 0..<7 {
                    out[13 + i] = (out[13 + i] & ~syncMask[i]) | audioSync[i]
                }
            } else {
                let lcss = applyEmbeddedFragment(&out, bits: bits, index: index)
                applyEmbeddedSignalling(&out, colorCode: colorCode, lcss: lcss)
            }
            bursts.append(out)
        }
        return bursts
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
