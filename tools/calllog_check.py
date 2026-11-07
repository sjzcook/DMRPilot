#!/usr/bin/env python3
"""CallLogStore 的 SQL 自检。

本机没有 Swift 工具链，编译验证只能等 CI；但通话记录这块真正会出问题的
是 SQL 本身（唯一键、LIKE 转义、分页参数）。所以这里直接**从 Swift 源码里
抽出那几段 SQL**，丢进 Python 的 sqlite3 跑一遍，行为对不上就报错。

覆盖：
  - schema 能建（含唯一索引）
  - 同一次通话重复写入只留一行（看门狗 + 断线双收尾）
  - frames 取大、呼号用 COALESCE 保留已有值
  - 关键字搜索：呼号 / 姓名 / 城市 / 通话组名 / 数字 ID，以及 % _ \\ 的转义
  - 分页：LIMIT/OFFSET 取第二页，空关键字时不带 WHERE 也能跑
  - 总条数与分页数据一致
"""

from __future__ import annotations

import pathlib
import re
import sqlite3
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "DMRPilot" / "CallLogStore.swift"


def fail(message: str) -> None:
    print(f"FAIL {message}")
    global FAILED
    FAILED = True


FAILED = False


def swift_blocks(text: str) -> list[str]:
    """把源码里的多行字符串按 Swift 的规则去缩进、还原转义后返回。"""
    blocks = []
    for match in re.finditer(r'"""(.*?)"""', text, re.S):
        raw = match.group(1)
        lines = raw.split("\n")
        # Swift：结束 """ 前面的那段空白是基准缩进
        closing = match.group(0).split("\n")[-1]
        indent = len(closing) - len(closing.lstrip())
        body = []
        for line in lines:
            body.append(line[indent:] if line[:indent].strip() == "" else line.lstrip())
        block = "\n".join(body).strip()
        # Swift 源码里的 \\ 是转义，落到运行时的 SQL 里只有一个反斜杠
        block = block.replace("\\\\", "\\")
        blocks.append(block)
    return blocks


def escape_like(value: str) -> str:
    """与 Swift 里的 escapeLike 保持一致。"""
    out = []
    for ch in value:
        if ch in ("\\", "%", "_"):
            out.append("\\")
        out.append(ch)
    return "".join(out)


def filter_clause(keyword: str) -> tuple[str, str | None]:
    """WHERE 子句直接从 Swift 源码里抽（见 main），这里只负责拼参数。"""
    trimmed = keyword.strip()
    if not trimmed:
        return "", None
    assert WHERE_CLAUSE is not None
    return WHERE_CLAUSE, f"%{escape_like(trimmed)}%"


WHERE_CLAUSE: str | None = None


def main() -> int:
    text = SOURCE.read_text(encoding="utf-8")
    blocks = swift_blocks(text)

    schema = next((b for b in blocks if "CREATE TABLE" in b), None)
    insert = next((b for b in blocks if "INSERT INTO calls" in b), None)
    select = next((b for b in blocks if "SELECT id, src, dst" in b), None)
    update = next((b for b in blocks if "UPDATE calls" in b), None)

    global WHERE_CLAUSE
    WHERE_CLAUSE = next((b for b in blocks if "WHERE (callsign LIKE" in b), None)

    if not WHERE_CLAUSE:
        fail("源码里找不到搜索用的 WHERE 子句")
        return 1

    if not schema:
        fail("源码里找不到建表语句")
        return 1
    if not insert:
        fail("源码里找不到 INSERT 语句")
        return 1
    if not select:
        fail("源码里找不到 SELECT 语句")
        return 1
    if not update:
        fail("源码里找不到回填呼号的 UPDATE 语句")
        return 1

    # 源码里的 SELECT 带着 \(whereClause) 插值，这里换成实际子句
    if r"\(whereClause)" not in select:
        fail("SELECT 里没有 whereClause 插值，抽取规则需要更新")
        return 1

    db = sqlite3.connect(":memory:")
    db.executescript(schema)

    rows = [
        # src, dst, slot, private, start, end, frames, callsign, name, city, dst_name
        (4600001, 46001, 2, 0, 1_700_000_000.0, 1_700_000_012.0, 24, "BD7IXF", "Chiwai", "Shenzhen", "China 1"),
        (4600002, 46001, 2, 0, 1_700_000_100.0, 1_700_000_110.0, 20, "BG8CVQ", "Yuan", "Wenzhou", "China 1"),
        (3100123, 91, 1, 1, 1_700_000_200.0, 1_700_000_205.0, 10, None, None, None, None),
    ]
    db.executemany(insert, rows)

    count = db.execute("SELECT COUNT(*) FROM calls").fetchone()[0]
    if count != 3:
        fail(f"写入 3 条后表里有 {count} 条")

    # 同一次通话被收尾两次：唯一键应该把它并成一行，frames 取大、呼号不丢
    db.execute(insert, (4600001, 46001, 2, 0, 1_700_000_000.0, 1_700_000_030.0, 30,
                        None, None, None, None))
    count = db.execute("SELECT COUNT(*) FROM calls").fetchone()[0]
    if count != 3:
        fail(f"重复写入同一句后变成 {count} 条（唯一键没生效）")
    ended, frames, callsign = db.execute(
        "SELECT ended_at, frames, callsign FROM calls WHERE src = 4600001").fetchone()
    if abs(ended - 1_700_000_030.0) > 0.001:
        fail("重复写入没有更新结束时间")
    if frames != 30:
        fail(f"重复写入后 frames = {frames}，应为 30（取大）")
    if callsign != "BD7IXF":
        fail(f"重复写入把呼号覆盖成了 {callsign!r}，应该用 COALESCE 保留")

    # 回填：只补空值
    db.execute(update, (None, "Someone", None, 3100123))
    name = db.execute("SELECT name, callsign FROM calls WHERE src = 3100123").fetchone()
    if name[0] != "Someone":
        fail("回填姓名失败")
    if name[1] is not None:
        fail("回填把 NULL 呼号写成了非 NULL")

    def search(keyword: str, limit: int = 100, offset: int = 0):
        clause, pattern = filter_clause(keyword)
        sql = select.replace(r"\(whereClause)", clause)
        # 空关键字时 SQL 里仍然只有 ?2 / ?3，但 ?1 的位置也要占着（Swift 侧
        # 显式 bind_null 了 ?1），所以这里补一个 None。
        params = [pattern, limit, offset]
        return db.execute(sql, params).fetchall()

    cases = [
        ("BG8", 1),      # 呼号子串，大小写不敏感
        ("bg8", 1),
        ("Chiwai", 1),   # 姓名
        ("wenz", 1),     # 城市
        ("China 1", 2),  # 通话组名
        ("3100123", 1),  # 数字 ID（src）
        ("91", 1),       # dst
        ("46000", 2),    # 两个 46000xx
        ("nothing-here", 0),
        ("", 3),         # 空关键字 = 全部
    ]
    for keyword, expected in cases:
        got = len(search(keyword))
        if got != expected:
            fail(f"搜索 {keyword!r} 命中 {got} 条，应为 {expected}")

    # LIKE 通配符必须被转义，否则搜 "%" 会命中所有行
    if len(search("%")) != 0:
        fail("关键字 % 没有转义，命中了不该命中的行")
    if len(search("_")) != 0:
        fail("关键字 _ 没有转义")
    # 转义后要能搜到真正的下划线 / 百分号
    db.execute(insert, (4600009, 9, 1, 0, 1_700_000_300.0, 1_700_000_301.0, 5,
                        "A_B", None, None, None))
    if len(search("A_B")) != 1:
        fail("下划线被当成通配符以外的东西，搜不到 A_B")

    # 分页：倒序取两页，拼起来应该等于全量
    page1 = search("", limit=2, offset=0)
    page2 = search("", limit=2, offset=2)
    if len(page1) != 2 or len(page2) != 2:
        fail(f"分页条数不对：page1={len(page1)} page2={len(page2)}")
    if {r[0] for r in page1} & {r[0] for r in page2}:
        fail("两页之间出现了重复行")
    if page1[0][5] < page1[1][5]:
        fail("没有按开始时间倒序")

    # 总条数与分页口径一致
    clause, pattern = filter_clause("")
    total = db.execute(f"SELECT COUNT(*) FROM calls {clause};",
                       [] if pattern is None else [pattern]).fetchone()[0]
    if total != 4:
        fail(f"count 返回 {total}，应为 4")

    names = [r[8] for r in search("")]
    if names[0] != "A_B":
        fail("最新一条没有排在最前面")

    if FAILED:
        return 1
    print("通话记录 SQL 自检通过（建表 / 幂等写入 / 转义 / 搜索 / 分页）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
