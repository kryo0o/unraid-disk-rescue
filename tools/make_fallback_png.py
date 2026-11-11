#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_fallback_png.py - 生成一个 8x8 的极小 PNG（base64），用于没有 python 时的兜底图标。

用法:
    python tools/make_fallback_png.py [--write]
    不带 --write 时只打印 base64 字符串。
"""

import base64
import struct
import sys
import zlib


def make_png(w=8, h=8, rgba=(34, 112, 192, 255)):
    raw = b"".join(b"\x00" + bytes(rgba) * w for _ in range(h))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress(raw, 9)) +
           chunk(b"IEND", b""))
    return png


def main():
    png = make_png()
    b64 = base64.b64encode(png).decode("ascii")
    if "--write" in sys.argv:
        import os
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        for rel in ("icons/diskrescue.png",
                    "package/usr/local/emhttp/plugins/diskrescue/icons/diskrescue.png"):
            path = os.path.join(base, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as fh:
                fh.write(png)
            print("写入", path, len(png), "字节")
    print("BASE64=" + b64)
    print("LEN=%d" % len(png))


if __name__ == "__main__":
    main()
