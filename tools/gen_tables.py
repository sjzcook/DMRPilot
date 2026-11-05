#!/usr/bin/env python3
"""从 DroidStar 的 C++ 声码器源码生成 Swift 常量表。

用法:
    python tools/gen_tables.py <DroidStar mbe 目录> <输出 Swift 文件>

把 codebook.cc / golay.cc / decoder_tables.cc / frame_layout.cc 里的数组逐项转成
Swift 字面量，十六进制浮点（0x1.995cc8p-5f）按 float32 精确还原，保证与 C++ 端
完全一致的数值。
"""

import os
import re
import struct
import sys

# (Swift 属性名, C++ 声明前缀, Swift 类型, 源文件)
PLAN = [
    ("pitchFundamental", "kPitchFundamental[120]", "Float", "codebook.cc"),
    ("pitchHarmonicCount", "kPitchHarmonicCount[120]", "Int32", "codebook.cc"),
    ("voicing", "kVoicingCodebook[32][8]", "Int32", "codebook.cc"),
    ("bandSizes", "kBandSizes[57][4]", "Int32", "codebook.cc"),
    ("gain", "kGainCodebook[32]", "Float", "codebook.cc"),
    ("shapeLow", "kShapeLowCodebook[512][3]", "Float", "codebook.cc"),
    ("shapeHigh", "kShapeHighCodebook[128][4]", "Float", "codebook.cc"),
    ("detail1", "kShapeDetail1Codebook[32][4]", "Float", "codebook.cc"),
    ("detail2", "kShapeDetail2Codebook[16][4]", "Float", "codebook.cc"),
    ("detail3", "kShapeDetail3Codebook[16][4]", "Float", "codebook.cc"),
    ("detail4", "kShapeDetail4Codebook[8][4]", "Float", "codebook.cc"),
    ("inverseDct", "kInverseDct[17][18][18]", "Float", "codebook.cc"),
    ("halfLog2Count", "kHalfLog2Count[64]", "Float", "codebook.cc"),
    ("reciprocalCount", "kReciprocalCount[64]", "Float", "codebook.cc"),
    ("golayParity", "kGolayParityRows[12]", "UInt32", "golay.cc"),
    ("golaySyndrome", "kGolaySyndromeCorrection[2048]", "UInt32", "golay.cc"),
    ("phaseTapWeight", "kPhaseTapWeight[33]", "Float", "decoder_tables.cc"),
    ("keypadLow", "kKeypadLow[4]", "Float", "decoder_tables.cc"),
    ("keypadHigh", "kKeypadHigh[4]", "Float", "decoder_tables.cc"),
    ("keypadLowIndex", "kKeypadLowIndex[16]", "Int32", "decoder_tables.cc"),
    ("keypadHighIndex", "kKeypadHighIndex[16]", "Int32", "decoder_tables.cc"),
    ("toneSetLow", "kToneSetLow[4]", "Float", "decoder_tables.cc"),
    ("toneSetHigh", "kToneSetHigh[4]", "Float", "decoder_tables.cc"),
    ("toneSetIndex", "kToneSetIndex[16][2]", "Int32", "decoder_tables.cc"),
    ("fieldWidth", "kFieldWidth[9]", "Int32", "frame_layout.cc"),
    ("fieldBitPosition", "kFieldBitPosition[9][9]", "Int32", "frame_layout.cc"),
]

EXPECTED = {
    "pitchFundamental": 120, "pitchHarmonicCount": 120, "voicing": 256, "bandSizes": 228,
    "gain": 32, "shapeLow": 1536, "shapeHigh": 512, "detail1": 128, "detail2": 64,
    "detail3": 64, "detail4": 32, "inverseDct": 5508, "halfLog2Count": 64,
    "reciprocalCount": 64, "golayParity": 12, "golaySyndrome": 2048, "phaseTapWeight": 33,
    "keypadLow": 4, "keypadHigh": 4, "keypadLowIndex": 16, "keypadHighIndex": 16,
    "toneSetLow": 4, "toneSetHigh": 4, "toneSetIndex": 32, "fieldWidth": 9,
    "fieldBitPosition": 81,
}

NUMBER = re.compile(
    r"-?0[xX][0-9a-fA-F.pP+-]+[fF]?|-?\d+\.\d+(?:[eE][-+]?\d+)?|-?\d+"
)


def f32(value):
    return struct.unpack("f", struct.pack("f", value))[0]


def parse_number(token):
    text = token.strip().rstrip("fFuUlL").strip()
    body = text[1:] if text.startswith("-") else text
    if body.lower().startswith("0x"):
        if "p" in body.lower() or "." in body:
            return f32(float.fromhex(text))
        return int(text, 16)
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    return f32(float(text))


def array_body(text, name):
    start = text.index(name)
    brace = text.index("{", start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:i]
    raise ValueError("unterminated array: " + name)


def numbers(body):
    return [parse_number(t) for t in NUMBER.findall(body)]


def swift_array(items, indent="        ", width=118):
    lines, current = [], indent
    for item in items:
        if len(current) + len(item) + 2 > width:
            lines.append(current.rstrip())
            current = indent
        current += item + ", "
    lines.append(current.rstrip().rstrip(","))
    return "\n".join(lines)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    source_dir, output = sys.argv[1], sys.argv[2]
    cache = {}

    def read(name):
        if name not in cache:
            with open(os.path.join(source_dir, name), encoding="utf-8", errors="replace") as f:
                cache[name] = f.read()
        return cache[name]

    parts = [
        "//",
        "//  HalfrateTables.swift",
        "//  DMRPilot",
        "//",
        "//  AMBE+2 半速率（DMR）解码器常量表。由 tools/gen_tables.py 从 DroidStar 的",
        "//  mbe/codebook.cc、golay.cc、decoder_tables.cc、frame_layout.cc 逐项转换，",
        "//  十六进制浮点按 float32 精确还原，数值与 C++ 端一一对应。",
        "//",
        "//  不要手改：任何数值偏差都会直接改变解出的音频。",
        "//",
        "",
        "enum HRTables {",
        "",
    ]

    for key, cpp_name, swift_type, source in PLAN:
        values = numbers(array_body(read(source), cpp_name))
        if len(values) != EXPECTED[key]:
            raise SystemExit("%s: expected %d items, got %d" % (key, EXPECTED[key], len(values)))
        items = [str(v) for v in values] if swift_type != "Float" else [repr(float(v)) for v in values]
        parts.append("    /// %s（%d 项）" % (cpp_name, len(values)))
        parts.append("    static let %s: [%s] = [" % (key, swift_type))
        parts.append(swift_array(items))
        parts.append("    ]")
        parts.append("")

    # harmonic classes: 32 rows of 16 chars, V/U/M/P/Q -> 0..4
    rows = re.findall(r'"([^"]*)"', array_body(read("decoder_tables.cc"), "kHarmonicClass[32][17]"))
    codes = {"V": 0, "U": 1, "M": 2, "P": 3, "Q": 4}
    flat = [codes[ch] for row in rows for ch in row]
    if len(flat) != 512:
        raise SystemExit("harmonicClass: expected 512, got %d" % len(flat))
    parts.append("    /// kHarmonicClass，32 行 × 16 槽，行优先；0=V 1=U 2=M 3=P 4=Q（512 项）")
    parts.append("    static let harmonicClass: [UInt8] = [")
    parts.append(swift_array([str(v) for v in flat]))
    parts.append("    ]")
    parts.append("}")
    parts.append("")

    with open(output, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(parts))
    print("wrote %s (%d bytes)" % (output, os.path.getsize(output)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
