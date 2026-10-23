#!/usr/bin/env python3
"""Regenerate branding/logo.png, branding/favicon.ico and the Grafana icon PNGs (needs Pillow and DejaVu Sans Bold).

Palette matches the dashboard: accent #60a5fa fading to #a78bfa, dark navy #0b1020 lettering.
branding/logo.svg is hand-written and mirrors the same design; keep the two in step.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent.parent / "branding"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
A, B, INK = (0x60, 0xA5, 0xFA), (0xA7, 0x8B, 0xFA), (0x0B, 0x10, 0x20)


def badge(w, h, text, size):
    """Gradient rounded rectangle with centred lettering, drawn 4x and scaled down for smooth edges."""
    s = 4
    img = Image.new("RGBA", (w * s, h * s))
    px = img.load()
    for x in range(w * s):
        t = x / (w * s - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(A, B)) + (255,)
        for y in range(h * s):
            px[x, y] = c
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w * s - 1, h * s - 1), radius=min(w, h) * s // 4, fill=255)
    img.putalpha(mask)
    d = ImageDraw.Draw(img)
    d.text((w * s / 2, h * s / 2), text, font=ImageFont.truetype(FONT, size * s), fill=INK + (255,), anchor="mm")
    return img.resize((w, h), Image.LANCZOS)


badge(400, 140, "GB10", 88).save(OUT / "logo.png")
badge(32, 32, "GB10", 10).save(OUT / "grafana" / "fav32.png")
badge(180, 180, "GB10", 57).save(OUT / "grafana" / "apple-touch-icon.png")
badge(256, 256, "GB10", 82).save(OUT / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
