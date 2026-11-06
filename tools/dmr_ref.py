"""
DroidStar dmr.cpp TX 路径的 Python 复刻，用来生成「参考字节」。

- 语音头 / 结束符：full_lc_encode → get_slot_data + BPTC + RS
- 语音突发：encode_data → addDMRAudioSync / get_embedded_data + get_emb_data
- build_frame：组装 55 字节 DMRD

只用来做逐字节比对，不含任何 App 逻辑。
"""

TBL_2087 = []
TBL_1676 = []
MASK = [0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0]
MS_DATA_SYNC = [0x0D, 0x5D, 0x7F, 0x77, 0xFD, 0x75, 0x70]
MS_AUDIO_SYNC = [0x07, 0xF7, 0xD5, 0xDD, 0x57, 0xDF, 0xD0]
LC_HDR_MASK = [0x96, 0x96, 0x96]
LC_TERM_MASK = [0x99, 0x99, 0x99]


def load_tables(root):
    import re
    g = open(root + "/cgolay2087.cpp", encoding="utf-8", errors="ignore").read()
    body = g.split("ENCODING_TABLE_2087")[1]
    body = body[body.index("{"): body.index("}")]
    TBL_2087.extend(int(v.rstrip("Uu"), 16) for v in re.findall(r"0x[0-9A-Fa-f]{2,4}U?", body))

    d = open(root + "/dmr.cpp", encoding="utf-8", errors="ignore").read()
    text = d[d.index("ENCODING_TABLE_1676"):]
    text = text[text.index("{"): text.index("};")]
    TBL_1676.extend(int(v, 16) for v in re.findall(r"0x[0-9A-Fa-f]{4}", text))


# ---------- GF(256) / RS(12,9) ----------

def build_gf():
    exp = [0] * 512
    log = [0] * 256
    v = 1
    for i in range(255):
        exp[i] = v
        log[v] = i
        v <<= 1
        if v & 0x100:
            v ^= 0x11D
    for i in range(255, 512):
        exp[i] = exp[i - 255]
    return exp, log


GF_EXP, GF_LOG = build_gf()


def gmult(a, b):
    if a == 0 or b == 0:
        return 0
    return GF_EXP[GF_LOG[a] + GF_LOG[b]]


def rs129_encode(msg):
    poly = [64, 56, 14, 1]
    parity = [0, 0, 0, 0]
    for byte in msg:
        dbyte = byte ^ parity[2]
        for j in (2, 1):
            parity[j] = parity[j - 1] ^ gmult(poly[j], dbyte)
        parity[0] = gmult(poly[0], dbyte)
    return parity


# ---------- Hamming / BPTC ----------

def hamming15113(d, b):
    d[b + 11] = d[b] ^ d[b + 1] ^ d[b + 2] ^ d[b + 3] ^ d[b + 5] ^ d[b + 7] ^ d[b + 8]
    d[b + 12] = d[b + 1] ^ d[b + 2] ^ d[b + 3] ^ d[b + 4] ^ d[b + 6] ^ d[b + 8] ^ d[b + 9]
    d[b + 13] = d[b + 2] ^ d[b + 3] ^ d[b + 4] ^ d[b + 5] ^ d[b + 7] ^ d[b + 9] ^ d[b + 10]
    d[b + 14] = d[b] ^ d[b + 1] ^ d[b + 2] ^ d[b + 4] ^ d[b + 6] ^ d[b + 7] ^ d[b + 10]


def hamming1393(d):
    d[9] = d[0] ^ d[1] ^ d[3] ^ d[5] ^ d[6]
    d[10] = d[0] ^ d[1] ^ d[2] ^ d[4] ^ d[6] ^ d[7]
    d[11] = d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[7] ^ d[8]
    d[12] = d[0] ^ d[2] ^ d[4] ^ d[5] ^ d[8]


def bits_of(block):
    out = []
    for byte in block:
        for i in range(7, -1, -1):
            out.append(bool((byte >> i) & 1))
    return out


def pack_bits(bits, offset):
    value = 0
    for i in range(8):
        value = (value << 1) | (1 if bits[offset + i] else 0)
    return value


def bptc_encode(block):
    data = bits_of(block)
    deinter = [False] * 196
    rows = [(4, 11), (16, 26), (31, 41), (46, 56), (61, 71),
            (76, 86), (91, 101), (106, 116), (121, 131)]
    pos = 0
    for start, end in rows:
        for index in range(start, end + 1):
            deinter[index] = data[pos]
            pos += 1

    for row in range(9):
        hamming15113(deinter, row * 15 + 1)

    for column in range(15):
        col = [deinter[column + 1 + i * 15] for i in range(13)]
        hamming1393(col)
        for i in range(13):
            deinter[column + 1 + i * 15] = col[i]

    raw = [False] * 196
    for a in range(196):
        raw[(a * 181) % 196] = deinter[a]

    out = [0] * 33
    for i in range(12):
        out[i] = pack_bits(raw, i * 8)
    crossing = pack_bits(raw, 96)
    out[12] = (out[12] & 0x3F) | (crossing & 0xC0)
    out[20] = (out[20] & 0xFC) | ((crossing >> 4) & 0x03)
    for i in range(12):
        out[21 + i] = pack_bits(raw, 100 + i * 8)
    return out


def golay2087(value):
    return TBL_2087[value]


# ---------- 语音头 / 结束符 ----------

def full_lc_encode(dst, src, cc, data_type):
    lc = [0x00, 0x00, 0x00,
          (dst >> 16) & 0xFF, (dst >> 8) & 0xFF, dst & 0xFF,
          (src >> 16) & 0xFF, (src >> 8) & 0xFF, src & 0xFF]
    parity = rs129_encode(lc)
    mask = LC_HDR_MASK if data_type == 1 else LC_TERM_MASK
    block = lc + [parity[2] ^ mask[0], parity[1] ^ mask[1], parity[0] ^ mask[2]]

    out = bptc_encode(block)

    slot = [(cc << 4) & 0xF0 | (data_type & 0x0F), 0x00, 0x00]
    ck = golay2087(slot[0])
    slot[1] = ck & 0xFF
    slot[2] = ck >> 8

    out[12] = (out[12] & 0xC0) | ((slot[0] >> 2) & 0x3F)
    out[13] = (out[13] & 0x0F) | ((slot[0] << 6) & 0xC0) | ((slot[1] >> 2) & 0x30)
    out[19] = (out[19] & 0xF0) | ((slot[1] >> 2) & 0x0F)
    out[20] = (out[20] & 0x03) | ((slot[1] << 6) & 0xC0) | ((slot[2] >> 2) & 0x3C)

    for i in range(7):
        out[13 + i] = (out[13 + i] & ~MASK[i] & 0xFF) | MS_DATA_SYNC[i]
    return out


# ---------- 嵌入 LC（DroidStar encode_embedded_data / get_embedded_data） ----------

def encode_embedded_data(dst, src):
    lc = [0x00, 0x00, 0x00,
          (dst >> 16) & 0xFF, (dst >> 8) & 0xFF, dst & 0xFF,
          (src >> 16) & 0xFF, (src >> 8) & 0xFF, src & 0xFF]
    m_data = bits_of(lc)
    crc = sum(lc) % 31

    data = [False] * 128
    data[106] = bool(crc & 0x01)
    data[90] = bool(crc & 0x02)
    data[74] = bool(crc & 0x04)
    data[58] = bool(crc & 0x08)
    data[42] = bool(crc & 0x10)

    b = 0
    for a in range(0, 11):
        data[a] = m_data[b]; b += 1
    for a in range(16, 27):
        data[a] = m_data[b]; b += 1
    for a in range(32, 42):
        data[a] = m_data[b]; b += 1
    for a in range(48, 58):
        data[a] = m_data[b]; b += 1
    for a in range(64, 74):
        data[a] = m_data[b]; b += 1
    for a in range(80, 90):
        data[a] = m_data[b]; b += 1
    for a in range(96, 106):
        data[a] = m_data[b]; b += 1

    for a in range(0, 112, 16):
        hamming16114(data, a)

    for a in range(16):
        data[a + 112] = (data[a] ^ data[a + 16] ^ data[a + 32] ^ data[a + 48]
                         ^ data[a + 64] ^ data[a + 80] ^ data[a + 96])

    raw = [False] * 128
    b = 0
    for a in range(128):
        raw[a] = data[b]
        b += 16
        if b > 127:
            b -= 127
    return raw


def hamming16114(d, base):
    d[base + 11] = d[base] ^ d[base + 1] ^ d[base + 2] ^ d[base + 3] ^ d[base + 5] ^ d[base + 7] ^ d[base + 8]
    d[base + 12] = d[base + 1] ^ d[base + 2] ^ d[base + 3] ^ d[base + 4] ^ d[base + 6] ^ d[base + 8] ^ d[base + 9]
    d[base + 13] = d[base + 2] ^ d[base + 3] ^ d[base + 4] ^ d[base + 5] ^ d[base + 7] ^ d[base + 9] ^ d[base + 10]
    d[base + 14] = d[base] ^ d[base + 1] ^ d[base + 2] ^ d[base + 4] ^ d[base + 6] ^ d[base + 7] ^ d[base + 10]
    d[base + 15] = d[base] ^ d[base + 2] ^ d[base + 5] ^ d[base + 6] ^ d[base + 8] ^ d[base + 9] ^ d[base + 10]


def qr1676(emb):
    value = (emb[0] >> 1) & 0x7F
    ck = TBL_1676[value]
    emb[0] = ck >> 8
    emb[1] = ck & 0xFF


def get_emb_data(data, cc, lcss):
    emb = [((cc << 4) & 0xF0) | ((lcss << 1) & 0x06), 0x00]
    qr1676(emb)
    data[13] = (data[13] & 0xF0) | ((emb[0] >> 4) & 0x0F)
    data[14] = (data[14] & 0x0F) | ((emb[0] << 4) & 0xF0)
    data[18] = (data[18] & 0xF0) | ((emb[1] >> 4) & 0x0F)
    data[19] = (data[19] & 0x0F) | ((emb[1] << 4) & 0xF0)


def get_embedded_data(data, raw, n):
    if 1 <= n < 5:
        idx = n - 1
        bits = [False] * 40
        bits[4:36] = raw[idx * 32:(idx + 1) * 32]
        b = [pack_bits(bits, 0), pack_bits(bits, 8), pack_bits(bits, 16),
             pack_bits(bits, 24), pack_bits(bits, 32)]
        data[14] = (data[14] & 0xF0) | (b[0] & 0x0F)
        data[15] = b[1]
        data[16] = b[2]
        data[17] = b[3]
        data[18] = (data[18] & 0x0F) | (b[4] & 0xF0)
        return 1 if idx == 0 else (2 if idx == 3 else 3)
    data[14] &= 0xF0
    data[15] = 0
    data[16] = 0
    data[17] = 0
    data[18] &= 0x0F
    return 0


SILENCE = [0xB9, 0xE8, 0x81, 0x52, 0x61, 0x73, 0x00, 0x2A, 0x6B, 0xB9, 0xE8,
           0x81, 0x52, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x73, 0x00,
           0x2A, 0x6B, 0xB9, 0xE8, 0x81, 0x52, 0x61, 0x73, 0x00, 0x2A, 0x6B]


def voice_bursts(dst, src, cc):
    raw = encode_embedded_data(dst, src)
    out = []
    for n in range(6):
        data = list(SILENCE)
        if n == 0:
            for i in range(7):
                data[13 + i] = (data[13 + i] & ~MASK[i] & 0xFF) | MS_AUDIO_SYNC[i]
        else:
            lcss = get_embedded_data(data, raw, n)
            get_emb_data(data, cc, lcss)
        out.append(data)
    return out


def dmrd(seq, src, dst, peer, flags, stream, payload):
    out = [0] * 55
    out[0:4] = [ord(c) for c in "DMRD"]
    out[4] = seq & 0xFF
    out[5:8] = [(src >> 16) & 0xFF, (src >> 8) & 0xFF, src & 0xFF]
    out[8:11] = [(dst >> 16) & 0xFF, (dst >> 8) & 0xFF, dst & 0xFF]
    out[11:15] = [(peer >> 24) & 0xFF, (peer >> 16) & 0xFF, (peer >> 8) & 0xFF, peer & 0xFF]
    out[15] = flags
    out[16:20] = [(stream >> 24) & 0xFF, (stream >> 16) & 0xFF, (stream >> 8) & 0xFF, stream & 0xFF]
    out[20:53] = payload
    return out


def hexs(values):
    return " ".join("%02X" % v for v in values)


if __name__ == "__main__":
    import sys
    load_tables(sys.argv[1] if len(sys.argv) > 1 else r"D:\workBuddySpace\DroidStar-main")
    print("tables:", len(TBL_2087), len(TBL_1676))

    dst, src, cc, peer = 46001, 4601234, 1, 460123401
    slot = 2
    slotflag = 0x80
    head = full_lc_encode(dst, src, cc, 1)
    tail = full_lc_encode(dst, src, cc, 2)
    print("HEAD", hexs(head))
    print("TAIL", hexs(tail))
    bursts = voice_bursts(dst, src, cc)
    for i, b in enumerate(bursts):
        print("BURST%d" % i, hexs(b))
