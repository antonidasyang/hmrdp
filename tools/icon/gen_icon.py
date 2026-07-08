#!/usr/bin/env python3
"""HMRDP 应用图标生成器（原创设计）。

设计语言：
- 背景：深蓝 → 青色对角渐变，科技感
- 前景：白色圆角矩形屏幕轮廓，右下角一枚触控圆点 + 两道外扩波纹，
  隐喻「指尖远程控制一块屏幕」。纯几何原创构图。

华为应用市场 / 鸿蒙图标合规（对齐 openvpn-oh 过审经验）：
- 分层前景主体必须落在中心「安全区」内，四周留足空白（本脚本按最大边 ~56%
  等比缩放并居中，左右/上下留白 ≥21%），避免被圆形/圆角方形蒙版裁切或偏心。
- 商店 / 应用图标（app_icon、startIcon、appgallery_icon_*）必须「满铺、不透明、
  不自带圆角」——圆角由系统/商店自动添加，自带圆角或透明留白会被审核驳回。

输出（out/，1024x1024 除特别标注）：
- background.png            分层图标背景（满铺渐变）
- foreground.png           分层图标前景（透明底，主体居中安全区）
- app_icon.png             合成单图（满铺不透明，无圆角）
- startIcon.png            启动页图标（满铺不透明）
- appgallery_icon_1024.png 商店图标 1024（满铺不透明，上传用）
- appgallery_icon_216.png  商店图标 216（满铺不透明，上传用）
"""
import os
import sys

from PIL import Image, ImageDraw

S = 4  # 超采样倍数
SIZE = 1024
CANVAS = SIZE * S

# 前景主体在最终 1024 画布中的最大边占比（对称居中，留白 ≥ (1-该值)/2）
FG_MAX_FRAC = 0.56

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


def _draw_composition():
    """在超采样画布上绘制白色前景构图（屏幕轮廓 + 触控点 + 波纹），返回 L 掩膜。"""
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    d = ImageDraw.Draw(mask)

    def sc(v):
        return int(v * S)

    # 屏幕圆角矩形轮廓
    d.rounded_rectangle((sc(232), sc(276), sc(744), sc(640)), radius=sc(64), outline=255, width=sc(52))
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
    return mask


def make_foreground():
    """白色前景：整体裁到内容包围盒，等比缩放进中心安全区并居中。"""
    mask = _draw_composition()
    bbox = mask.getbbox()
    crop = mask.crop(bbox)
    cw, ch = crop.size
    target = int(SIZE * FG_MAX_FRAC)                 # 最终画布中主体最大边
    scale = target / max(cw, ch)
    nw, nh = max(1, round(cw * scale)), max(1, round(ch * scale))
    crop = crop.resize((nw, nh), Image.LANCZOS)

    fgmask = Image.new("L", (SIZE, SIZE), 0)
    fgmask.paste(crop, ((SIZE - nw) // 2, (SIZE - nh) // 2))  # 包围盒居中

    fg = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    white = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))
    fg.paste(white, (0, 0), fgmask)
    return fg


def main():
    bg = make_background()          # RGB 满铺
    fg = make_foreground()          # RGBA 透明底

    bg.save(os.path.join(OUT, "background.png"))
    fg.save(os.path.join(OUT, "foreground.png"))

    # 合成满铺不透明单图（不加圆角、不留透明）——商店/应用图标合规要求
    composed = bg.convert("RGBA")
    composed.alpha_composite(fg)
    flat = composed.convert("RGB")

    flat.save(os.path.join(OUT, "app_icon.png"))
    flat.save(os.path.join(OUT, "startIcon.png"))
    flat.save(os.path.join(OUT, "appgallery_icon_1024.png"))
    flat.resize((216, 216), Image.LANCZOS).save(os.path.join(OUT, "appgallery_icon_216.png"))
    print("图标已生成到", OUT)


if __name__ == "__main__":
    sys.exit(main())
