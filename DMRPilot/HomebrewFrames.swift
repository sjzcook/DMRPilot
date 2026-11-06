//
//  HomebrewFrames.swift
//  DMRPilot
//
//  Homebrew Repeater Protocol（MMDVM / HBlink / BrandMeister 通用）帧编解码。
//  参考实现：MMDVMHost DMRNetwork.cpp、HBlink3 hblink.py
//
//  经典帧（BrandMeister 传统）：
//    RPTL     8 字节   "RPTL" + id(4)
//    RPTACK  10 字节   "RPTACK" + 4 字节（RPTL 的应答里是挑战盐，其余是 id）
//    RPTK    40 字节   "RPTK" + id(4) + SHA256(挑战盐 ‖ 密码)(32)   ← BM 只认这个
//    RPTK    28 字节   "RPTK" + id(4) + 明文密码(20, \0 补齐)      ← 老 HBlink 兼容
//    RPTC   302 字节   "RPTC" + id(4) + 配置块(294)
//    RPTPING 11 字节   "RPTPING" + id(4)
//    MSTPONG 11 字节   "MSTPONG" + id(4)
//    MSTNAK  10 字节   "MSTNAK" + id(4)
//    DMRD    53 字节   "DMRD" + seq(1) + src(3) + dst(3) + peer(4) + bits(1)
//                      + streamId(2) + payload(33) + ber(1) + rssi(1)
//
//  新版 MMDVMHost 把 streamId 扩到 4 字节、payload 后移到 20，总长 55，
//  心跳改成 "DMRP"。解析时按长度自适应，两种都能吃。
//

import CryptoKit
import Foundation

enum HB {

    // MARK: - 标签

    static let loginTag = "RPTL"
    static let authTag = "RPTK"
    static let configTag = "RPTC"
    static let pingTagLegacy = "RPTPING"
    static let pingTagModern = "DMRP"
    static let dmrTag = "DMRD"

    // MARK: - 基础工具

    static func bigEndian(_ value: Int, count: Int) -> [UInt8] {
        stride(from: count - 1, through: 0, by: -1).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }

    static func readBE(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        guard offset >= 0, count > 0, offset + count <= bytes.count else { return 0 }
        var value = 0
        for i in 0..<count {
            value = (value << 8) | Int(bytes[offset + i])
        }
        return value
    }

    /// 取前 4 字节命令字（"RPTACK" → "RPTA"，"MSTPONG" → "MSTP"）
    static func tag(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        return String(bytes: bytes[0..<4], encoding: .ascii)
    }

    // MARK: - 出站帧

    static func login(id: Int) -> Data {
        Data([UInt8](loginTag.utf8) + bigEndian(id, count: 4))
    }

    /// RPTK 挑战应答：id(4) + SHA256(挑战盐 ‖ 密码)，共 40 字节。
    ///
    /// 关键：RPTL 之后 master 回的 RPTACK 里，第 6…9 字节是 4 字节挑战盐；
    /// 密码必须做 SHA256(salt + password) 再发，直接发明文会被当成密码错误回 MSTNAK。
    /// 参考实现 BMWire.hbAuth / MMDVMHost DMRNetwork::writeAuthorisation 都是这个算法。
    static func auth(id: Int, challenge: [UInt8], password: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(challenge))
        hasher.update(data: Data(password.utf8))
        let digest = [UInt8](hasher.finalize())
        return Data([UInt8](authTag.utf8) + bigEndian(id, count: 4) + digest)
    }

    /// 传统 28 字节 RPTK：id(4) + 明文密码（20 字节，\0 补齐）。
    /// 老版 HBlink / 部分自建网关只认这个；BrandMeister 会当密码错处理，
    /// 所以只在标准鉴权被拒后回退试一次。
    static func authLegacy(id: Int, password: String) -> Data {
        var passwordBytes = Array(password.utf8.prefix(20))
        while passwordBytes.count < 20 { passwordBytes.append(0) }
        return Data([UInt8](authTag.utf8) + bigEndian(id, count: 4) + passwordBytes)
    }

    static func ping(id: Int, modern: Bool) -> Data {
        let tag = modern ? pingTagModern : pingTagLegacy
        return Data([UInt8](tag.utf8) + bigEndian(id, count: 4))
    }

    /// 配置上报（302 字节）。
    ///
    /// 字段宽度与 MMDVMHost `DMRNetwork::writeConfig` 的格式串逐项对应：
    ///
    ///     "RPTC%08u%-8.8s%09u%09u%02u%02u%8.8s%9.9s%03d%-20.20s%-19.19s%c%-124.124s%-40.40s%-40.40s"
    ///
    /// 注意 id 是 **4 字节二进制**（不是 8 位文本），所以 4 + 4 + 294 = 302。
    ///
    /// 两个曾经踩过的坑，都会让 master 直接回 MSTNAK：
    /// 1. 数字字段必须零补齐（`%02u` 得 "01"），只写 "1" 会留一个 NUL 字节；
    /// 2. 尾部必须用空格 0x20 补齐，不能用 NUL —— master 按 C 字符串解析时会被截断，
    ///    后面的呼号 / URL 全成了垃圾，整包配置被拒。
    static func config(
        id: Int,
        callsign: String,
        frequency: Int = 438_800_000,
        colorCode: Int = 1,
        latitude: String = "+00.0000",
        longitude: String = "+000.0000",
        location: String = "DMRPilot",
        description: String = "DMRPilot iOS",
        url: String = "www.qrz.com",
        softwareID: String = "20200922",
        packageID: String = "MMDVM_MMDVM_HS_Hat",
        slots: Int = 2
    ) -> Data {
        var payload: [UInt8] = []

        payload += ascii(callsign, width: 8, alignLeft: true)        // %-8.8s 呼号
        payload += digits(frequency, width: 9)                       // %09u RX（Hz）
        payload += digits(frequency, width: 9)                       // %09u TX（Hz）
        payload += digits(1, width: 2)                               // %02u 功率（dBm）
        payload += digits(colorCode, width: 2)                       // %02u 色码
        payload += ascii(latitude, width: 8, alignLeft: false)       // %8.8s
        payload += ascii(longitude, width: 9, alignLeft: false)      // %9.9s
        payload += digits(0, width: 3)                               // %03d 天线高度
        payload += ascii(location, width: 20, alignLeft: true)       // %-20.20s
        payload += ascii(description, width: 19, alignLeft: true)    // %-19.19s
        // 时隙数：真实热点发 1 或 2。这个字节在旧版规范里属于描述字段的最后一位，
        // 但新版（DMRHub / HBlink3）都按「时隙数」解析，填 4 之类会被当成非法值。
        payload += digits(slots, width: 1)                           // %c
        payload += ascii(url, width: 124, alignLeft: true)           // %-124.124s
        payload += ascii(softwareID, width: 40, alignLeft: true)     // %-40.40s
        payload += ascii(packageID, width: 40, alignLeft: true)      // %-40.40s

        if payload.count > 294 { payload = Array(payload.prefix(294)) }
        while payload.count < 294 { payload.append(0x20) }

        return Data([UInt8](configTag.utf8) + bigEndian(id, count: 4) + payload)
    }

    /// 定长 ASCII：超出截断，不足按 `%Ns` / `%-Ns` 补空格（0x20）。
    private static func ascii(_ text: String, width: Int, alignLeft: Bool) -> [UInt8] {
        let clipped = Array(text.utf8.prefix(width))
        let padding = Array(repeating: UInt8(0x20), count: max(0, width - clipped.count))
        return alignLeft ? clipped + padding : padding + clipped
    }

    /// 定长十进制，前导零补齐（对应 C 的 `%0Nu`）。
    private static func digits(_ value: Int, width: Int) -> [UInt8] {
        var text = String(max(0, value))
        if text.count > width { text = String(text.suffix(width)) }
        while text.count < width { text = "0" + text }
        return Array(text.utf8)
    }

    // MARK: - 入站 DMRD 解析

    struct DmrFrame {
        let seq: Int
        let src: Int
        let dst: Int
        let peerId: Int
        let slot: Int
        let isPrivate: Bool
        let isDataSync: Bool
        let isVoiceSync: Bool
        /// dataSync 时是数据类型：1 = 语音头，2 = 语音结束，3 = CSBK，6 = 数据头
        /// 否则是语音突发的序号 A..F（0..5）
        let dataType: Int
        let streamId: Int
        let payload: [UInt8]

        var isVoiceHeader: Bool { isDataSync && dataType == 1 }
        var isVoiceTerminator: Bool { isDataSync && dataType == 2 }

        /// 这一帧是否属于用户选定的通话组。
        ///
        /// - 组呼：`dst` 就是 TG，直接比。
        /// - 单呼：`dst` 是对方 ID，跟自己没关系；只有「发给我的」和「我发出的」才算。
        /// - `talkgroup == 0` 时不做过滤，全部接收。
        func belongs(toTalkgroup talkgroup: Int, myId: Int) -> Bool {
            guard talkgroup > 0 else { return true }
            if isPrivate { return dst == myId || src == myId }
            return dst == talkgroup
        }
    }

    static func parseDmr(_ bytes: [UInt8]) -> DmrFrame? {
        guard bytes.count >= 53, tag(bytes) == dmrTag else { return nil }

        let wide = bytes.count >= 55
        let bits = bytes[15]

        let slot = (bits & 0x80) != 0 ? 2 : 1
        let isPrivate = (bits & 0x40) != 0
        let isDataSync = (bits & 0x20) != 0
        let isVoiceSync = (bits & 0x10) != 0
        let dataType = Int(bits & 0x0F)
        let streamId = wide ? readBE(bytes, 16, 4) : readBE(bytes, 16, 2)
        let offset = wide ? 20 : 18
        let payloadEnd = min(offset + 33, bytes.count)

        return DmrFrame(
            seq: Int(bytes[4]),
            src: readBE(bytes, 5, 3),
            dst: readBE(bytes, 8, 3),
            peerId: readBE(bytes, 11, 4),
            slot: slot,
            isPrivate: isPrivate,
            isDataSync: isDataSync,
            isVoiceSync: isVoiceSync,
            dataType: dataType,
            streamId: streamId,
            payload: Array(bytes[offset..<payloadEnd])
        )
    }
}
