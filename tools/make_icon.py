#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_icon.py - 生成插件图标（纯 Python，不依赖 Pillow）

用法:
    python tools/make_icon.py

输出:
    package/usr/local/emhttp/plugins/diskrescue/icons/diskrescue.png   (48x48)
    icons/diskrescue.png                                               (64x64，给 .plg 用)

实现：4 倍超采样，每个采样点直接判断「落在哪个形状里」并取对应颜色，
不做 alpha 混合，避免颜色被错误叠加。最后用 zlib 编码成 PNG。
"""

import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_PKG = os.path.join(
    ROOT, "package", "usr", "local", "emhttp", "plugins", "diskrescue", "icons", "diskrescue.png"
)
OUT_REPO = os.path.join(ROOT, "icons", "diskrescue.png")

BG_TOP = (34, 112, 192)
BG_BOT = (16, 58, 116)
WHITE = (246, 249, 253)
RED = (212, 58, 46)
DARK = (26, 36, 48)


def in_rounded(px, py, x0, y0, x1, y1, r):
    if px < x0 or px > x1 or py < y0 or py > y1:
        return False
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    dx = px - cx
    dy = py - cy
    return dx * dx + dy * dy <= r * r


def in_circle(px, py, cx, cy, r):
    return (px - cx) ** 2 + (py - cy) ** 2 <= r * r


def in_ellipse(px, py, cx, cy, rx, ry):
    return ((px - cx) / rx) ** 2 + ((py - cy) / ry) ** 2 <= 1.0


def draw(size):
    f = 4
    s = size * f
    pad = s * 0.04
    radius = s * 0.22

    # 硬盘机身
    bx0, by0 = s * 0.16, s * 0.25
    bx1, by1 = s * 0.84, s * 0.75
    br = s * 0.09

    # 盘片
    pcx, pcy = s * 0.50, s * 0.50
    pr_out = s * 0.175
    pr_in = s * 0.062

    # 警告角标
    wcx, wcy = s * 0.775, s * 0.775
    wr = s * 0.185
    # 感叹号（竖条 + 点）
    bar_x0, bar_x1 = wcx - s * 0.026, wcx + s * 0.026
    bar_y0, bar_y1 = wcy - s * 0.100, wcy + s * 0.018
    dot_r = s * 0.030
    dot_cy = wcy + s * 0.075

    out = []
    for y in range(size):
        row = []
        for x in range(size):
            r = g = b = a = 0.0
            for dy in range(f):
                for dx in range(f):
                    px = x * f + dx + 0.5
                    py = y * f + dy + 0.5
                    col = None

                    if in_circle(px, py, wcx, wcy, wr):
                        # 角标内部：白色感叹号 or 红色底
                        if (bar_x0 <= px <= bar_x1 and bar_y0 <= py <= bar_y1) or \
                           in_circle(px, py, wcx, dot_cy, dot_r):
                            col = WHITE
                        else:
                            col = RED
                    elif in_rounded(px, py, bx0, by0, bx1, by1, br):
                        if in_circle(px, py, pcx, pcy, pr_in):
                            col = WHITE
                        elif in_circle(px, py, pcx, pcy, pr_out):
                            col = BG_BOT
                        else:
                            # 磁头臂：从盘片右上角伸出的一条细线
                            lx0, ly0 = pcx + s * 0.07, pcy - s * 0.14
                            lx1, ly1 = pcx + s * 0.22, pcy - s * 0.235
                            vx, vy = lx1 - lx0, ly1 - ly0
                            t = ((px - lx0) * vx + (py - ly0) * vy) / (vx * vx + vy * vy)
                            t = max(0.0, min(1.0, t))
                            qx, qy = lx0 + t * vx, ly0 + t * vy
                            if (px - qx) ** 2 + (py - qy) ** 2 <= (s * 0.016) ** 2:
                                col = DARK
                            else:
                                col = WHITE
                    elif in_rounded(px, py, pad, pad, s - pad, s - pad, radius):
                        t = (py - pad) / max(1.0, (s - 2 * pad))
                        col = tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3))
                    else:
                        continue  # 透明

                    r += col[0]
                    g += col[1]
                    b += col[2]
                    a += 1.0

            n = float(f * f)
            if a > 0:
                row.append((int(round(r / a)), int(round(g / a)), int(round(b / a)),
                            int(round(a / n * 255))))
            else:
                row.append((0, 0, 0, 0))
        out.append(row)
    return out


def write_png(path, pixels):
    h = len(pixels)
    w = len(pixels[0])
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter: none
        for (r, g, b, a) in row:
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
           chunk(b"IEND", b""))

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(png)
    return len(png)


def main():
    for out, size in ((OUT_PKG, 48), (OUT_REPO, 64)):
        n = write_png(out, draw(size))
        print("生成 %s (%dx%d, %d 字节)" % (out, size, size, n))


if __name__ == "__main__":
    main()
