#!/usr/bin/env python3
"""Generate the workflow's original icon artwork.

Uses only the Python standard library so the build has no dependencies, and so
the icons are reproducible from source. The artwork is drawn here from
primitives; no third-party or vendor imagery is used or redistributed.

Usage: python3 scripts/make-icons.py [output-directory]
"""

import math
import os
import struct
import sys
import zlib

SIZE = 512
SUPERSAMPLE = 4

INK = (0x11, 0x17, 0x24)  # deep slate — the badge body
SHIELD = (0xF4, 0xF7, 0xFB)  # near-white shield
ACCENT = (0x36, 0xC7, 0x8F)  # green: traffic allowed through the gate
CAUTION_BODY = (0xB4, 0x54, 0x09)
CAUTION_MARK = (0xFF, 0xF6, 0xE6)


def rounded_rect(x, y, half, radius):
    """Point-in-rounded-square, centred on the origin."""
    ax, ay = abs(x), abs(y)
    inner = half - radius
    if ax <= inner or ay <= inner:
        return ax <= half and ay <= half
    return math.hypot(ax - inner, ay - inner) <= radius


def shield_half_width(t, width):
    """Half-width of a heater-shield profile at vertical position t in [0, 1].

    Straight flanks with rounded top corners down to the shoulder, then a
    bulged arc that closes to a soft point at the base.
    """
    if t < 0.0 or t > 1.0:
        return 0.0
    shoulder = 0.44
    if t <= shoulder:
        corner = 0.22
        if t < corner:
            k = (corner - t) / corner
            return width * math.sqrt(max(0.0, 1.0 - k * k))
        return width
    k = (t - shoulder) / (1.0 - shoulder)
    return width * max(0.0, 1.0 - k * k) ** 0.62


def in_shield(x, y, top, height, width):
    t = (y - top) / height
    if t < 0.0 or t > 1.0:
        return False
    return abs(x) <= shield_half_width(t, width)


def capsule(x, y, half_width, half_height):
    inner = max(0.0, half_width - half_height)
    if abs(x) <= inner:
        return abs(y) <= half_height
    return math.hypot(abs(x) - inner, y) <= half_height


def triangle(x, y, top, height, half):
    t = (y - top) / height
    if t < 0.0 or t > 1.0:
        return False
    return abs(x) <= half * t


def sample_main(x, y):
    """Colour at a point of the main icon, or None for transparent."""
    if not rounded_rect(x, y, 236.0, 108.0):
        return None

    top, height, width = -190.0, 380.0, 150.0
    if -24.0 <= y <= 24.0 and capsule(x, y, 62.0, 17.0):
        # The bar in the gate is the traffic the filter is currently passing.
        return ACCENT
    if in_shield(x, y, top, height, width):
        # A gate slot cut clean through the crest.
        if -24.0 <= y <= 24.0:
            return INK
        return SHIELD
    return INK


def sample_caution(x, y):
    if not rounded_rect(x, y, 236.0, 108.0):
        return None
    if triangle(x, y, -176.0, 352.0, 210.0):
        # Exclamation: stem plus dot, punched out of the triangle.
        if abs(x) <= 26.0 and -66.0 <= y <= 74.0:
            return CAUTION_MARK
        if math.hypot(x, y - 128.0) <= 28.0:
            return CAUTION_MARK
        return CAUTION_BODY
    return None


def render(sampler, size):
    scale = size / 512.0
    step = 1.0 / SUPERSAMPLE
    rows = []
    weight = SUPERSAMPLE * SUPERSAMPLE
    for py in range(size):
        row = bytearray()
        for px in range(size):
            r = g = b = a = 0
            for sy in range(SUPERSAMPLE):
                for sx in range(SUPERSAMPLE):
                    x = ((px + (sx + 0.5) * step) / scale) - 256.0
                    y = ((py + (sy + 0.5) * step) / scale) - 256.0
                    colour = sampler(x, y)
                    if colour is not None:
                        r += colour[0]
                        g += colour[1]
                        b += colour[2]
                        a += 255
            if a == 0:
                row += b"\x00\x00\x00\x00"
            else:
                covered = a // 255
                row += bytes((r // covered, g // covered, b // covered, a // weight))
        rows.append(bytes(row))
    return rows


def write_png(path, rows, size):
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "workflow"
    os.makedirs(target, exist_ok=True)
    for name, sampler in (
        ("icon.png", sample_main),
        ("icon-caution.png", sample_caution),
    ):
        path = os.path.join(target, name)
        write_png(path, render(sampler, SIZE), SIZE)
        print(f"wrote {path} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
