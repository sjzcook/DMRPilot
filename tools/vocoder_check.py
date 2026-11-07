#!/usr/bin/env python3
"""Core/Vocoder/ 的静态自检。

本机没有 C++ 编译器（Windows，无 clang/g++），CI 也只跑在 macOS 上，
所以这里用「读源码」的方式把最容易出错的三件事钉住：

  1. 文件齐全        解码闭包少一个 .cc，真机上就是链接期 undefined symbol
  2. include 自洽    引号 include 必须能在同目录找到（Xcode 不会替你找）
  3. 符号有定义      tables.h / halfrate.h 里声明的每个符号都得有人实现

跑：python tools/vocoder_check.py
"""

import pathlib
import re
import sys

VOC = pathlib.Path("DMRPilot/Core/Vocoder")
CORE = pathlib.Path("DMRPilot/Core")

# 解码闭包：从 decoder_api.cc 的 include 图推出来的（见 README「语音是怎么解出来的」）
CC = [
    "decoder_api.cc", "decoder.cc", "decoder_synth.cc", "decoder_options.cc",
    "decoder_tables.cc", "dequant.cc", "enhance.cc", "fec.cc", "frame.cc",
    "frame_layout.cc", "fastmath.cc", "fft.cc", "golay.cc", "api.cc",
    "codebook.cc", "codebook_set.cc", "cosine.cc",
]
HH = [
    "halfrate.h", "decoder.h", "decoder_synth.h", "decoder_options.h",
    "decoder_tables.h", "dequant.h", "enhance.h", "fastmath.h", "fec.h",
    "fft.h", "frame.h", "codebook.h", "numeric.h", "tables.h",
]

# 编码器那半边不属于解码闭包，出现就说明混进来了
FORBIDDEN = ["encoder.cc", "analysis.cc", "pitch.cc", "shape_quantizer.cc",
             "enc_analysis.cc", "enc_pitch_net.cc", "options.cc",
             "encoder_api.cc", "mbevocoder.cpp", "ambe2.cc"]

# halfrate.h 里属于编码器 / 不在解码路径上的接口，允许没有实现
OPTIONAL_API = {"hr_encoder_new", "hr_encoder_free", "hr_encoder_set", "hr_encode"}


def strip_noise(src: str) -> str:
    """去掉注释与字符串/字符字面量，剩下的用于括号与符号扫描。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif c == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
        elif c == "'":
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def main() -> int:
    ok = True

    def check(name, good):
        nonlocal ok
        print(("  ✓ " if good else "  ✗ ") + name)
        if not good:
            ok = False
        return good

    print("文件清单")
    for name in CC:
        check(name, (VOC / name).exists())
    for name in HH:
        check(name, (VOC / name).exists())
    check("没有混进编码器文件", not any((VOC / f).exists() for f in FORBIDDEN))
    check("HRCore.h / HRCore.cpp 存在",
          (CORE / "HRCore.h").exists() and (CORE / "HRCore.cpp").exists())

    print("include 自洽（引号形式必须在同目录 / Core 下找得到）")
    missing = []
    for p in sorted(list(VOC.glob("*.cc")) + list(VOC.glob("*.h"))) + [CORE / "HRCore.cpp"]:
        src = p.read_text(encoding="utf-8", errors="replace")
        for inc in re.findall(r'#include\s+"([^"]+)"', src):
            if (p.parent / inc).exists():
                continue
            missing.append(f"{p.name} -> {inc}")
    check("全部能解析" if not missing else "找不到：" + "; ".join(missing), not missing)

    print("没有 Qt / 平台专属头")
    bad_inc = []
    for p in sorted(list(VOC.glob("*.cc")) + list(VOC.glob("*.h"))):
        src = p.read_text(encoding="utf-8", errors="replace")
        # 只看行首的 #include，注释里提到 QtGlobal 不算
        for inc in re.findall(r"^\s*#include\s+<([^>]+)>", src, re.M):
            if inc.startswith("Q") or inc in ("windows.h", "Arduino.h", "QtGlobal"):
                bad_inc.append(f"{p.name} -> <{inc}>")
    check("干净" if not bad_inc else "仍有：" + "; ".join(bad_inc), not bad_inc)

    print("tables.h 里的常量表都有定义")
    tables = (VOC / "tables.h").read_text(encoding="utf-8")
    externs = re.findall(r"extern\s+const\s+[\w:<>]+\s+(\w+)", tables)
    defined = set()
    for p in VOC.glob("*.cc"):
        defined.update(re.findall(r"const\s+[\w:<>]+\s+(\w+)\s*[\[=]", p.read_text(encoding="utf-8", errors="replace")))
    undef = [sym for sym in externs if sym not in defined]
    check(f"{len(externs)} 个常量表", not undef)
    if undef:
        print("      缺定义：" + ", ".join(undef))

    print("halfrate.h 的 C 接口都有实现")
    api = re.search(r"extern \"C\" \{(.*?)\n\}", (VOC / "halfrate.h").read_text(encoding="utf-8"), re.S)
    api_src = api.group(1) if api else ""
    funcs = set(re.findall(r"\b(hr_\w+)\s*\(", api_src))
    defined_api = set()
    for p in VOC.glob("*.cc"):
        defined_api.update(re.findall(r"\b(hr_\w+)\s*\([^;]*?\)\s*\{", p.read_text(encoding="utf-8", errors="replace")))
    required = sorted(f for f in funcs if f not in OPTIONAL_API)
    missing_api = [f for f in required if f not in defined_api]
    check(f"{len(required)} 个必需函数（另有 {len(funcs) - len(required)} 个编码器接口不编进工程）",
          not missing_api)
    if missing_api:
        print("      缺实现：" + ", ".join(missing_api))

    print("HRCore.cpp 用到的 hr_* 都已声明")
    hr_src = (CORE / "HRCore.cpp").read_text(encoding="utf-8")
    used = set(re.findall(r"\b(hr_\w+)\s*\(", hr_src))
    check("; ".join(sorted(used)) if used else "（无）", used <= funcs)

    print("括号配平（去注释与字符串）")
    unbalanced = []
    for p in sorted(list(VOC.glob("*.cc")) + list(VOC.glob("*.h"))) + [CORE / "HRCore.cpp", CORE / "HRCore.h"]:
        s = strip_noise(p.read_text(encoding="utf-8", errors="replace"))
        for o, c in [("{", "}"), ("(", ")"), ("[", "]")]:
            if s.count(o) != s.count(c):
                unbalanced.append(f"{p.name}: {o}={s.count(o)} {c}={s.count(c)}")
    check(f"{len(CC) + len(HH) + 2} 个文件", not unbalanced)
    if unbalanced:
        print("      " + "; ".join(unbalanced))

    print()
    print("全部一致" if ok else "有差异")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
