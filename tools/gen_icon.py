#!/usr/bin/env python3
"""
DMRPilot App icon 生成器。

候选：
  ht      —— 手持台（对讲机剪影 + 屏幕里的通话波形）  主推
  tower   —— 桁架天线塔（细杆结构，不是实心三角）
  slots   —— 双时隙（DMR 的 TDMA 特征：两个半环轮流占用一个信道）

所有几何都是精确数值，4 倍超采样后 LANCZOS 缩小，任何尺寸都不发虚。
输出 RGB（无 alpha），符合 iOS AppIcon 要求。

用法：
    python tools/gen_icon.py
"""

import math
import os
from PIL import Image, ImageDraw, ImageOps

OUT = 1024
SS = 4
S = OUT * SS
K = SS

BG_TOP = (14, 26, 44)
BG_BOTTOM = (6, 11, 19)
GLOW = (46, 125, 255)

WHITE = (245, 248, 255)
CYAN_L = (165, 243, 252)
CYAN = (56, 189, 248)
BLUE = (46, 125, 255)
VIOLET = (139, 92, 246)

CX = CY = 512


def px(v):
    return v * K


def make_background():
    grad = Image.linear_gradient("L").resize((S, S), Image.BICUBIC)
    base = Image.composite(
        Image.new("RGB", (S, S), BG_BOTTOM),
        Image.new("RGB", (S, S), BG_TOP),
        grad,
    )
    glow = ImageOps.invert(Image.radial_gradient("L").resize((S, S), Image.BICUBIC))
    glow = glow.point(lambda v: int(v * 0.26))
    return Image.composite(Image.new("RGB", (S, S), GLOW), base, glow)


def fill_mask(mask, color, img):
    """用 L 掩膜贴色，掩膜为黑的区域露出背景，实现真正的镂空。"""
    img.paste(Image.new("RGB", (S, S), color), (0, 0), mask)


def rrect(draw, x0, y0, x1, y1, radius, fill):
    draw.rounded_rectangle((px(x0), px(y0), px(x1), px(y1)), radius=px(radius), fill=fill)


def capsule(draw, p0, p1, width, color):
    w = px(width)
    draw.line((px(p0[0]), px(p0[1]), px(p1[0]), px(p1[1])), fill=color, width=int(w))
    for x, y in (p0, p1):
        draw.ellipse((px(x) - w / 2, px(y) - w / 2, px(x) + w / 2, px(y) + w / 2), fill=color)


def arc_head(draw, center, radius, width, start, end, color):
    """Pillow 的 arc 线宽从外向内，端点圆要落在 半径-线宽/2 上，否则会凸出去。"""
    r = radius - width / 2
    box = (px(center[0] - r), px(center[1] - r), px(center[0] + r), px(center[1] + r))
    draw.arc(box, start=start, end=end, fill=color, width=px(width))
    for ang in (start, end):
        a = math.radians(ang)
        ex = px(center[0]) + px(r) * math.cos(a)
        ey = px(center[1]) + px(r) * math.sin(a)
        draw.ellipse((ex - px(width) / 2, ey - px(width) / 2,
                      ex + px(width) / 2, ey + px(width) / 2), fill=color)


# ---------------------------------------------------------------- 手持台（主推）

def draw_ht(img, with_waves=True):
    mark = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mark)

    rrect(d, 340, 396, 684, 784, 54, 255)      # 机身
    rrect(d, 592, 208, 632, 412, 20, 255)      # 天线
    rrect(d, 576, 364, 648, 412, 20, 255)      # 天线座，只比天线宽一点

    for y in (426, 464, 502):                   # 扬声器槽
        rrect(d, 404, y, 620, y + 24, 12, 0)
    rrect(d, 404, 548, 620, 722, 24, 0)        # 屏幕

    fill_mask(mark, WHITE, img)

    # 屏幕里的通话波形
    draw = ImageDraw.Draw(img)
    for i, h in enumerate((52, 88, 118, 88, 58)):
        x = 434 + i * 38
        rrect(draw, x, 635 - h / 2, x + 24, 635 + h / 2, 12, CYAN)

    if with_waves:
        # 从天线尖向右上方张开。对称地扣在头顶会变成"飞碟帽"，偏向一侧才像在发信
        for radius, width, color in ((56, 22, CYAN_L), (96, 19, BLUE)):
            arc_head(draw, (612, 208), radius, width, -104, -26, color)

    return img


def draw_ht_plain(img):
    return draw_ht(img, with_waves=False)


# ---------------------------------------------------------------- 桁架天线塔

def draw_tower(img):
    draw = ImageDraw.Draw(img)
    apex_y, base_y = 448, 812
    half_top, half_bottom = 16, 108
    w = 30

    # 外腿
    capsule(draw, (CX - half_top, apex_y), (CX - half_bottom, base_y), w, WHITE)
    capsule(draw, (CX + half_top, apex_y), (CX + half_bottom, base_y), w, WHITE)

    # 横撑 + 交叉撑，越往上越窄
    levels = [752, 668, 588, 514]
    for i, y in enumerate(levels):
        t = (y - apex_y) / (base_y - apex_y)
        half = half_top + (half_bottom - half_top) * t
        capsule(draw, (CX - half, y), (CX + half, y), w - 4, WHITE)

    for i in range(len(levels) - 1):
        y0, y1 = levels[i], levels[i + 1]
        t0 = (y0 - apex_y) / (base_y - apex_y)
        t1 = (y1 - apex_y) / (base_y - apex_y)
        h0 = half_top + (half_bottom - half_top) * t0
        h1 = half_top + (half_bottom - half_top) * t1
        capsule(draw, (CX - h0, y0), (CX + h1, y1), 18, WHITE)
        capsule(draw, (CX + h0, y0), (CX - h1, y1), 18, WHITE)

    # 塔尖
    capsule(draw, (CX, apex_y - 96), (CX, apex_y + 6), 26, WHITE)

    for radius, color in ((116, CYAN_L), (196, BLUE)):
        for start, end in ((-72, -20), (200, 252)):
            arc_head(draw, (CX, apex_y - 96), radius, 26, start, end, color)
    return img


# ---------------------------------------------------------------- 双时隙

def draw_slots(img):
    draw = ImageDraw.Draw(img)
    # 两个半环在上下各留一道缺口，像同一个信道被两个时隙轮流切开
    arc_head(draw, (CX, CY), 250, 76, 108, 252, BLUE)
    arc_head(draw, (CX, CY), 250, 76, -72, 72, VIOLET)
    # 中心：一道通话波形
    for i, h in enumerate((78, 134, 176, 134, 78)):
        x = CX - 84 + i * 36
        rrect(draw, x, CY - h / 2, x + 22, CY + h / 2, 11, WHITE)
    return img


VARIANTS = {"ht": draw_ht, "ht_plain": draw_ht_plain, "tower": draw_tower, "slots": draw_slots}


def render(name):
    img = make_background()
    VARIANTS[name](img)
    return img.resize((OUT, OUT), Image.LANCZOS)


def contact_sheet(items, path):
    cell, pad, label_h = 300, 32, 124
    w = pad + (cell + pad) * len(items)
    sheet = Image.new("RGB", (w, pad + cell + label_h), (22, 22, 25))
    d = ImageDraw.Draw(sheet)
    for i, (name, img) in enumerate(items):
        x, y = pad + i * (cell + pad), pad
        r = int(cell * 0.2237)
        mask = Image.new("L", (cell, cell), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, cell - 1, cell - 1), radius=r, fill=255)
        rounded = img.resize((cell, cell), Image.LANCZOS).copy()
        rounded.putalpha(mask)
        sheet.paste(rounded, (x, y), rounded)
        d.text((x + 2, y + cell + 8), name, fill=(230, 230, 236))
        tiny = img.resize((56, 56), Image.LANCZOS).resize((84, 84), Image.NEAREST)
        sheet.paste(tiny, (x + cell - 84, y + cell + 26))
    sheet.save(path, "PNG")
    print("wrote", path)


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    logo_dir = os.path.join(here, "Logo")
    icon_dir = os.path.join(here, "DMRPilot", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(logo_dir, exist_ok=True)

    items = []
    for name in VARIANTS:
        img = render(name)
        img.save(os.path.join(logo_dir, f"dmrpilot-{name}-1024.png"), "PNG")
        items.append((name, img))
        print("wrote", name)

    contact_sheet(items, os.path.join(logo_dir, "compare.png"))
    items[0][1].save(os.path.join(icon_dir, "AppIcon-1024.png"), "PNG")
    print("assets <-", items[0][0])


if __name__ == "__main__":
    main()
