#!/usr/bin/env python3
"""RewindCore.cpp 的字节级自检。

本机没有 C++ 编译器，所以把 RewindCore.cpp 里那几个拼包的函数照抄成 Python，
再拿 BrandMeister 规范里写死的字段逐字节对一遍：头偏移、小端序、订阅内容、
语音头 12 字节 LC 的位置。任何一处偏移写错都会让服务端静默丢弃（症状就是
「登录成功但收不到语音」），所以这些必须钉死。

跑：python tools/rewind_check.py
"""

import hashlib
import struct

SIGN = b"REWIND01"
HEADER = 18

TYPE_KEEP_ALIVE = 0x0000
TYPE_CLOSE = 0x0001
TYPE_CHALLENGE = 0x0002
TYPE_AUTHENTICATION = 0x0003
TYPE_REPORT = 0x0100
TYPE_SUBSCRIPTION = 0x0901
TYPE_CANCELLING = 0x0902
TYPE_DMR_DATA_BASE = 0x0910
TYPE_DMR_AUDIO_FRAME = 0x0920

FLAG_NONE = 0x0000
FLAG_REAL_TIME = 0x0001

SERVICE_OPEN_TERMINAL = 0x21
SESSION_GROUP_VOICE = 7


class Core:
    """RewindCore.cpp 的最小复刻：只关心拼出来的字节。"""

    def __init__(self, dmr_id, password, version="DMRPilot 1.0"):
        self.dmr_id = dmr_id & 0xFFFFFF
        self.password = password
        self.version = version
        self.counter = [0, 0]

    def build(self, type_, flags, data=b""):
        index = 1 if (flags & FLAG_REAL_TIME) else 0
        seq = self.counter[index]
        self.counter[index] = (seq + 1) & 0xFFFFFFFF
        header = SIGN + struct.pack("<HHIH", type_, flags, seq, len(data))
        assert len(header) == HEADER, f"头长度应为 {HEADER}，实际 {len(header)}"
        return header + data

    def keepalive(self):
        data = struct.pack("<I", self.dmr_id) + bytes([SERVICE_OPEN_TERMINAL]) + self.version.encode()
        return self.build(TYPE_KEEP_ALIVE, FLAG_NONE, data)

    def subscribe(self, talkgroup):
        return self.build(TYPE_SUBSCRIPTION, FLAG_NONE,
                          struct.pack("<II", SESSION_GROUP_VOICE, talkgroup & 0xFFFFFF))

    def close(self):
        return self.build(TYPE_CLOSE, FLAG_NONE)

    def tx_header(self, talkgroup, is_private=0):
        return self.build(TYPE_DMR_DATA_BASE + 1, FLAG_REAL_TIME,
                          self.build_lc(talkgroup, is_private))

    def build_lc(self, talkgroup, is_private=0):
        lc = bytearray(12)
        lc[0] = 0x03 if is_private else 0x00
        lc[3] = (talkgroup >> 16) & 0xFF
        lc[4] = (talkgroup >> 8) & 0xFF
        lc[5] = talkgroup & 0xFF
        lc[6] = (self.dmr_id >> 16) & 0xFF
        lc[7] = (self.dmr_id >> 8) & 0xFF
        lc[8] = self.dmr_id & 0xFF
        return bytes(lc)

    def tx_header_again(self, talkgroup, is_private=0):
        """RewindCore.cpp 的 rw_core_tx_header_again：复用上一个序号。"""
        if self.counter[1] == 0:
            return self.tx_header(talkgroup, is_private)
        saved = self.counter[1]
        self.counter[1] = (saved - 1) & 0xFFFFFFFF
        packet = self.build(TYPE_DMR_DATA_BASE + 1, FLAG_REAL_TIME,
                            self.build_lc(talkgroup, is_private))
        self.counter[1] = saved
        return packet

    def tx_audio(self, codec27):
        assert len(codec27) == 27
        return self.build(TYPE_DMR_AUDIO_FRAME, FLAG_REAL_TIME, codec27)

    def tx_end(self):
        return self.build(TYPE_DMR_DATA_BASE + 2, FLAG_REAL_TIME)


def parse(packet):
    assert packet[:8] == SIGN, "签名不对"
    type_, flags, seq, length = struct.unpack("<HHIH", packet[8:HEADER])
    return type_, flags, seq, packet[HEADER:HEADER + length]


class Rx:
    """rw_core_receive 的复刻：只关心「从服务器来的包」怎么被拆开。

    收不到语音时，错的地方几乎都在这一层 —— 头偏移、LC 里 src/dst 的顺序、
    音频帧长度。所以这里用 BrandMeister 真会发的那几种包做输入。
    """

    DISCONNECTED, CONNECTING, AUTH, SUBSCRIBING, CONNECTED = 0, 1, 2, 3, 4

    def __init__(self, password):
        self.password = password
        self.status = self.DISCONNECTED
        self.stream_src = 0
        self.stream_dst = 0
        self.stream_private = 0

    def receive(self, packet):
        type_, flags, seq, data = parse(packet)
        if type_ == TYPE_CHALLENGE:
            digest = hashlib.sha256(data + self.password.encode()).digest()
            self.status = self.AUTH
            return "AUTH", digest
        if type_ == TYPE_KEEP_ALIVE:
            if not data and self.status == self.AUTH:
                self.status = self.SUBSCRIBING
                return "AUTHENTICATED", b""
            return "PONG", b""
        if type_ == TYPE_SUBSCRIPTION:
            self.status = self.CONNECTED
            return "SUBSCRIBED", b""
        if type_ == TYPE_DMR_DATA_BASE + 1:
            flco = data[0] & 0x3F
            self.stream_dst = (data[3] << 16) | (data[4] << 8) | data[5]
            self.stream_src = (data[6] << 16) | (data[7] << 8) | data[8]
            self.stream_private = 1 if flco == 3 else 0
            return "HEADER", data
        if type_ == TYPE_DMR_DATA_BASE + 2:
            return "EOT", b""
        if type_ == TYPE_DMR_AUDIO_FRAME:
            return "VOICE", data
        return "UNKNOWN", b""


def packet(type_, data=b"", flags=FLAG_NONE, seq=0):
    """手工拼一个服务器发来的包（序号由我们指定，方便断言）。"""
    return SIGN + struct.pack("<HHIH", type_, flags, seq, len(data)) + data


def check(name, ok):
    print(("  ✓ " if ok else "  ✗ ") + name)
    return ok


def main():
    ok = True
    core = Core(dmr_id=4601234, password="secret")

    print("头布局 / 小端")
    ka = core.keepalive()
    type_, flags, seq, data = parse(ka)
    ok &= check("KEEP_ALIVE 类型 0x0000", type_ == TYPE_KEEP_ALIVE)
    ok &= check("KEEP_ALIVE 标志 0", flags == FLAG_NONE)
    ok &= check("第一个包序号 0", seq == 0)
    ok &= check("VersionData 里的 DMR ID 是小端 7 位",
                data[:4] == struct.pack("<I", 4601234))
    ok &= check("服务类型 = 0x21（Open Terminal）", data[4] == SERVICE_OPEN_TERMINAL)
    ok &= check("描述紧跟其后", data[5:] == b"DMRPilot 1.0")
    ok &= check("长度字段 = 5 + 描述长度", len(data) == 5 + len("DMRPilot 1.0"))

    print("序号：常规包与实时包分开计数")
    core2 = Core(dmr_id=4601234, password="x")
    core2.keepalive()                      # 常规 0 → 1
    core2.keepalive()                      # 常规 1 → 2
    hdr = core2.tx_header(46001)           # 实时 0 → 1
    ok &= check("第三个常规包之前序号已到 2", parse(core2.keepalive())[2] == 2)
    ok &= check("第一个实时包序号从 0 开始", parse(hdr)[2] == 0)
    ok &= check("第二个实时包序号 1", parse(core2.tx_audio(bytes(27)))[2] == 1)

    print("订阅")
    sub = core2.subscribe(46001)
    type_, flags, seq, data = parse(sub)
    ok &= check("类型 0x0901", type_ == TYPE_SUBSCRIPTION)
    ok &= check("内容 8 字节", len(data) == 8)
    ok &= check("会话类型 7（组呼）", struct.unpack("<I", data[:4])[0] == SESSION_GROUP_VOICE)
    ok &= check("通话组 46001", struct.unpack("<I", data[4:])[0] == 46001)

    print("语音头 12 字节 LC")
    h = parse(core2.tx_header(46001))[3]
    ok &= check("长度 12", len(h) == 12)
    ok &= check("FLCO = 0（组呼）", h[0] == 0x00)
    ok &= check("FID = 0", h[1] == 0x00)
    ok &= check("目的地址 46001 大端", h[3:6] == bytes([0x00, 0xB3, 0xB1]))
    ok &= check("源地址 4601234 大端（0x463592）", h[6:9] == bytes([0x46, 0x35, 0x92]))
    ok &= check("CRC 留空（规范允许跳过）", h[9:12] == b"\x00\x00\x00")

    print("语音帧 / 结束符")
    audio = core2.tx_audio(bytes(range(27)))
    type_, flags, seq, data = parse(audio)
    ok &= check("类型 0x0920", type_ == TYPE_DMR_AUDIO_FRAME)
    ok &= check("带实时标志", flags == FLAG_REAL_TIME)
    ok &= check("载荷原样 27 字节", data == bytes(range(27)))

    end = core2.tx_end()
    type_, flags, seq, data = parse(end)
    ok &= check("结束符类型 0x0912", type_ == TYPE_DMR_DATA_BASE + 2)
    ok &= check("结束符无内容", len(data) == 0)

    print("关闭")
    close = Core(1, "x").close()
    ok &= check("CLOSE 类型 0x0001", parse(close)[0] == TYPE_CLOSE)

    print("语音头重发（同一序号）")
    core3 = Core(dmr_id=4601234, password="secret")
    first = core3.tx_header(46001)
    again1 = core3.tx_header_again(46001)
    again2 = core3.tx_header_again(46001)
    ok &= check("重发两次都与首帧逐字节相同", first == again1 == again2)
    ok &= check("重发用的是同一个序号", parse(again1)[2] == parse(first)[2])
    ok &= check("重发不会把实时计数器推进", core3.counter[1] == 1)
    audio_after = core3.tx_audio(bytes(27))
    ok &= check("重发之后的语音帧序号接着数", parse(audio_after)[2] == 1)

    print("接收侧（服务器 → 客户端）")
    salt = bytes(range(32))
    rx = Rx(password="secret")
    event, digest = rx.receive(packet(TYPE_CHALLENGE, salt))
    ok &= check("CHALLENGE 触发 AUTH", event == "AUTH")
    ok &= check("SHA256(盐‖密码) 与 hashlib 一致",
                digest == hashlib.sha256(salt + b"secret").digest())
    ok &= check("AUTH 摘要 32 字节", len(digest) == 32)

    event, _ = rx.receive(packet(TYPE_KEEP_ALIVE))
    ok &= check("鉴权后空 KEEP_ALIVE = AUTHENTICATED", event == "AUTHENTICATED")
    event, _ = rx.receive(packet(TYPE_SUBSCRIPTION))
    ok &= check("SUBSCRIPTION 确认 = 已连上", event == "SUBSCRIBED")

    # 服务器下发的语音头：flco/fid/服务选项 + 目的(3) + 源(3) + CRC(3)
    lc = bytes([0x00, 0x00, 0x00, 0x00, 0xB3, 0xB1, 0x46, 0x35, 0x92, 0x11, 0x22, 0x33])
    event, _ = rx.receive(packet(TYPE_DMR_DATA_BASE + 1, lc, FLAG_REAL_TIME))
    ok &= check("语音头触发 HEADER", event == "HEADER")
    ok &= check("目的地址 = TG 46001", rx.stream_dst == 46001)
    ok &= check("源地址 = 4601234", rx.stream_src == 4601234)
    ok &= check("组呼标记为 0", rx.stream_private == 0)

    lc_private = bytes([0x03, 0x00, 0x00, 0x00, 0x00, 0x2A, 0x46, 0x35, 0x92, 0, 0, 0])
    rx.receive(packet(TYPE_DMR_DATA_BASE + 1, lc_private, FLAG_REAL_TIME))
    ok &= check("FLCO=3 判成单呼", rx.stream_private == 1 and rx.stream_dst == 42)

    codec = bytes(range(27))
    event, payload = rx.receive(packet(TYPE_DMR_AUDIO_FRAME, codec, FLAG_REAL_TIME))
    ok &= check("语音帧原样交出 27 字节 AMBE", event == "VOICE" and payload == codec)
    ok &= check("27 = 3 × 9（mode 33 三帧）", len(payload) % 9 == 0 and len(payload) // 9 == 3)

    event, _ = rx.receive(packet(TYPE_DMR_DATA_BASE + 2, b"", FLAG_REAL_TIME))
    ok &= check("结束符触发 EOT", event == "EOT")

    print()
    print("全部一致" if ok else "有差异")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
