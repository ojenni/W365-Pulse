"""
Generate W365Pulse_waiting.ico — amber/orange clock icon for the "no session
window" waiting state. Uncompressed 32-bit DIB frames (8 sizes) so Windows
can load them with System.Drawing without hitting the PNG-decompression path.
"""

import struct
import math

SIZES = [16, 20, 24, 32, 40, 48, 64, 256]

TOP_COLOR = (217, 119,  6)   # amber  #D97706
BOT_COLOR = (146,  64, 14)   # brown  #92400E
WHITE     = (255, 255, 255)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def blend(fg, bg_rgba, alpha):
    a = alpha / 255.0
    r = int(fg[0] * a + bg_rgba[0] * (1 - a))
    g = int(fg[1] * a + bg_rgba[1] * (1 - a))
    b = int(fg[2] * a + bg_rgba[2] * (1 - a))
    na = min(255, bg_rgba[3] + alpha)
    return (r, g, b, na)


def make_frame(size):
    pixels = []
    for y in range(size):
        t = y / max(size - 1, 1)
        r = lerp(TOP_COLOR[0], BOT_COLOR[0], t)
        g = lerp(TOP_COLOR[1], BOT_COLOR[1], t)
        b = lerp(TOP_COLOR[2], BOT_COLOR[2], t)
        for x in range(size):
            pixels.append((r, g, b, 255))

    # Rounded corners — zero alpha outside a rounded rectangle
    corner_r = size * 0.18
    for y in range(size):
        for x in range(size):
            cdx = max(0.0, corner_r - min(x, size - 1 - x))
            cdy = max(0.0, corner_r - min(y, size - 1 - y))
            dist = math.sqrt(cdx * cdx + cdy * cdy)
            if dist > corner_r:
                pixels[y * size + x] = (0, 0, 0, 0)

    _draw_clock(pixels, size)
    return pixels


def _draw_clock(pixels, size):
    cx = (size - 1) / 2.0
    cy = (size - 1) / 2.0
    margin = max(1.5, size * 0.12)
    radius = size / 2.0 - margin
    if radius < 2:
        return

    ring_th  = max(0.8, size / 20.0)
    hour_th  = max(0.8, size / 14.0)
    min_th   = max(0.6, size / 20.0)

    _aa_circle(pixels, size, cx, cy, radius, WHITE, ring_th)

    # Hour hand → ~10 o'clock position
    ha = math.radians(-60)
    _aa_line(pixels, size, cx, cy,
             cx + math.sin(ha) * radius * 0.52,
             cy - math.cos(ha) * radius * 0.52,
             WHITE, hour_th)

    # Minute hand → ~2 o'clock position
    ma = math.radians(60)
    _aa_line(pixels, size, cx, cy,
             cx + math.sin(ma) * radius * 0.75,
             cy - math.cos(ma) * radius * 0.75,
             WHITE, min_th)


def _aa_circle(pixels, size, cx, cy, radius, color, thickness):
    y0 = max(0, int(cy - radius - 2))
    y1 = min(size, int(cy + radius + 3))
    x0 = max(0, int(cx - radius - 2))
    x1 = min(size, int(cx + radius + 3))
    for y in range(y0, y1):
        for x in range(x0, x1):
            dist = math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
            d = abs(dist - radius)
            if d < thickness + 1:
                alpha = max(0, min(255, int(255 * (1 - max(0, d - thickness + 1)))))
                if alpha > 0:
                    pixels[y * size + x] = blend(color, pixels[y * size + x], alpha)


def _aa_line(pixels, size, x1, y1, x2, y2, color, thickness):
    dx = x2 - x1
    dy = y2 - y1
    length = math.sqrt(dx * dx + dy * dy)
    if length < 0.01:
        return
    nx, ny = dx / length, dy / length
    px, py = -ny, nx
    hw = thickness / 2.0
    steps = max(int(length * 3), 2)
    for i in range(steps + 1):
        t = i / steps
        pcx = x1 + dx * t
        pcy = y1 + dy * t
        ry0 = max(0, int(pcy - hw - 1))
        ry1 = min(size, int(pcy + hw + 2))
        rx0 = max(0, int(pcx - hw - 1))
        rx1 = min(size, int(pcx + hw + 2))
        for y in range(ry0, ry1):
            for x in range(rx0, rx1):
                d = abs((x - pcx) * px + (y - pcy) * py)
                if d < hw + 1:
                    alpha = max(0, min(255, int(255 * (1 - max(0, d - hw + 1)))))
                    if alpha > 0:
                        pixels[y * size + x] = blend(color, pixels[y * size + x], alpha)


def pack_dib(pixels, size):
    # BITMAPINFOHEADER — biHeight doubled (XOR + AND bitmaps stacked)
    header = struct.pack('<IiiHHIIiiII',
        40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)

    xor_data = bytearray()
    for y in range(size - 1, -1, -1):  # bottom-up
        for x in range(size):
            r, g, b, a = pixels[y * size + x]
            xor_data.extend([b, g, r, a])

    row_bytes = ((size + 31) // 32) * 4
    and_data = bytearray(row_bytes * size)  # all zeros = transparent from alpha

    return header + bytes(xor_data) + bytes(and_data)


def build_ico(sizes):
    frames = [(s, pack_dib(make_frame(s), s)) for s in sizes]
    n = len(frames)
    ico_header = struct.pack('<HHH', 0, 1, n)

    offset = 6 + n * 16
    dir_entries = b''
    for s, dib in frames:
        w = s if s < 256 else 0
        h = s if s < 256 else 0
        dir_entries += struct.pack('<BBBBHHII',
            w, h, 0, 0, 1, 32, len(dib), offset)
        offset += len(dib)

    return ico_header + dir_entries + b''.join(dib for _, dib in frames)


data = build_ico(SIZES)
out = 'W365Pulse_waiting.ico'
with open(out, 'wb') as f:
    f.write(data)
print(f"Written {out} ({len(data):,} bytes, {len(SIZES)} frames)")
