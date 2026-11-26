# -*- coding: utf-8 -*-
"""生成 EPUB 可视化构建器的应用图标（多尺寸 ICO + 预览 PNG）。

设计：蓝色渐变圆角底 + 打开的书本（章节文本）+ 音视频播放按钮 + 生成闪光。
运行：python GUI/make_icon.py
"""
import math
import os
import struct
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
S = 512                      # 超采样画布
SS = 2                       # 超采样倍数 -> 实际 1024
W = S * SS


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def gradient_bg():
    """左上偏亮、右下偏深的蓝紫渐变，附带柔和高光。"""
    top = (59, 130, 246)      # #3B82F6
    bottom = (91, 63, 234)   # #5B3FEA
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    px = img.load()
    for y in range(W):
        t = y / (W - 1)
        base = lerp(top, bottom, t)
        for x in range(W):
            # 中心稍亮，边缘稍暗，形成球面感
            d = math.hypot(x - W / 2, y - W / 2) / (W / 2)
            shade = 1.0 - 0.18 * min(1.0, d)
            r, g, b = (int(c * shade) for c in base)
            px[x, y] = (r, g, b, 255)
    return img


def rounded_mask():
    mask = Image.new('L', (W, W), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, W - 1, W - 1), radius=int(W * 0.22), fill=255)
    return mask


def draw_star(d, cx, cy, r, color):
    """四角闪光（生成/魔法）。"""
    pts = []
    for i in range(8):
        ang = math.pi / 4 * i - math.pi / 2
        rr = r if i % 2 == 0 else r * 0.28
        pts.append((cx + math.cos(ang) * rr, cy + math.sin(ang) * rr))
    d.polygon(pts, fill=color)


def build():
    bg = gradient_bg()
    bg.putalpha(rounded_mask())
    canvas = bg

    # 柔和高光（左上）
    hi = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hi)
    hd.ellipse((W * 0.05, -W * 0.18, W * 0.72, W * 0.45), fill=(255, 255, 255, 46))
    hi = hi.filter(ImageFilter.GaussianBlur(W * 0.04))
    canvas = Image.alpha_composite(canvas, hi)

    # 书本阴影
    shadow = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse((W * 0.14, W * 0.70, W * 0.86, W * 0.90), fill=(12, 20, 60, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(W * 0.035))
    canvas = Image.alpha_composite(canvas, shadow)

    d = ImageDraw.Draw(canvas)
    U = W / 512.0  # 以 512 为设计坐标的缩放因子

    def P(*pts):
        return [(x * U, y * U) for x, y in pts]

    # 打开的书：左右两页（上缘略斜，呈现翻开感）
    spine = 256 * U
    top_y, bot_y = 168 * U, 372 * U
    left_outer, right_outer = 92 * U, 420 * U

    # 书的厚度/侧面
    d.polygon(P((88, 348), (256, 378), (424, 348), (424, 366),
                (256, 396), (88, 366)), fill=(24, 42, 120, 210))

    # 左页
    d.polygon(P((96, 168), (250, 150), (250, 366), (96, 344)),
              fill=(255, 255, 255, 255))
    # 右页
    d.polygon(P((262, 150), (416, 168), (416, 344), (262, 366)),
              fill=(248, 250, 255, 255))
    # 中缝阴影
    d.polygon(P((250, 150), (262, 150), (262, 366), (250, 366)),
              fill=(190, 200, 225, 255))

    # 左页文字行（章节文本）
    line_col = (148, 163, 184, 255)
    for i, (y, w) in enumerate([(196, 112), (222, 128), (248, 96), (274, 120)]):
        d.rounded_rectangle((112 * U, y * U, (112 + w) * U, (y + 9) * U),
                            radius=4 * U, fill=line_col)

    # 右页：音视频播放按钮
    cx, cy, r = 338 * U, 250 * U, 46 * U
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(79, 70, 229, 255))
    d.ellipse((cx - r + 4 * U, cy - r + 4 * U, cx + r - 4 * U, cy + r - 4 * U),
              outline=(255, 255, 255, 70), width=max(1, int(3 * U)))
    # 播放三角（cx/cy 已是画布坐标，直接用 U 缩放，勿再经过 P）
    d.polygon([(cx - 16 * U, cy - 24 * U),
               (cx + 22 * U, cy),
               (cx - 16 * U, cy + 24 * U)],
              fill=(255, 255, 255, 255))

    # 右页底部波形线（音频）
    wave_col = (99, 102, 241, 255)
    for x, h in [(292, 10), (306, 20), (320, 30), (334, 16),
                 (348, 26), (362, 14), (376, 22)]:
        d.rounded_rectangle((x * U, (322 - h / 2) * U,
                             (x + 6) * U, (322 + h / 2) * U),
                            radius=3 * U, fill=wave_col)

    # 生成闪光
    draw_star(d, 132 * U, 122 * U, 30 * U, (255, 255, 255, 235))
    draw_star(d, 392 * U, 118 * U, 18 * U, (255, 255, 255, 200))

    # 降采样
    final = canvas.resize((S, S), Image.Resampling.LANCZOS)
    return final


def save_dib_ico(img, sizes, path):
    """写出传统 DIB(未压缩 32bpp) 格式的 ICO。

    Delphi 的 brcc32 5.40 不支持 PNG 压缩条目（PIL 默认会用 PNG 存 ICO），
    会报 'Allocate failed'。这里按 BITMAPINFOHEADER + XOR + AND mask 手工
    构造每个尺寸的 DIB 条目，brcc32 与 Windows 都完全兼容。
    """
    entries = []
    for size in sizes:
        cur = img.resize((size, size), Image.Resampling.LANCZOS)
        w = h = size
        px = cur.load()
        xor = bytearray()
        for y in range(h - 1, -1, -1):
            for x in range(w):
                r, g, b, a = px[x, y]
                xor += bytes((b, g, r, a))
        mask_row = ((w + 31) // 32) * 4
        and_mask = bytearray()
        for y in range(h - 1, -1, -1):
            bits = bytearray(mask_row)
            for x in range(w):
                a = px[x, y][3]
                if a < 128:
                    bits[x >> 3] |= 0x80 >> (x & 7)
            and_mask += bits
        header = struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, 32, 0,
                             len(xor) + len(and_mask), 0, 0, 0, 0)
        entries.append(bytes(header) + bytes(xor) + bytes(and_mask))

    n = len(entries)
    data = bytearray(struct.pack('<HHH', 0, 1, n))
    offset = 6 + 16 * n
    for size, body in zip(sizes, entries):
        b = 0 if size >= 256 else size   # ICO 目录中 256 记为 0
        data += struct.pack('<BBBBHHII', b, b, 0, 0, 1, 32, len(body), offset)
        offset += len(body)
    for body in entries:
        data += body
    with open(path, 'wb') as f:
        f.write(data)


def main():
    img = build()
    # 预览 PNG（透明背景）
    preview = os.path.join(HERE, 'AppIcon_preview.png')
    img.save(preview)
    # 多尺寸 DIB 格式 ICO（兼容 Delphi brcc32）
    ico = os.path.join(HERE, 'AppIcon.ico')
    sizes = [16, 24, 32, 48, 64, 128, 256]
    save_dib_ico(img, sizes, ico)
    print('preview:', preview)
    print('ico     :', ico)
    print('ico size:', os.path.getsize(ico), 'bytes')


if __name__ == '__main__':
    main()
