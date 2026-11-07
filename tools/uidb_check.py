#!/usr/bin/env python3
"""本地 DMR ID 库的静态自检（tools/uidb_check.py）

本机没有 Swift 编译器，`DMRUserDatabase.swift` 里那套「扫 CSV → 压索引 → 二分查找
→ 读回那一行」的字节级逻辑只能靠复刻来验。这个脚本用 Python 把同一套算法跑一遍，
喂给它的是一段**构造出来的** CSV，专门覆盖真实文件里出现过的几种脏数据：

  * CRLF 换行（RadioID 的 user.csv 就是 CRLF）
  * 表头 `RADIO_ID,CALLSIGN,...`
  * 空行
  * 带引号且含逗号的字段（真实文件 316264 行里有 1 行是这种）
  * 文件末尾没有换行
  * 重复 ID、超长 ID、首位是 0 的 ID

跑法：

    python tools/uidb_check.py

索引布局必须和 Swift 那边一致：

    "RIDX" | count:UInt32 LE | N × ( id:UInt32 LE | offset:UInt32 LE )，按 id 升序
"""

from __future__ import annotations

import struct
import sys

HEADER_BYTES = 8
ENTRY_BYTES = 8
COMMA = 0x2C
QUOTE = 0x22
LF = 0x0A
CR = 0x0D

CSV = (
    b"RADIO_ID,CALLSIGN,FIRST_NAME,LAST_NAME,CITY,STATE,COUNTRY\r\n"
    b"4600001,BD7IXF,Chiwai,,SHENZHEN,Hunan Guangdong Guangxi Hainan,China\r\n"
    b"\r\n"
    b"4600002,BG8CVQ,Yuan,,wen zhou,,China\r\n"
    b'4600003,BX6AM,River,,"Tainan, West",,China\r\n'
    b"4600004,dup,First,,City,,China\r\n"
    b"4600004,dup,Later,,City,,China\r\n"
    b"123,TOO_SHORT_ID,Ada,,City,,China\r\n"
    b"0076543,LEADING0,Zero,,City,,China\r\n"
    b"16777215,MAXID,Max,,City,,China\r\n"
    b"not-an-id,BROKEN,,,City,,China\r\n"
    b"4600005,NOEOL,Last,,City,,China"
)


# ---------------------------------------------------------------- 建索引

def append_entry(data: bytes, start: int, end: int, out: list[int]) -> None:
    cursor = start
    value = 0
    digits = 0
    while cursor < end:
        byte = data[cursor]
        if not 0x30 <= byte <= 0x39:
            break
        value = value * 10 + (byte - 0x30)
        digits += 1
        cursor += 1
    if digits >= 4 and cursor < end and data[cursor] == COMMA and 0 < value <= 0xFFFFFFFF:
        out.append((value << 32) | start)


def build(data: bytes) -> bytes:
    packed: list[int] = []
    line_start = 0
    cursor = 0
    while cursor < len(data):
        if data[cursor] == LF:
            append_entry(data, line_start, cursor, packed)
            line_start = cursor + 1
        cursor += 1
    if line_start < len(data):
        append_entry(data, line_start, len(data), packed)

    packed.sort()
    index = bytearray(HEADER_BYTES + len(packed) * ENTRY_BYTES)
    index[0:4] = b"RIDX"
    index[4:8] = struct.pack("<I", len(packed))
    for position, entry in enumerate(packed):
        index[HEADER_BYTES + position * ENTRY_BYTES:HEADER_BYTES + (position + 1) * ENTRY_BYTES] = struct.pack("<Q", entry)
    return bytes(index)


# ---------------------------------------------------------------- 查询

def unquote(field: str) -> str:
    if len(field) >= 2 and field.startswith('"') and field.endswith('"'):
        return field[1:-1].replace('""', '"')
    return field


def split_quoted(line: bytes) -> list[str]:
    """`"a,b",c` → ["a,b", "c"]，与 Swift 侧的 RadioIDIndex.splitQuoted 一一对应。"""
    fields: list[str] = []
    current = bytearray()
    in_quotes = False
    cursor = 0
    while cursor < len(line):
        byte = line[cursor]
        if in_quotes:
            if byte == QUOTE:
                if cursor + 1 < len(line) and line[cursor + 1] == QUOTE:
                    current.append(QUOTE)
                    cursor += 2
                    continue
                in_quotes = False
                cursor += 1
                continue
            current.append(byte)
            cursor += 1
            continue
        if byte == QUOTE:
            in_quotes = True
            cursor += 1
            continue
        if byte == COMMA:
            fields.append(current.decode("utf-8", "replace"))
            current.clear()
            cursor += 1
            continue
        current.append(byte)
        cursor += 1

    fields.append(current.decode("utf-8", "replace"))
    return fields


def is_consistent(csv: bytes, index: bytes) -> bool:
    """抽查首 / 中 / 尾三条：偏移指向的行必须以「ID + 逗号」开头。"""
    if not csv or len(index) < HEADER_BYTES:
        return False
    count = struct.unpack("<I", index[4:8])[0]
    if count <= 0 or len(index) < HEADER_BYTES + count * ENTRY_BYTES:
        return False

    for position in (0, count // 2, count - 1):
        value = struct.unpack("<Q", index[HEADER_BYTES + position * ENTRY_BYTES:HEADER_BYTES + (position + 1) * ENTRY_BYTES])[0]
        entry_id = value >> 32
        offset = value & 0xFFFFFFFF
        if offset >= len(csv):
            return False
        end = csv.find(b",", offset, offset + 14)
        if end < 0:
            return False
        head = csv[offset:end]
        if not head.isdigit():
            return False
        if int(head) != entry_id:
            return False
    return True


def lookup(data: bytes, index: bytes, target: int):
    if len(index) < HEADER_BYTES:
        return None
    count = struct.unpack("<I", index[4:8])[0]
    if count <= 0 or len(index) < HEADER_BYTES + count * ENTRY_BYTES:
        return None

    low, high, offset = 0, count - 1, -1
    while low <= high:
        mid = (low + high) // 2
        value = struct.unpack("<Q", index[HEADER_BYTES + mid * ENTRY_BYTES:HEADER_BYTES + (mid + 1) * ENTRY_BYTES])[0]
        entry_id = value >> 32
        if entry_id == target:
            offset = value & 0xFFFFFFFF
            break
        if entry_id < target:
            low = mid + 1
        else:
            high = mid - 1
    if offset < 0:
        return None

    end = data.find(b"\n", offset)
    if end < 0:
        end = len(data)
    stop = end - 1 if end > offset and data[end - 1] == CR else end
    if stop <= offset:
        return None

    line = data[offset:stop]
    if QUOTE in line:
        fields = split_quoted(line)
    else:
        fields = line.decode("utf-8", "replace").split(",")
    if len(fields) < 2:
        return None
    callsign = fields[1].strip().upper()
    if not callsign:
        return None

    def field(i: int) -> str:
        return fields[i].strip() if i < len(fields) else ""

    return {
        "id": target,
        "callsign": callsign,
        "given": field(2),
        "surname": field(3),
        "city": field(4),
        "state": field(5),
    }


# ---------------------------------------------------------------- 断言

CASES = [
    (4600001, "BD7IXF", "Chiwai", "SHENZHEN"),
    (4600002, "BG8CVQ", "Yuan", "wen zhou"),
    # 引号里有逗号：按逗号硬切会让后面的列整体错位，这里必须整行按引号规则重切
    (4600003, "BX6AM", "River", "Tainan, West"),
    (76543, "LEADING0", "Zero", "City"),
    (16777215, "MAXID", "Max", "City"),
    (4600005, "NOEOL", "Last", "City"),
]

MISSES = [0, 123, 999999, -1]

# 索引条数：上面 11 行数据里，表头 / 空行 / 3 位 ID / 非数字行被筛掉，
# 4600004 出现两次所以占两条 —— 8 条。
EXPECTED_ENTRIES = 8


def main() -> int:
    index = build(CSV)
    count = struct.unpack("<I", index[4:8])[0]

    problems: list[str] = []

    if count != EXPECTED_ENTRIES:
        problems.append(f"索引条数 {count}，应为 {EXPECTED_ENTRIES}（表头 / 空行 / 短 ID / 非数字行都要被筛掉）")

    if len(index) != HEADER_BYTES + count * ENTRY_BYTES:
        problems.append(f"索引长度 {len(index)} 与条数 {count} 不自洽")

    if index[:4] != b"RIDX":
        problems.append("索引缺少 RIDX 魔数")

    for target, callsign, given, city in CASES:
        user = lookup(CSV, index, target)
        if user is None:
            problems.append(f"{target} 查不到")
            continue
        if user["callsign"] != callsign:
            problems.append(f"{target} 呼号 {user['callsign']} != {callsign}")
        if user["given"] != given:
            problems.append(f"{target} 名 {user['given']!r} != {given!r}")
        if user["city"] != city:
            problems.append(f"{target} 城市 {user['city']!r} != {city!r}")

    for target in MISSES:
        if lookup(CSV, index, target) is not None:
            problems.append(f"{target} 不该查到")

    # 一致性抽查：正常配对必须通过；CSV 被换成另一份（这里在前面插一行，所有偏移错位）
    # 时必须判为不一致。
    if not is_consistent(CSV, index):
        problems.append("正常的 CSV / 索引被判成不一致")
    shifted = b"9999999,SHIFT,Shift,,City,,China\r\n" + CSV
    if is_consistent(shifted, index):
        problems.append("CSV 与索引错位时没有判为不一致")

    if problems:
        for problem in problems:
            print(f"FAIL {problem}")
        return 1

    print(f"OK  {count} 条记录，{len(index)} 字节索引，{len(CASES)} 次命中 + {len(MISSES)} 次未命中全部正确")
    return 0


if __name__ == "__main__":
    sys.exit(main())
