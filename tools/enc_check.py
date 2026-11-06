"""把 HalfrateEncoder / HalfrateDequant 的数学搬到 Python，验证「量化 → 反量化」闭环。

不编译 Swift，也能确认：目标残差的推导（去掉预测、去掉均值）、增益索引、谱形码本
搜索三者放在一起，最终重建出来的 log2 幅度是否回到目标附近。
"""
import re
import sys

SRC = r"D:\workBuddySpace\DMRApp\DMRPilot\Vocoder\HalfrateTables.swift"


def arr(name):
    s = open(SRC, encoding="utf-8").read()
    i = s.index("static let %s:" % name)
    b = s[i:]
    b = b[b.index("= ["):]
    b = b[:b.index("\n    ]")]
    return [float(x) for x in re.findall(r"-?\d+\.?\d*(?:[eE][-+]?\d+)?", b)]


PITCH = arr("pitchFundamental")
PITCH_L = [int(v) for v in arr("pitchHarmonicCount")]
BAND = [int(v) for v in arr("bandSizes")]
VOICING = arr("voicing")
GAIN = arr("gain")
SHAPELOW = arr("shapeLow")
SHAPEHIGH = arr("shapeHigh")
DETAIL = [arr("detail1"), arr("detail2"), arr("detail3"), arr("detail4")]
IDCT = arr("inverseDct")
HALFLOG = arr("halfLog2Count")
RECIP = arr("reciprocalCount")

PREDICTION = 0.65
GAIN_W = 1.0
PREV_GAIN_W = 0.5
HALF_SQRT_HALF = 0.35355338
MAX_H = 56


class State:
    def __init__(self):
        self.count = 30
        self.gain = 0.0
        self.amp = [0.0] * (MAX_H + 2)


def shape_residual(count, fields):
    low = fields[3]
    high = fields[4]
    coeffs = [0.0,
              SHAPELOW[low * 3], SHAPELOW[low * 3 + 1], SHAPELOW[low * 3 + 2],
              SHAPEHIGH[high * 4], SHAPEHIGH[high * 4 + 1],
              SHAPEHIGH[high * 4 + 2], SHAPEHIGH[high * 4 + 3]]
    pairs = [0.0] * 8
    dct8 = 7 * 324
    for r in range(8):
        pairs[r] = sum(IDCT[dct8 + r * 18 + c] * coeffs[c] for c in range(8))

    out = [0.0] * 64
    pos = 0
    base = count * 4
    for block in range(4):
        n = BAND[base + block] if base + block < len(BAND) else 0
        if n < 1:
            continue
        bc = [0.0] * 18
        a = pairs[2 * block]
        b = pairs[2 * block + 1]
        bc[0] = (a + b) * 0.5
        bc[1] = (a - b) * HALF_SQRT_HALF
        if n >= 3:
            dc = min(n, 6) - 2
            row = fields[5 + block]
            table = DETAIL[block]
            for i in range(dc):
                bc[2 + i] = table[row * 4 + i]
        dct = (n - 1) * 324
        for i in range(n):
            out[pos] = sum(IDCT[dct + i * 18 + c] * bc[c] for c in range(n))
            pos += 1
    return out


def predict(state, count):
    prev = list(state.amp)
    if count > state.count:
        last = prev[state.count]
        for i in range(state.count + 1, count + 1):
            prev[i] = last
    prev[0] = prev[1]
    ratio = state.count / count
    out = [0.0] * count
    for k in range(1, count + 1):
        x = ratio * k
        i = int(x)
        frac = x - i
        a = (1 - frac) * PREDICTION * (prev[i] if i < len(prev) else 0)
        b = frac * PREDICTION * (prev[i + 1] if i + 1 < len(prev) else 0)
        out[k - 1] = a + b
    return out


def dequant(state, fields):
    pitch = fields[0]
    count = PITCH_L[pitch]
    gain_new = GAIN_W * GAIN[fields[2]]
    gain = gain_new + PREV_GAIN_W * state.gain
    res = shape_residual(count, fields)
    pred = predict(state, count)

    rsum = sum(res[:count])
    psum = sum(pred)
    offset = gain - HALFLOG[count] - rsum * RECIP[count]
    pmean = psum * RECIP[count]
    state.amp = [0.0] * (MAX_H + 2)
    for k in range(count):
        state.amp[k + 1] = offset + (res[k] + pred[k] - pmean)
    state.count = count
    state.gain = gain
    return count, [state.amp[k + 1] for k in range(count)]


# ---------------- 编码端（照抄 Swift 的逻辑） ----------------

def nearest_rows(table, stride, target, limit):
    rows = len(table) // stride
    best = []
    for row in range(rows):
        err = sum((table[row * stride + i] - target[i]) ** 2 for i in range(stride))
        best.append((err, row))
    best.sort()
    return [row for _, row in best[:limit]]


def pairs_of(low, high):
    coeffs = [0.0] * 8
    coeffs[1] = SHAPELOW[low * 3]
    coeffs[2] = SHAPELOW[low * 3 + 1]
    coeffs[3] = SHAPELOW[low * 3 + 2]
    for i in range(4):
        coeffs[4 + i] = SHAPEHIGH[high * 4 + i]
    dct8 = 7 * 324
    out = [0.0] * 8
    for r in range(8):
        out[r] = sum(IDCT[dct8 + r * 18 + c] * coeffs[c] for c in range(8))
    return out


def quantize_shape(target, count):
    sizes = [BAND[count * 4 + b] for b in range(4)]
    block_target = []
    offset = 0
    for b in range(4):
        n = sizes[b]
        coeff = [0.0] * max(n, 1)
        if n >= 1:
            base = (n - 1) * 324
            for c in range(n):
                acc = sum(IDCT[base + j * 18 + c] * (target[offset + j] if offset + j < len(target) else 0)
                          for j in range(n))
                # 逆 DCT 的列范数不是 1：第 0 列 n，其余 2n（M 的第 0 行系数是 1、其余是 2）
                coeff[c] = acc / (n if c == 0 else 2 * n)
        block_target.append(coeff)
        offset += n

    pairs = [0.0] * 8
    for b in range(4):
        c0 = block_target[b][0] if block_target[b] else 0.0
        c1 = block_target[b][1] if len(block_target[b]) > 1 else 0.0
        pairs[2 * b] = c0 + 0.70710678 * c1
        pairs[2 * b + 1] = c0 - 0.70710678 * c1

    dct8 = 7 * 324
    coeffs = [0.0] * 8
    for c in range(1, 8):
        coeffs[c] = sum(IDCT[dct8 + r * 18 + c] * pairs[r] for r in range(8)) / 16.0
    low_target = coeffs[1:4]
    high_target = coeffs[4:8]

    lows = nearest_rows(SHAPELOW, 3, low_target, 4)
    highs = nearest_rows(SHAPEHIGH, 4, high_target, 4)

    mean_target = sum(target[:count]) / count
    best = None
    for low in lows:
        for high in highs:
            bp = pairs_of(low, high)
            details = [0] * 4
            for b in range(4):
                n = sizes[b]
                if n < 3:
                    continue
                wanted = min(n, 6)
                table = DETAIL[b]
                rows = len(table) // 4
                best_row, best_err = 0, float("inf")
                for row in range(rows):
                    err = 0.0
                    for i in range(wanted - 2):
                        t = block_target[b][2 + i] if len(block_target[b]) > 2 + i else 0.0
                        err += (table[row * 4 + i] - t) ** 2
                    if err < best_err:
                        best_err, best_row = err, row
                details[b] = best_row
            fields = [0, 0, 0, low, high] + details + [0, 0, 0, 0]
            res = shape_residual(count, fields)
            mean = sum(res[:count]) / count
            err = sum(((res[k] - mean) - (target[k] - mean_target)) ** 2 for k in range(count))
            if best is None or err < best[0]:
                best = (err, low, high, details)
    return best[1], best[2], best[3]


def encode_target(state, log_amps, pitch_index, voicing):
    count = PITCH_L[pitch_index]
    mean_log = sum(log_amps[:count]) / count
    gain_target = mean_log + HALFLOG[count]
    carried = PREV_GAIN_W * state.gain
    gain_index = min(range(len(GAIN)), key=lambda i: abs(GAIN_W * GAIN[i] + carried - gain_target))

    pred = predict(state, count)
    pmean = sum(pred) / count
    residual_target = [(log_amps[k] - mean_log) - (pred[k] - pmean) for k in range(count)]

    low, high, details = quantize_shape(residual_target, count)
    fields = [pitch_index, voicing, gain_index, low, high] + details + [0, 0, 0, 0]
    return fields


def run(label, log_amps, pitch_index=40):
    st_enc = State()
    st_dec = State()
    print(f"\n== {label}：pitch={pitch_index} count={PITCH_L[pitch_index]} ==")
    total = 0.0
    for frame in range(4):
        fields = encode_target(st_enc, log_amps, pitch_index, 0)
        count, recon = dequant(st_dec, fields)
        # 编码端的预测器也要往前走，两边状态必须一致
        dequant(st_enc, fields)
        err = max(abs(recon[k] - log_amps[k]) for k in range(count))
        total += err
        print(f"  frame {frame}: gain={fields[2]} low={fields[3]} high={fields[4]} "
              f"details={fields[5:9]} 最大误差 {err:.2f} bit")
    print(f"  平均最大误差 {total / 4:.2f} bit")


if __name__ == "__main__":
    # 一个典型浊音：低次谐波强、高频滚降，整体在码本的常见区间
    n = 40
    vowel = [5.0 - 0.09 * k for k in range(n)]
    run("平缓滚降（浊音）", vowel)

    # 起伏大一点的谱形，考验 detail 码字
    ripple = [4.5 - 0.06 * k + 0.5 * ((k % 3) - 1) for k in range(n)]
    run("带起伏的谱形", ripple)

    # 很轻的帧
    quiet = [1.5 - 0.04 * k for k in range(n)]
    run("轻音", quiet)
