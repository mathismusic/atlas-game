#!/usr/bin/env python3
"""Draw the home-screen icon.

Safari needs a real PNG for apple-touch-icon, so rather than pull in an image
library this rasterises a small globe by hand and writes the PNG chunks
directly.  Antialiasing is done by 3x supersampling.
"""

import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "Sources", "AtlasServer", "Public", "icon.png")

SIZE = 512
SS = 3                      # supersample factor
BG = (13, 17, 23)
INK = (74, 222, 128)

R = 0.34                    # globe radius, as a fraction of the canvas
STROKE = 0.030              # line half-width


def coverage(x, y):
    """Fraction of ink at supersampled point (x, y), both in -0.5..0.5."""
    d = (x * x + y * y) ** 0.5
    if d > R + STROKE:
        return 0.0

    # Outer circle.
    if abs(d - R) <= STROKE:
        return 1.0
    if d > R:
        return 0.0

    # Two latitude lines.
    for lat in (-R * 0.42, R * 0.42):
        if abs(y - lat) <= STROKE * 0.62:
            return 1.0
    # Equator, slightly heavier.
    if abs(y) <= STROKE * 0.75:
        return 1.0

    # Central meridian plus two ellipses, drawn as |x| = a*sqrt(1-(y/R)^2).
    if abs(x) <= STROKE * 0.7:
        return 1.0
    root = max(0.0, 1.0 - (y / R) ** 2) ** 0.5
    for a in (R * 0.52,):
        edge = a * root
        if edge > 1e-6 and abs(abs(x) - edge) <= STROKE * 0.62:
            return 1.0
    return 0.0


def render():
    rows = []
    step = 1.0 / (SIZE * SS)
    for py in range(SIZE):
        row = bytearray()
        for px in range(SIZE):
            total = 0.0
            for sy in range(SS):
                y = (py + (sy + 0.5) / SS) / SIZE - 0.5
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) / SIZE - 0.5
                    total += coverage(x, y)
            alpha = total / (SS * SS)
            for channel in range(3):
                value = BG[channel] + (INK[channel] - BG[channel]) * alpha
                row.append(int(round(value)))
        rows.append(bytes(row))
    _ = step
    return rows


def write_png(path, rows):
    raw = b"".join(b"\x00" + row for row in rows)   # filter type 0 per scanline

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)   # 8-bit truecolour
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)


if __name__ == "__main__":
    write_png(OUT, render())
    print(f"wrote {os.path.relpath(OUT)}  ({os.path.getsize(OUT)/1024:.1f} KiB)")
