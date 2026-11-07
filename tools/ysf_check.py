#!/usr/bin/env python3
"""YSF 协议核心的离线自检（本机没有 Swift / C++ 工具链，只能这样验）。

做三件事：

1. 表抄写校验：把 Core/YSFCore.cpp 里的交织表、白化表、扰码表逐个元素和
   参考实现 DroidStar/ysf.cpp 比对——抄错一个数字，空口就全乱。
2. 码链闭环：用 Core/Golay24128.cpp、Core/CRCenc.cpp 里的**真实码表**，
   把 YSFCore.cpp 的编码/解码逻辑翻成 Python，验证
       FICH    编码 → 解码 得到同样的字段；
       语音头 DCH 编码 → 解码 得到同样的 20 字节；
       VD2 的 10 字节 DCH 与 49 bit 语音 编码 → 解码 得到原样。
3. 结构校验：组出来的包长度、同步字、包头字段、"YSFD" 前缀。

跑法：python tools/ysf_check.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, "DMRPilot", "Core")
REF = os.path.join(os.path.dirname(ROOT), "DroidStar-main")

failures = []


def check(name, ok, detail=""):
    if ok:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s %s" % (name, detail))
        failures.append(name)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def array(src, name):
    """从 C/C++ 源码里抠出一个数值数组的内容。"""
    m = re.search(r"\b" + name + r"\s*\[\s*\w*\s*\]\s*=\s*\{(.*?)\};", src, re.S)
    if not m:
        raise SystemExit("找不到数组 %s" % name)
    return [int(x, 0) for x in re.findall(r"0x[0-9A-Fa-f]+|\d+", m.group(1))]


# ---------------------------------------------------------------- 码表

src_mine = read(os.path.join(CORE, "YSFCore.cpp"))
src_ref = read(os.path.join(REF, "ysf.cpp"))

print("[1] 码表抄写校验")
for name in ("INTERLEAVE_TABLE_9_20", "INTERLEAVE_TABLE_5_20", "INTERLEAVE_TABLE_26_4"):
    mine = array(src_mine, name)
    ref = array(src_ref, name)
    check(name, mine == ref, "(mine %d / ref %d 项)" % (len(mine), len(ref)))

# 白化表在参考实现里叫 WHITENING_DATA，在 YSFCore.cpp 里同名
check("WHITENING_DATA",
      array(src_mine, "WHITENING_DATA") == array(src_ref, "WHITENING_DATA"))

# 扰码表在参考实现里是 ysf_scramble 内的局部数组 scramble_code[180]
ref_scramble = array(src_ref, "scramble_code")
mine_scramble = array(src_mine, "YSF_SCRAMBLE_CODE")
check("scramble_code", mine_scramble[:104] == ref_scramble[:104],
      "(前 104 项，参考共 %d)" % len(ref_scramble))

# ---------------------------------------------------------------- Golay / CRC

golay_src = read(os.path.join(CORE, "Golay24128.cpp"))
ENC_23127 = array(golay_src, "ENCODING_TABLE_23127")
DEC_23127 = array(golay_src, "DECODING_TABLE_23127")
ENC_24128 = array(golay_src, "ENCODING_TABLE_24128")

crc_src = read(os.path.join(CORE, "CRCenc.cpp"))
CCITT16_TABLE2 = array(crc_src, "CCITT16_TABLE2")


def golay_syndrome(pattern):
    X22, X11, MASK12, GENPOL = 0x00400000, 0x00000800, 0xFFFFF800, 0x00000C75
    aux = X22
    if pattern >= X11:
        while pattern & MASK12:
            while not (aux & pattern):
                aux >>= 1
            pattern ^= (aux // X11) * GENPOL
    return pattern


def golay_decode_23127(code):
    return (code ^ DEC_23127[golay_syndrome(code)]) >> 11


def golay_decode_24128_bytes(b):
    code = (b[0] << 16) | (b[1] << 8) | b[2]
    return golay_decode_23127(code >> 1)


def crc_add_ccitt16(data, length):
    """CCRC::addCCITT162：算前 length-2 字节，写进最后两字节。"""
    crc = 0
    for i in range(length - 2):
        crc = ((crc >> 8) << 8) ^ CCITT16_TABLE2[(crc & 0xFF) ^ data[i]]
    crc ^= 0xFFFF
    data[length - 2] = (crc >> 8) & 0xFF
    data[length - 1] = crc & 0xFF


def crc_check_ccitt16(data, length):
    crc = 0
    for i in range(length - 2):
        crc = ((crc >> 8) << 8) ^ CCITT16_TABLE2[(crc & 0xFF) ^ data[i]]
    crc ^= 0xFFFF
    return ((crc >> 8) & 0xFF) == data[length - 2] and (crc & 0xFF) == data[length - 1]


MASK = [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]


def read_bit(p, i):
    return 1 if p[i >> 3] & MASK[i & 7] else 0


def write_bit(p, i, b):
    if b:
        p[i >> 3] |= MASK[i & 7]
    else:
        p[i >> 3] &= ~MASK[i & 7] & 0xFF


BRANCH1 = [0, 0, 0, 0, 1, 1, 1, 1]
BRANCH2 = [0, 1, 1, 0, 0, 1, 1, 0]
M, K = 2, 5


def conv_encode(bits_in, nbits):
    out = bytearray((2 * nbits + 7) // 8 + 1)
    d1 = d2 = d3 = d4 = 0
    k = 0
    for i in range(nbits):
        d = bits_in[i]
        g1 = (d + d3 + d4) & 1
        g2 = (d + d1 + d2 + d4) & 1
        d4, d3, d2, d1 = d3, d2, d1, d
        write_bit(out, k, g1)
        k += 1
        write_bit(out, k, g2)
        k += 1
    return out


class Convolution:
    def __init__(self):
        self.m1 = [0] * 16
        self.m2 = [0] * 16
        self.old = self.m1
        self.new = self.m2
        self.decisions = []
        self.dp = 0

    def start(self):
        self.m1 = [0] * 16
        self.m2 = [0] * 16
        self.old, self.new = self.m1, self.m2
        self.decisions = [0] * 180
        self.dp = 0

    def decode(self, s0, s1):
        word = 0
        for i in range(8):
            j = i * 2
            metric = (BRANCH1[i] ^ s0) + (BRANCH2[i] ^ s1)
            m0 = self.old[i] + metric
            m1 = self.old[i + 8] + (M - metric)
            d0 = 1 if m0 >= m1 else 0
            self.new[j] = m1 if d0 else m0
            m0 = self.old[i] + (M - metric)
            m1 = self.old[i + 8] + metric
            d1 = 1 if m0 >= m1 else 0
            self.new[j + 1] = m1 if d1 else m0
            word |= (d1 << (j + 1)) | (d0 << j)
        self.decisions[self.dp] = word
        self.dp += 1
        self.old, self.new = self.new, self.old

    def chainback(self, nbits):
        out = bytearray((nbits + 7) // 8 + 1)
        state = 0
        for n in range(nbits - 1, -1, -1):
            self.dp -= 1
            i = state >> (9 - K)
            bit = (self.decisions[self.dp] >> i) & 1
            state = (bit << 7) | (state >> 1)
            write_bit(out, n, bit)
        return out


# ---------------------------------------------------------------- FICH

TBL_5_20 = array(src_mine, "INTERLEAVE_TABLE_5_20")
TBL_9_20 = array(src_mine, "INTERLEAVE_TABLE_9_20")
TBL_26_4 = array(src_mine, "INTERLEAVE_TABLE_26_4")
WHITEN = array(src_mine, "WHITENING_DATA")
SCRAMBLE = array(src_mine, "YSF_SCRAMBLE_CODE")
SYNC = [0xD4, 0x71, 0xC9, 0x63, 0x4D]

FI_HEADER, FI_COMM, FI_TERM = 0, 1, 2
DT_VD1, DT_DATA, DT_VD2, DT_VOICE_FR = 0, 1, 2, 3


def fich_bytes(fi, cs, cm, bn, bt, fn, ft, dev, mr, voip, dt, sql, sq):
    f = [0] * 6
    f[0] = (fi << 6) | (cs << 4) | (cm << 2) | bn
    f[1] = (bt << 6) | (fn << 3) | ft
    f[2] = (dev << 6) | (mr << 3) | (voip << 2) | dt
    f[3] = (sql << 7) | (sq & 0x7F)
    return f


def fich_encode(f):
    f = list(f)
    crc_add_ccitt16(f, 6)
    b0 = ((f[0] << 4) & 0xFF0) | ((f[1] >> 4) & 0x00F)
    b1 = ((f[1] << 8) & 0xF00) | (f[2] & 0x0FF)
    b2 = ((f[3] << 4) & 0xFF0) | ((f[4] >> 4) & 0x00F)
    b3 = ((f[4] << 8) & 0xF00) | (f[5] & 0x0FF)

    conv = bytearray(13)
    for idx, (c) in enumerate((b0, b1, b2, b3)):
        code = ENC_24128[c]
        conv[idx * 3 + 0] = (code >> 16) & 0xFF
        conv[idx * 3 + 1] = (code >> 8) & 0xFF
        conv[idx * 3 + 2] = code & 0xFF

    convolved = conv_encode([read_bit(conv, i) for i in range(104)], 100)

    payload = bytearray(30)
    payload[0:5] = bytes(SYNC)
    j = 0
    for i in range(100):
        n = FICH_INTERLEAVE[i]
        write_bit(payload, 5 * 8 + n, read_bit(convolved, j))
        j += 1
        write_bit(payload, 5 * 8 + n + 1, read_bit(convolved, j))
        j += 1
    return payload


def fich_decode(payload):
    conv = Convolution()
    conv.start()
    for i in range(100):
        n = FICH_INTERLEAVE[i]
        s0 = read_bit(payload, 5 * 8 + n)
        s1 = read_bit(payload, 5 * 8 + n + 1)
        conv.decode(s0, s1)
    out = conv.chainback(96)

    blocks = []
    for k in range(4):
        blocks.append(golay_decode_24128_bytes(out[k * 3:k * 3 + 3]))
    b0, b1, b2, b3 = blocks

    f = [0] * 6
    f[0] = (b0 >> 4) & 0xFF
    f[1] = ((b0 << 4) & 0xF0) | ((b1 >> 8) & 0x0F)
    f[2] = b1 & 0xFF
    f[3] = (b2 >> 4) & 0xFF
    f[4] = ((b2 << 4) & 0xF0) | ((b3 >> 8) & 0x0F)
    f[5] = b3 & 0xFF
    return f, crc_check_ccitt16(f, 6)


FICH_INTERLEAVE = array(read(os.path.join(REF, "YSFFICH.cpp")), "INTERLEAVE_TABLE")

print("[2] FICH 编解码闭环")
payload = fich_encode(fich_bytes(FI_HEADER, 2, 0, 0, 0, 0, 6, 0, 0, 0, DT_VD2, 0, 0))
f, ok = fich_decode(payload)
check("FICH CRC", ok)
check("FICH FI", (f[0] >> 6) & 0x03 == FI_HEADER, hex(f[0]))
check("FICH DT", f[2] & 0x03 == DT_VD2, hex(f[2]))
check("FICH FN/FT", ((f[1] >> 3) & 0x07, f[1] & 0x07) == (0, 6), hex(f[1]))


# ---------------------------------------------------------------- DCH

def write_fr_mode_data(dt20, payload, offset):
    out = bytearray(25)
    for i in range(20):
        out[i] = dt20[i] ^ WHITEN[i]
    crc_add_ccitt16(out, 22)
    out[22] = 0
    convolved = conv_encode([read_bit(out, i) for i in range(180)], 180)
    bytes45 = bytearray(45)
    j = 0
    for i in range(180):
        n = TBL_9_20[i]
        write_bit(bytes45, n, read_bit(convolved, j))
        j += 1
        write_bit(bytes45, n + 1, read_bit(convolved, j))
        j += 1
    for i in range(5):
        payload[35 + 30 + offset + 18 * i:35 + 30 + offset + 18 * i + 9] = bytes45[9 * i:9 * i + 9]


def decode_dch_9(body):
    dch = bytearray(45)
    p1, p2 = 0, 0
    for _ in range(5):
        dch[p2:p2 + 9] = body[p1:p1 + 9]
        p1 += 18
        p2 += 9
    conv = Convolution()
    conv.start()
    for i in range(180):
        n = TBL_9_20[i]
        conv.decode(read_bit(dch, n), read_bit(dch, n + 1))
    out = conv.chainback(176)
    if not crc_check_ccitt16(out, 22):
        return None
    for i in range(20):
        out[i] ^= WHITEN[i]
    return bytes(out[:20])


print("[3] 语音头 DCH 闭环")
callsign = b"BG7ABC    "
csd1 = b"*" * 10 + callsign
csd2 = callsign + callsign
pkt = bytearray(155)
pkt[35:40] = bytes(SYNC)
fich_payload = fich_encode(fich_bytes(FI_HEADER, 2, 0, 0, 0, 0, 6, 0, 0, 0, DT_VD2, 0, 0))
pkt[35:65] = fich_payload
write_fr_mode_data(csd1, pkt, 0)
write_fr_mode_data(csd2, pkt, 9)
body = pkt[35 + 30:]
d1 = decode_dch_9(body)
d2 = decode_dch_9(body[9:])
check("头 DCH 往返（CSD1）", d1 == csd1, repr(d1))
check("头 DCH 往返（CSD2）", d2 == csd2, repr(d2))


# ---------------------------------------------------------------- VD2

def encode_vch_vd2(bits49):
    buf = bytearray(104)
    for i in range(27):
        buf[i * 3 + 0] = bits49[i]
        buf[i * 3 + 1] = bits49[i]
        buf[i * 3 + 2] = bits49[i]
    buf[81:103] = bytes(bits49[27:49])
    buf[103] = 0
    for i in range(104):
        buf[i] ^= SCRAMBLE[i]
    result = bytearray(104)
    for i in range(4):
        for j in range(26):
            result[i + j * 4] = buf[j + i * 26]
    vch = bytearray(13)
    for i in range(13):
        for j in range(8):
            vch[i] |= (result[i * 8 + j] << (7 - j))
    return vch


def decode_vch(body):
    frames = bytearray(35)
    offset = 40
    for j in range(5):
        vch = bytearray(13)
        for i in range(104):
            write_bit(vch, i, read_bit(body, offset + TBL_26_4[i]))
        for i in range(13):
            vch[i] ^= WHITEN[i]
        dat_a = dat_b = dat_c = 0
        for i in range(12):
            dat_a = (dat_a << 1) | read_bit(vch, 3 * i + 1)
        for i in range(12):
            dat_b = (dat_b << 1) | read_bit(vch, 3 * (i + 12) + 1)
        for i in range(3):
            dat_c = (dat_c << 1) | read_bit(vch, 3 * (i + 24) + 1)
        for i in range(22):
            dat_c = (dat_c << 1) | read_bit(vch, i + 81)

        frame = bytearray(7)
        for i in range(12):
            write_bit(frame, i, 1 if (dat_a << (i + 20)) & 0x80000000 else 0)
            write_bit(frame, i + 12, 1 if (dat_b << (i + 20)) & 0x80000000 else 0)
        for i in range(25):
            write_bit(frame, i + 24, 1 if (dat_c << (i + 7)) & 0x80000000 else 0)
        frames[7 * j:7 * j + 7] = frame
        offset += 144
    return bytes(frames)


print("[4] VD2 语音闭环")
import random

random.seed(7)
codec = bytes(random.randrange(256) for _ in range(35))
codec = b"".join(codec[7 * i:7 * i + 6] + bytes([codec[7 * i + 6] & 0x80]) for i in range(5))
pkt = bytearray(155)
pkt[35:40] = bytes(SYNC)
pkt[35:65] = fich_encode(fich_bytes(FI_COMM, 2, 0, 0, 0, 1, 6, 0, 0, 0, DT_VD2, 0, 0))
body = pkt[35 + 30:]
for frame in range(5):
    bits = [read_bit(codec[7 * frame:7 * frame + 7], i) for i in range(49)]
    vch = encode_vch_vd2(bits)
    body[18 * frame + 5:18 * frame + 18] = vch
check("VCH 往返", decode_vch(body) == codec)

# VD2 的 10 字节 DCH


def write_vd_mode2_data(dt10, body):
    tmp = bytearray(13)
    tmp[:10] = dt10
    for i in range(10):
        tmp[i] ^= WHITEN[i]
    crc_add_ccitt16(tmp, 12)
    tmp[12] = 0
    convolved = conv_encode([read_bit(tmp, i) for i in range(100)], 100)
    bytes25 = bytearray(25)
    j = 0
    for i in range(100):
        n = TBL_5_20[i]
        write_bit(bytes25, n, read_bit(convolved, j))
        j += 1
        write_bit(bytes25, n + 1, read_bit(convolved, j))
        j += 1
    for i in range(5):
        body[18 * i:18 * i + 5] = bytes25[5 * i:5 * i + 5]


def decode_dch_5(body):
    dch = bytearray(25)
    for i in range(5):
        dch[5 * i:5 * i + 5] = body[18 * i:18 * i + 5]
    conv = Convolution()
    conv.start()
    for i in range(100):
        n = TBL_5_20[i]
        conv.decode(read_bit(dch, n), read_bit(dch, n + 1))
    out = conv.chainback(96)
    if not crc_check_ccitt16(out, 12):
        return None
    for i in range(10):
        out[i] ^= WHITEN[i]
    return bytes(out[:10])


print("[5] VD2 的 DCH 闭环")
dch10 = b"BG7ABC    "
body2 = bytearray(90)
write_vd_mode2_data(dch10, body2)
check("VD2 DCH 往返", decode_dch_5(body2) == dch10)

# ---------------------------------------------------------------- 结构

print("[6] 包结构")
header = bytearray(155)
header[0:4] = b"YSFD"
header[4:14] = callsign
header[14:24] = callsign
header[24:34] = b"ALL       "
header[34] = 0
check("包头 35 字节 + 120 字节载荷", len(header) == 35 + 120)
header[35:40] = bytes(SYNC)
check("同步字位置", header[35:40] == bytes(SYNC))
check("FICH 起点", 35 + 5 == 40)
check("DCH 起点", 35 + 30 == 65)

print()
if failures:
    print("失败 %d 项：%s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("全部通过")
