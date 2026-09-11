#!/usr/bin/env python3
"""Generates the highway shield sprite sheet.

MapLibre draws a shield as an `icon-image` with `icon-text-fit`, which
stretches one image to fit whatever text sits on it. That is why these are
*stretchable* sprites: the `stretchX`/`stretchY` zones say which band of
pixels may be repeated, and `content` says where the text goes. One image
per shield type then serves "6" and "285" alike without distorting the
border.

Run after changing shield artwork:
    python3 scripts/make_shields.py

Writes sprite.png/.json and sprite@2x.png/.json into Resources/sprites/.
"""
import json, os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "Swiftcamp", "Resources", "sprites")
SS = 8          # supersample factor; PIL has no antialiased polygon fill
BASE_W, BASE_H = 26, 24

# Normalised outlines (0..1 in both axes).
INTERSTATE = [(0.06,0.20),(0.11,0.07),(0.89,0.07),(0.94,0.20),
              (0.94,0.44),(0.86,0.64),(0.64,0.87),(0.50,0.97),
              (0.36,0.87),(0.14,0.64),(0.06,0.44)]
US_ROUTE   = [(0.08,0.14),(0.30,0.06),(0.50,0.09),(0.70,0.06),(0.92,0.14),
              (0.92,0.50),(0.74,0.80),(0.50,0.97),(0.26,0.80),(0.08,0.50)]

def poly(d, pts, w, h, fill, outline=None, width=0):
    p = [(x*w, y*h) for x, y in pts]
    d.polygon(p, fill=fill)
    if outline:
        d.line(p + [p[0]], fill=outline, width=width, joint="curve")

def interstate(w, h):
    img = Image.new("RGBA", (w*SS, h*SS), (0,0,0,0))
    d = ImageDraw.Draw(img)
    W, H = w*SS, h*SS
    # White border, then the blue body inset inside it.
    poly(d, INTERSTATE, W, H, (255,255,255,255))
    inner = [(0.5 + (x-0.5)*0.86, 0.5 + (y-0.5)*0.86) for x, y in INTERSTATE]
    poly(d, inner, W, H, (16,58,122,255))
    # Red crown across the top third of the body.
    band = Image.new("RGBA", (W, H), (0,0,0,0))
    bd = ImageDraw.Draw(band)
    poly(bd, inner, W, H, (200,32,44,255))
    bd.rectangle([0, int(H*0.30), W, H], fill=(0,0,0,0))
    img.alpha_composite(band)
    return img.resize((w, h), Image.LANCZOS)

def us_route(w, h):
    img = Image.new("RGBA", (w*SS, h*SS), (0,0,0,0))
    d = ImageDraw.Draw(img)
    W, H = w*SS, h*SS
    poly(d, US_ROUTE, W, H, (40,40,40,255))
    inner = [(0.5 + (x-0.5)*0.84, 0.5 + (y-0.5)*0.84) for x, y in US_ROUTE]
    poly(d, inner, W, H, (255,255,255,255))
    return img.resize((w, h), Image.LANCZOS)

def state(w, h):
    img = Image.new("RGBA", (w*SS, h*SS), (0,0,0,0))
    d = ImageDraw.Draw(img)
    W, H = w*SS, h*SS
    r = int(min(W, H)*0.18)
    d.rounded_rectangle([0, int(H*0.06), W-1, int(H*0.94)], radius=r, fill=(40,40,40,255))
    m = int(min(W, H)*0.10)
    d.rounded_rectangle([m, int(H*0.06)+m, W-1-m, int(H*0.94)-m],
                        radius=max(1, r-m), fill=(255,255,255,255))
    return img.resize((w, h), Image.LANCZOS)

SHAPES = {"shield-interstate": interstate, "shield-us": us_route, "shield-state": state}

def build(scale):
    w, h = BASE_W*scale, BASE_H*scale
    pad = 2*scale
    sheet = Image.new("RGBA", (len(SHAPES)*(w+pad)+pad, h+2*pad), (0,0,0,0))
    index, x = {}, pad
    for name, fn in SHAPES.items():
        sheet.alpha_composite(fn(w, h), (x, pad))
        # Stretch only the middle third horizontally: the curved shoulders
        # must not be repeated or the shield deforms on a 3-digit route.
        index[name] = {
            "x": x, "y": pad, "width": w, "height": h, "pixelRatio": scale,
            "stretchX": [[int(w*0.34), int(w*0.66)]],
            "stretchY": [[int(h*0.40), int(h*0.62)]],
            "content": [int(w*0.14), int(h*0.22), int(w*0.86), int(h*0.80)],
        }
        x += w + pad
    return sheet, index

os.makedirs(OUT, exist_ok=True)
for scale, suffix in ((1, ""), (2, "@2x")):
    sheet, index = build(scale)
    sheet.save(os.path.join(OUT, f"sprite{suffix}.png"))
    with open(os.path.join(OUT, f"sprite{suffix}.json"), "w") as f:
        json.dump(index, f, indent=1)
    print(f"sprite{suffix}.png  {sheet.size[0]}x{sheet.size[1]}  {len(index)} icons")
