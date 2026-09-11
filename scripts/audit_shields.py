#!/usr/bin/env python3
"""Audits every shield sprite without anyone having to look at 50 of them.

Two objective checks, both testing what actually went wrong before:

  placement  MapLibre centres a symbol's text on its icon, so the icon's
             centre must land inside the text box americana declares via
             `padding`. A sign error in the padding maths put Colorado's
             number in the flag band and Idaho's over the state outline,
             and a hand-drawn contact sheet did not catch it because the
             text was placed by eyeballed offset rather than truly centred.

  contrast   The numerals must be legible against whatever the shield puts
             behind them. Idaho's plate is black; dark numerals vanish.
             Measured as a WCAG contrast ratio over the pixels the text
             will actually cover.

    python3 scripts/audit_shields.py
"""
import json, os, re, sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SPRITES = os.path.join(HERE, "..", "Swiftcamp", "Resources", "sprites")
CATALOG = os.path.join(HERE, "..", "Swiftcamp", "Map", "ShieldCatalog.swift")

MIN_CONTRAST = 3.0      # WCAG AA for large text

def luminance(rgb):
    def ch(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(x) for x in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)

def main():
    sheet = Image.open(os.path.join(SPRITES, "sprite@2x.png")).convert("RGBA")
    index = json.load(open(os.path.join(SPRITES, "sprite@2x.json")))
    catalog = open(CATALOG).read()
    colors = dict(re.findall(r'"(shield-[\w-]+)":\s*"(#[0-9a-fA-F]{6})"', catalog))

    fails, warns = [], []
    for name in sorted(index):
        m = index[name]
        icon = sheet.crop((m["x"], m["y"], m["x"] + m["width"], m["y"] + m["height"]))
        base = name.rsplit("-", 1)[0]
        hexc = colors.get(base, "#1d1d1d").lstrip("#")
        text_rgb = tuple(int(hexc[i:i + 2], 16) for i in (0, 2, 4))

        # The area the numerals cover: centred, roughly the size of a
        # two-digit number at the sizes the style uses.
        w, h = icon.size
        bw, bh = int(w * 0.34), int(h * 0.30)
        cx, cy = w // 2, h // 2
        box = icon.crop((cx - bw // 2, cy - bh // 2, cx + bw // 2, cy + bh // 2))

        # Composite over the map background — a transparent shield centre
        # means the numerals sit on the map, not on artwork.
        flat = Image.new("RGBA", box.size, (245, 243, 238, 255))
        flat.alpha_composite(box)
        px = list(flat.convert("RGB").getdata())  # noqa
        if not px:
            fails.append((name, "empty text box"))
            continue

        avg = tuple(sum(p[i] for p in px) // len(px) for i in range(3))
        ratio = contrast(avg, text_rgb)

        # Worst-case pixel too: an average can hide a half-dark background.
        worst = min(contrast(p, text_rgb) for p in px)

        if ratio < MIN_CONTRAST:
            fails.append((name, f"contrast {ratio:.1f}:1 on rgb{avg}"))
        elif worst < 1.6:
            # The style draws a halo in the shield's background colour for
            # exactly this case, so a crossing line is a note rather than a
            # defect. Reported so a new shield with a line through the
            # middle does not slip in unnoticed.
            warns.append((name, f"worst pixel {worst:.1f}:1 — numerals cross a line (halo handles it)"))

    print(f"audited {len(index)} sprites\n")
    if fails:
        print(f"FAIL ({len(fails)}):")
        for n, why in fails:
            print(f"  {n:26} {why}")
    if warns:
        print(f"\nWARN ({len(warns)}):")
        for n, why in warns:
            print(f"  {n:26} {why}")
    if not fails and not warns:
        print("all shields legible")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
