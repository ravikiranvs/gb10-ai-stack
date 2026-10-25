#!/usr/bin/env python3
"""Regenerate branding/logo.png, branding/favicon.ico and the Grafana icon PNGs (needs Pillow and DejaVu Sans Mono Bold).

Design: an off-white square tile, "gb10" in bold monospace with a block cursor, in near-black with an green cursor. Same colours as the dashboard (--accent / --bg).
branding/logo.svg and branding/grafana/grafana_icon.svg are hand-written and mirror the same design; keep them in step.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent.parent / "branding"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
PAPER, INK, HUE = (0xF4, 0xF4, 0xF0), (0x05, 0x05, 0x05), (0x6F, 0xDC, 0x8C)       # PAPER is the tile, INK the lettering, HUE the cursor


def badge(w, h, size):
    """Square tile with "gb10" and a block cursor, centred. Drawn 4x and scaled down for smooth edges."""
    s = 4
    img = Image.new("RGBA", (w * s, h * s), PAPER + (255,))
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT, size * s)
    adv = font.getlength("g")                       # monospace: every glyph has the same advance
    width = adv * 5                                  # "gb10" + the cursor cell
    x0 = (w * s - width) / 2
    d.text((x0, h * s / 2), "gb10", font=font, fill=INK + (255,), anchor="lm")
    top, bottom = font.getbbox("1", anchor="lm")[1], font.getbbox("1", anchor="lm")[3]     # cursor as tall as a digit, in the fifth cell
    d.rectangle((x0 + adv * 4.12, h * s / 2 + top, x0 + adv * 4.88, h * s / 2 + bottom), fill=HUE + (255,))
    return img.resize((w, h), Image.LANCZOS)


badge(400, 140, 60).save(OUT / "logo.png")
badge(32, 32, 7).save(OUT / "grafana" / "fav32.png")
badge(180, 180, 31).save(OUT / "grafana" / "apple-touch-icon.png")
badge(256, 256, 44).save(OUT / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
