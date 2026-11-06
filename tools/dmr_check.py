"""
把 DMRCallFrames.swift 里新写的算法「逐行照抄」成 Python，和 dmr_ref.py（DroidStar 复刻）
逐字节比对。Swift 端没有编译器可用，这是唯一能验证移植没走形的办法。

只检查数据：[0] QR(16,7) 表、[1] 嵌入 LC + 6 个突发、[2] 语音头 / 结束符。
"""

import importlib.util
import re
import sys


def load_ref(root):
    spec = importlib.util.spec_from_file_location("ref", "tools/dmr_ref.py")
    ref = importlib.util.module_from_spec(spec)
    sys.modules["ref"] = ref
    spec.loader.exec_module(ref)
    ref.load_tables(root)
    return ref


def swift_qr_table():
    text = open("DMRPilot/DMRCallFrames.swift", encoding="utf-8").read()
    body = text[text.index("private static let qr1676"):]
    start = body.index("= [")
    body = body[start: body.index("]", start)]
    return [int(v, 16) for v in re.findall(r"0x[0-9A-Fa-f]{4}", body)]


def xor(values):
    result = False
    for value in values:
        result = result != value
    return result


def hamming16114(d, base):
    d[base + 11] = xor([d[base], d[base + 1], d[base + 2], d[base + 3], d[base + 5], d[base + 7], d[base + 8]])
    d[base + 12] = xor([d[base + 1], d[base + 2], d[base + 3], d[base + 4], d[base + 6], d[base + 8], d[base + 9]])
    d[base + 13] = xor([d[base + 2], d[base + 3], d[base + 4], d[base + 5], d[base + 7], d[base + 9], d[base + 10]])
    d[base + 14] = xor([d[base], d[base + 1], d[base + 2], d[base + 4], d[base + 6], d[base + 7], d[base + 10]])
    d[base + 15] = xor([d[base], d[base + 2], d[base + 5], d[base + 6], d[base + 8], d[base + 9], d[base + 10]])


def embedded_lc(dst, src):
    lc = [0, 0, 0,
          (dst >> 16) & 0xFF, (dst >> 8) & 0xFF, dst & 0xFF,
          (src >> 16) & 0xFF, (src >> 8) & 0xFF, src & 0xFF]

    data = [False] * 128
    crc = sum(lc) % 31
    data[42] = bool(crc & 0x10)
    data[58] = bool(crc & 0x08)
    data[74] = bool(crc & 0x04)
    data[90] = bool(crc & 0x02)
    data[106] = bool(crc & 0x01)

    source = []
    for byte in lc:
        for bit in range(8):
            source.append(bool((byte >> (7 - bit)) & 1))

    rows = [(0, 11), (16, 11), (32, 10), (48, 10), (64, 10), (80, 10), (96, 10)]
    cursor = 0
    for start, count in rows:
        for offset in range(count):
            data[start + offset] = source[cursor]
            cursor += 1
    assert cursor == 72

    for row in range(7):
        hamming16114(data, row * 16)

    for column in range(16):
        parity = False
        for row in range(7):
            parity = parity != data[row * 16 + column]
        data[112 + column] = parity

    raw = [False] * 128
    index = 0
    for position in range(128):
        raw[position] = data[index]
        index += 16
        if index > 127:
            index -= 127
    return raw


def pack(bits, offset):
    value = 0
    for i in range(8):
        value = (value << 1) | (1 if bits[offset + i] else 0)
    return value


def apply_fragment(out, bits, index, qr_table_unused=None):
    if not (1 <= index < 5):
        out[14] &= 0xF0
        out[15] = 0
        out[16] = 0
        out[17] = 0
        out[18] &= 0x0F
        return 0
    piece = index - 1
    block = [False] * 40
    for i in range(32):
        block[4 + i] = bits[piece * 32 + i]
    b0 = pack(block, 0)
    b1 = pack(block, 8)
    b2 = pack(block, 16)
    b3 = pack(block, 24)
    b4 = pack(block, 32)
    out[14] = (out[14] & 0xF0) | (b0 & 0x0F)
    out[15] = b1
    out[16] = b2
    out[17] = b3
    out[18] = (out[18] & 0x0F) | (b4 & 0xF0)
    return 1 if piece == 0 else (2 if piece == 3 else 3)


def apply_signalling(out, color_code, lcss, qr_table):
    info = ((color_code << 4) & 0xF0) | ((lcss << 1) & 0x06)
    code = qr_table[(info >> 1) & 0x7F]
    emb0 = code >> 8
    emb1 = code & 0xFF
    out[13] = (out[13] & 0xF0) | ((emb0 >> 4) & 0x0F)
    out[14] = (out[14] & 0x0F) | ((emb0 << 4) & 0xF0)
    out[18] = (out[18] & 0xF0) | ((emb1 >> 4) & 0x0F)
    out[19] = (out[19] & 0x0F) | ((emb1 << 4) & 0xF0)


SILENCE = [0xB9, 0xE8, 0x81, 0x52, 0x61, 0x73, 0x00, 0x2A, 0x6B, 0xB9, 0xE8,
           0x81, 0x52, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x73, 0x00,
           0x2A, 0x6B, 0xB9, 0xE8, 0x81, 0x52, 0x61, 0x73, 0x00, 0x2A, 0x6B]
MASK = [0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0]
AUDIO_SYNC = [0x07, 0xF7, 0xD5, 0xDD, 0x57, 0xDF, 0xD0]


def voice_bursts(dst, src, cc, qr_table):
    bits = embedded_lc(dst, src)
    out = []
    for index in range(6):
        data = list(SILENCE)
        if index == 0:
            for i in range(7):
                data[13 + i] = (data[13 + i] & ~MASK[i] & 0xFF) | AUDIO_SYNC[i]
        else:
            lcss = apply_fragment(data, bits, index)
            apply_signalling(data, cc, lcss, qr_table)
        out.append(data)
    return out


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else r"D:\workBuddySpace\DroidStar-main"
    ref = load_ref(root)
    qr = swift_qr_table()

    assert qr == ref.TBL_1676, "QR(16,7) 表和 DroidStar 不一致"
    print("[ok] QR(16,7) 表 128 项一致")

    cases = [(46001, 4601234, 1), (91, 4601234, 1), (46001, 4601234, 0), (91, 3100001, 15)]
    for dst, src, cc in cases:
        mine = voice_bursts(dst, src, cc, qr)
        theirs = ref.voice_bursts(dst, src, cc)
        for i, (a, b) in enumerate(zip(mine, theirs)):
            assert a == b, "TG=%d src=%d cc=%d 突发 %d 不一致\n mine  %s\n ref   %s" % (
                dst, src, cc, i, ref.hexs(a), ref.hexs(b))
        print("[ok] TG %s src %s cc %d：6 个突发全部一致" % (dst, src, cc))

    print("样例（TG 46001 / src 4601234 / CC1）：")
    for i, burst in enumerate(voice_bursts(46001, 4601234, 1, qr)):
        print("  突发 %d: %s" % (i, ref.hexs(burst)))


if __name__ == "__main__":
    main()
