"""
DMRCore.cpp 的 TX 路径逐字节核对。

做法：把 DMRCore.cpp 里的状态机（dmr_cnt / data_type / build_frame / encode_data 的
调用顺序）照抄成 Python，输出 55 字节的 DMRD 帧，再和 `dmr_ref.py`（DroidStar dmr.cpp
的 Python 复刻）按同样的输入生成的帧做逐字节比对。

为什么需要这个：本机没有 C++ 编译器，CI 也只能告诉你「编过了」，不会告诉你
「发出去的帧对不对」。这里比对的是**字节**，能提前抓住偏移错位、flags 错位、
超帧序号错、同步字用错组这类「编得过但收不到」的问题。

用法：
    python tools/core_check.py [DroidStar 目录]
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dmr_ref as ref

# ---------------------------------------------------------------- 状态机复刻

FLCO_GROUP = 0
DT_VOICE_LC_HEADER = 0x01
DT_TERMINATOR_WITH_LC = 0x02
DT_VOICE_SYNC = 0xF0
DT_VOICE = 0xF1

SILENCE_AMBE = [0xB9, 0xE8, 0x81, 0x52, 0x61, 0x73, 0x00, 0x2A, 0x6B] * 3


class Core:
    """DMRCore.cpp 的精简复刻，只保留发射需要的那部分状态。"""

    def __init__(self, dmr_id, essid, cc):
        self.dmr_id = dmr_id
        self.essid = essid
        self.tx_cc = cc
        self.tx_src = 0
        self.tx_dst = 0
        self.tx_stream = 0
        self.tx_slot = 2
        self.flco = FLCO_GROUP
        self.data_type = 0
        self.dmr_cnt = 0
        self.raw = [False] * 128
        self.frame = [0] * 55
        self.tx_active = False

    # ---- build_frame ----
    def build_frame(self):
        f = self.frame
        f[0:4] = [ord(c) for c in "DMRD"]
        f[5] = (self.tx_src >> 16) & 0xFF
        f[6] = (self.tx_src >> 8) & 0xFF
        f[7] = self.tx_src & 0xFF
        f[8] = (self.tx_dst >> 16) & 0xFF
        f[9] = (self.tx_dst >> 8) & 0xFF
        f[10] = self.tx_dst & 0xFF
        f[11] = (self.essid >> 24) & 0xFF
        f[12] = (self.essid >> 16) & 0xFF
        f[13] = (self.essid >> 8) & 0xFF
        f[14] = self.essid & 0xFF

        f[15] = 0x00 if self.tx_slot == 1 else 0x80
        f[15] |= 0x00 if self.flco == FLCO_GROUP else 0x40

        if self.data_type == DT_VOICE_SYNC:
            f[15] |= 0x10
        elif self.data_type == DT_VOICE:
            f[15] |= (self.dmr_cnt - 1) % 6
        else:
            f[15] |= 0x20 | self.data_type

        f[4] = self.dmr_cnt & 0xFF
        f[16] = (self.tx_stream >> 24) & 0xFF
        f[17] = (self.tx_stream >> 16) & 0xFF
        f[18] = (self.tx_stream >> 8) & 0xFF
        f[19] = self.tx_stream & 0xFF
        f[53] = 0
        f[54] = 0

    def encode_header(self, data_type):
        # addDMRDataSync + full_lc_encode，ref 里合成的是一次调用
        self.data_type = data_type
        self.frame[20:53] = ref.full_lc_encode(self.tx_dst, self.dmr_id, self.tx_cc, data_type)

    def encode_data(self):
        n = (self.dmr_cnt - 1) % 6
        if n == 0:
            self.data_type = DT_VOICE_SYNC
            self.raw = ref.encode_embedded_data(self.tx_dst, self.dmr_id)
            payload = self.frame[20:53]
            for i in range(7):
                payload[13 + i] = (payload[13 + i] & ~ref.MASK[i] & 0xFF) | ref.MS_AUDIO_SYNC[i]
            self.frame[20:53] = payload
        else:
            self.data_type = DT_VOICE
            payload = self.frame[20:53]
            lcss = ref.get_embedded_data(payload, self.raw, n)
            ref.get_emb_data(payload, self.tx_cc, lcss)
            self.frame[20:53] = payload

    # ---- 对外 ----
    def tx_begin(self, talkgroup, slot, cc):
        self.tx_src = self.dmr_id & 0xFFFFFF
        self.tx_dst = talkgroup & 0xFFFFFF
        self.tx_slot = 1 if slot == 1 else 2
        self.tx_cc = cc & 0x0F
        self.flco = FLCO_GROUP
        self.dmr_cnt = 0
        self.tx_active = True
        self.tx_stream = 0x12345678  # 固定值，方便比对
        self.encode_header(DT_VOICE_LC_HEADER)
        self.build_frame()
        self.dmr_cnt += 1
        return list(self.frame)

    def tx_burst(self, codec27):
        f = self.frame
        f[20:33] = codec27[0:13]
        f[33] = codec27[13] & 0xF0
        f[39] = codec27[13] & 0x0F
        f[40:53] = codec27[14:27]
        self.encode_data()
        self.build_frame()
        self.dmr_cnt += 1
        return list(f)

    def tx_end(self):
        self.encode_header(DT_TERMINATOR_WITH_LC)
        self.build_frame()
        self.dmr_cnt += 1
        self.tx_active = False
        return list(self.frame)


# ---------------------------------------------------------------- 比对

def slot_bit(slot):
    return 0x00 if slot == 1 else 0x80


def reference_header(dst, src, cc, stream, slot):
    payload = ref.full_lc_encode(dst, src, cc, DT_VOICE_LC_HEADER)
    return ref.dmrd(0, src, dst, 0, slot_bit(slot) | 0x20 | DT_VOICE_LC_HEADER, stream, payload)


def reference_bursts(dst, src, cc, stream, slot):
    out = []
    for i, payload in enumerate(ref.voice_bursts(dst, src, cc)):
        n = i % 6
        flags = slot_bit(slot) | (0x10 if n == 0 else n)
        out.append(ref.dmrd(i + 1, src, dst, 0, flags, stream, payload))
    return out


def reference_eot(dst, src, cc, stream, seq, slot):
    payload = ref.full_lc_encode(dst, src, cc, DT_TERMINATOR_WITH_LC)
    return ref.dmrd(seq, src, dst, 0, slot_bit(slot) | 0x20 | DT_TERMINATOR_WITH_LC, stream, payload)


def compare(label, got, want):
    # gwid（11…14）由 Core 自己填，参考这边填 0，先屏蔽掉
    got = list(got)
    want = list(want)
    for i in range(11, 15):
        got[i] = 0
        want[i] = 0
    if got == want:
        return True
    print("  ✗ %s" % label)
    print("    got : %s" % ref.hexs(got))
    print("    want: %s" % ref.hexs(want))
    diff = [i for i in range(55) if got[i] != want[i]]
    print("    差异字节下标: %s" % diff)
    return False


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else r"D:\workBuddySpace\DroidStar-main"
    ref.load_tables(root)

    cases = [
        # (dmr_id, essid, tg, slot, cc)
        (4601234, 460123401, 46001, 2, 1),
        (4601234, 460123401, 91, 1, 1),
        (3123456, 312345600, 46020, 2, 15),
        (1, 100, 9990, 1, 0),
    ]

    ok = True
    for dmr_id, essid, tg, slot, cc in cases:
        core = Core(dmr_id, essid, cc)
        head = core.tx_begin(tg, slot, cc)
        stream = core.tx_stream

        want_head = reference_header(tg, dmr_id, cc, stream, slot)
        want_head[11:15] = [(essid >> 24) & 0xFF, (essid >> 16) & 0xFF,
                            (essid >> 8) & 0xFF, essid & 0xFF]
        ok &= compare("TG%d TS%d CC%d 语音头" % (tg, slot, cc), head, want_head)

        bursts = reference_bursts(tg, dmr_id, cc, stream, slot)
        for i in range(6):
            got = core.tx_burst(SILENCE_AMBE)
            want = bursts[i]
            want[11:15] = head[11:15]
            ok &= compare("  突发 %d" % i, got, want)

        # 第二轮超帧：序号应当回到 0x10
        got = core.tx_burst(SILENCE_AMBE)
        want = reference_bursts(tg, dmr_id, cc, stream, slot)[0]
        want[11:15] = head[11:15]
        want[4] = 7
        ok &= compare("  第二轮超帧首个突发", got, want)

        eot = core.tx_end()
        want_eot = reference_eot(tg, dmr_id, cc, stream, 8, slot)
        want_eot[11:15] = head[11:15]
        ok &= compare("  结束符", eot, want_eot)

        if core.dmr_cnt != 9:
            print("  ✗ 帧计数应为 9，实际 %d" % core.dmr_cnt)
            ok = False

    # 语音突发 → 接收侧拆帧，必须还原出原来的 27 字节
    print()
    core = Core(4601234, 460123401, 1)
    core.tx_begin(46001, 2, 1)
    sample = [(i * 37 + 11) & 0xFF for i in range(27)]
    frame = core.tx_burst(sample)
    payload = frame[20:53]
    codec = payload[0:14]
    codec[13] = (codec[13] & 0xF0) | (payload[19] & 0x0F)
    codec += payload[20:33]
    if codec == sample:
        print("✓ 语音突发拆帧往返一致")
    else:
        print("✗ 语音突发拆帧往返不一致")
        print("  got : %s" % ref.hexs(codec))
        print("  want: %s" % ref.hexs(sample))
        ok = False

    print()
    print("全部一致" if ok else "存在不一致，见上")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
