#!/usr/bin/env python3
"""HMRDP 应用图标生成器（原创设计）。

设计语言：
- 背景：深蓝 → 青色对角渐变，科技感
- 前景：白色圆角矩形屏幕轮廓，右下角一枚触控圆点 + 两道外扩波纹，
  隐喻「指尖远程控制一块屏幕」。纯几何原创构图。

输出（1024x1024）：
- background.png   分层图标背景
- foreground.png   分层图标前景（透明底）
- app_icon.png     合成后的圆角单图（预览/市场素材）
- startIcon.png    启动页图标（同合成图）
"""
import math
import os
import sys

from PIL import Image, ImageDraw

S = 4  # 超采样倍数
SIZE = 1024
CANVAS = SIZE * S

# 调色
C_TOP = (13, 27, 77)      # 深藏蓝
C_MID = (23, 92, 177)     # 皇家蓝
C_BOT = (36, 190, 232)    # 亮青

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT, exist_ok=True)


def lerp(a, b, t):
    return tuple(int(x + (y - x) * t) for x, y in zip(a, b))


def make_background():
    img = Image.new("RGB", (CANVAS, CANVAS))
    px = img.load()
    for y in range(CANVAS):
        for x in range(0, CANVAS, 8):  # 分块加速，块内颜色一致
            t = (x + y) / (2 * CANVAS)
            c = lerp(C_TOP, C_MID, t * 2) if t < 0.5 else lerp(C_MID, C_BOT, (t - 0.5) * 2)
            for dx in range(8):
                px[x + dx, y] = c
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def make_foreground():
    """白色玻璃感前景：屏幕轮廓 + 触控点 + 波纹。"""
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    d = ImageDraw.Draw(mask)

    def sc(v):
        return int(v * S)

    # 屏幕圆角矩形轮廓（中心偏左上，为触控点留出呼吸空间）
    rect = (sc(232), sc(276), sc(744), sc(640))
    d.rounded_rectangle(rect, radius=sc(64), outline=255, width=sc(52))

    # 屏内两道内容横条（暗示桌面窗口，几何抽象）
    d.rounded_rectangle((sc(320), sc(376), sc(560), sc(420)), radius=sc(22), fill=255)
    d.rounded_rectangle((sc(320), sc(464), sc(480), sc(508)), radius=sc(22), fill=255)

    # 触控点区域：先在屏幕描边上打一个透明豁口，让圆点悬浮其上
    cx, cy, r = 700, 636, 62
    d.ellipse((sc(cx - r - 34), sc(cy - r - 34), sc(cx + r + 34), sc(cy + r + 34)), fill=0)
    # 圆点本体
    d.ellipse((sc(cx - r), sc(cy - r), sc(cx + r), sc(cy + r)), fill=255)
    # 两道向右下外扩的波纹（PIL 角度：0°=三点钟方向，顺时针）
    for rad, w in ((r + 74, 30), (r + 138, 26)):
        bbox = (sc(cx - rad), sc(cy - rad), sc(cx + rad), sc(cy + rad))
        d.arc(bbox, start=-32, end=122, fill=255, width=sc(w))

    mask = mask.resize((SIZE, SIZE), Image.LANCZOS)
    fg = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    white = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))
    fg.paste(white, (0, 0), mask)
    return fg


def rounded(img, radius=232):
    m = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, CANVAS, CANVAS), radius=radius * S, fill=255)
    m = m.resize((SIZE, SIZE), Image.LANCZOS)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(img.convert("RGBA"), (0, 0), m)
    return out


def main():
    bg = make_background()
    fg = make_foreground()

    bg.save(os.path.join(OUT, "background.png"))
    fg.save(os.path.join(OUT, "foreground.png"))

    composed = bg.convert("RGBA")
    composed.alpha_composite(fg)
    rounded(composed).save(os.path.join(OUT, "app_icon.png"))
    composed.save(os.path.join(OUT, "startIcon.png"))
    print("图标已生成到", OUT)


if __name__ == "__main__":
    sys.exit(main())
