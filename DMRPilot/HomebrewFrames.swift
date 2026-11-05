//
//  HomebrewFrames.swift
//  DMRPilot
//
//  Homebrew Repeater Protocol（MMDVM / HBlink / BrandMeister 通用）帧编解码。
//  参考实现：MMDVMHost DMRNetwork.cpp、HBlink3 hblink.py
//
//  经典帧（BrandMeister 传统）：
//    RPTL     8 字节   "RPTL" + id(4)
//    RPTK    28 字节   "RPTK" + id(4) + password(20, \0 补齐)
//    RPTC   302 字节   "RPTC" + id(4) + 配置块(294)
//    RPTPING 11 字节   "RPTPING" + id(4)
//    MSTPONG 11 字节   "MSTPONG" + id(4)
//    RPTACK  10 字节   "RPTACK" + id(4)
//    MSTNAK  10 字节   "MSTNAK" + id(4)
//    DMRD    53 字节   "DMRD" + seq(1) + src(3) + dst(3) + peer(4) + bits(1)
//                      + streamId(2) + payload(33) + ber(1) + rssi(1)
//
//  新版 MMDVMHost 把 streamId 扩到 4 字节、payload 后移到 20，总长 55，
//  心跳改成 "DMRP"。解析时按长度自适应，两种都能吃。
//

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

    static func auth(id: Int, password: String) -> Data {
        var passwordBytes = Array(password.utf8.prefix(20))
        while passwordBytes.count < 20 { passwordBytes.append(0) }
        return Data([UInt8](authTag.utf8) + bigEndian(id, count: 4) + passwordBytes)
    }

    static func ping(id: Int, modern: Bool) -> Data {
        let tag = modern ? pingTagModern : pingTagLegacy
        return Data([UInt8](tag.utf8) + bigEndian(id, count: 4))
    }

    /// 配置上报。BrandMeister 只在自助页校验 ID + 密码，配置块内容基本不进库，
    /// 但协议要求存在，所以按 HBlink3 的偏移表填一份合法结构。
    static func config(
        id: Int,
        callsign: String,
        rxFrequency: String = "430.00000",
        txFrequency: String = "430.00000",
        colorCode: Int = 1,
        latitude: Double = 0,
        longitude: Double = 0,
        location: String = "DMRPilot",
        description: String = "DMRPilot iOS",
        slots: Int = 2
    ) -> Data {
        var buffer = [UInt8](repeating: 0, count: 302)

        write(configTag, at: 0, length: 4, into: &buffer)
        write(bigEndian(id, count: 4), at: 4, into: &buffer)
        write(callsign, at: 8, length: 8, into: &buffer)          // 呼号
        write(rxFrequency, at: 16, length: 9, into: &buffer)      // RX 频率
        write(txFrequency, at: 25, length: 9, into: &buffer)      // TX 频率
        write("1", at: 34, length: 2, into: &buffer)              // 功率
        write("\(colorCode)", at: 36, length: 2, into: &buffer)   // 色码
        write(String(format: "%.5f", latitude), at: 38, length: 8, into: &buffer)
        write(String(format: "%.5f", longitude), at: 46, length: 9, into: &buffer)
        write("0", at: 55, length: 3, into: &buffer)              // 天线高度
        write(location, at: 58, length: 20, into: &buffer)        // 位置
        write(description, at: 78, length: 19, into: &buffer)     // 描述
        buffer[97] = UInt8(clamping: slots)                       // 时隙数
        write("https://brandmeister.network", at: 98, length: 124, into: &buffer)
        write("DMRPilot 1.0 (iOS)", at: 222, length: 40, into: &buffer)
        write("DMRPilot", at: 262, length: 40, into: &buffer)

        return Data(buffer)
    }

    private static func write(_ text: String, at offset: Int, length: Int, into buffer: inout [UInt8]) {
        let bytes = Array(text.utf8.prefix(length))
        for (i, byte) in bytes.enumerated() where offset + i < buffer.count {
            buffer[offset + i] = byte
        }
    }

    private static func write(_ bytes: [UInt8], at offset: Int, into buffer: inout [UInt8]) {
        for (i, byte) in bytes.enumerated() where offset + i < buffer.count {
            buffer[offset + i] = byte
        }
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
