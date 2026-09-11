#!/usr/bin/env python3
"""Builds the highway shield sprite sheet.

Artwork comes from openstreetmap-americana (CC0-1.0, public domain), which
maintains proper route shields for every US state — California's spade,
Colorado's, the Interstate and US route markers — rather than the generic
plates we started with.

    https://github.com/osm-americana/openstreetmap-americana

Shields are *not* stretchable sprites. Americana draws a separate shape per
digit count because a 3-digit California spade is not a 2-digit one scaled
horizontally, so we follow suit: every network gets a `_2` and a `_3`
variant, and the style picks between them on text length. Where americana
ships only one width, it is used for both; where it ships nothing for a
state, a generic plate is generated so the style's name lookup always
resolves and MapLibre never logs a missing image.

Requires: rsvg-convert (brew install librsvg), Pillow.

    python3 scripts/make_shields.py
"""
import io, json, os, subprocess, sys, urllib.request
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Swiftcamp", "Resources", "sprites")
CACHE = os.path.join(HERE, ".shield-cache")
RAW = "https://raw.githubusercontent.com/osm-americana/openstreetmap-americana/main/icons/"
LIST = "https://api.github.com/repos/osm-americana/openstreetmap-americana/contents/icons"

BASE_H = 20          # shield height in CSS pixels

STATES = ("al ak az ar ca co ct de dc fl ga hi id il in ia ks ky la me md ma mi mn ms mo "
          "mt ne nv nh nj nm ny nc nd oh ok or pa ri sc sd tn tx ut vt va wa wv wi wy").split()

def fetch(url, binary=True):
    os.makedirs(CACHE, exist_ok=True)
    key = os.path.join(CACHE, url.rsplit("/", 1)[-1].replace("?", "_"))
    if os.path.exists(key):
        return open(key, "rb").read()
    with urllib.request.urlopen(url) as r:
        data = r.read()
    open(key, "wb").write(data)
    return data

def available():
    names = {f["name"] for f in json.loads(fetch(LIST)) if f["name"].endswith(".svg")}
    return names

def render(svg_name, scale):
    """SVG -> RGBA image at BASE_H * scale tall, aspect preserved."""
    svg = fetch(RAW + svg_name)
    p = subprocess.run(["rsvg-convert", "-h", str(BASE_H * scale), "-f", "png"],
                       input=svg, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(f"rsvg-convert failed on {svg_name}: {p.stderr.decode()[:200]}")
    return Image.open(io.BytesIO(p.stdout)).convert("RGBA")

def plate(scale, digits):
    """Fallback: a white plate with a dark border, for networks americana
    has no artwork for. Same silhouette as a generic state route marker."""
    h = BASE_H * scale
    w = int(h * (1.15 if digits == 2 else 1.45))
    ss = 8
    img = Image.new("RGBA", (w*ss, h*ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = int(min(w, h) * ss * 0.18)
    d.rounded_rectangle([0, int(h*ss*0.06), w*ss-1, int(h*ss*0.94)], radius=r, fill=(40, 40, 40, 255))
    m = int(min(w, h) * ss * 0.10)
    d.rounded_rectangle([m, int(h*ss*0.06)+m, w*ss-1-m, int(h*ss*0.94)-m],
                        radius=max(1, r-m), fill=(255, 255, 255, 255))
    return img.resize((w, h), Image.LANCZOS)

def pick(names, stem, digits):
    """Best artwork for a stem at a digit count, or None for the plate.

    Naming is not uniform across the library. Most shields are
    `shield_us_<st>[_<digits>].svg`, but New Mexico's zia is published under
    a `shield40_` prefix and Tennessee and Texas use `_primary` / `_outline`
    suffixes. Falling back to the plate for the rest is correct rather than
    lazy: americana itself draws those states as a plain rectangle, because
    their real markers are plain rectangles.
    """
    tail = stem.split("shield_us_")[-1] if "shield_us_" in stem else None
    cands = [f"{stem}_{digits}.svg", f"{stem}.svg"]
    if tail:
        cands += [f"shield40_us_{tail}_{digits}.svg",
                  f"shield_us_{tail}_primary.svg",
                  f"shield_us_{tail}_outline.svg"]
    for cand in cands:
        if cand in names:
            return cand
    return None

def build():
    names = available()
    # sprite name -> svg file (or None to synthesise a plate)
    wanted = {}
    for digits in (2, 3):
        wanted[f"shield-interstate-{digits}"] = pick(names, "shield_us_interstate", digits)
        wanted[f"shield-us-{digits}"] = pick(names, "shield_badge", digits)
        # Last-resort marker for a network we have no state for, so the
        # style's name lookup always resolves to a real image.
        wanted[f"shield-plate-{digits}"] = None
        for st in STATES:
            wanted[f"shield-{st}-{digits}"] = pick(names, f"shield_us_{st}", digits)

    missing = sorted(k for k, v in wanted.items() if v is None)
    print(f"{len(wanted)} shields, {len(missing)} falling back to a generic plate")
    if missing:
        print("  " + " ".join(sorted({m.rsplit('-', 1)[0] for m in missing})))

    for scale, suffix in ((1, ""), (2, "@2x")):
        images = {}
        for key, svg in sorted(wanted.items()):
            digits = int(key.rsplit("-", 1)[1])
            images[key] = render(svg, scale) if svg else plate(scale, digits)

        pad = 2 * scale
        # Single row keeps packing trivial; the sheet stays a few thousand
        # pixels wide, well inside any texture limit.
        total_w = sum(im.width + pad for im in images.values()) + pad
        max_h = max(im.height for im in images.values()) + 2 * pad
        sheet = Image.new("RGBA", (total_w, max_h), (0, 0, 0, 0))
        index, x = {}, pad
        for key, im in images.items():
            sheet.alpha_composite(im, (x, pad))
            index[key] = {"x": x, "y": pad, "width": im.width, "height": im.height,
                          "pixelRatio": scale}
            x += im.width + pad

        os.makedirs(OUT, exist_ok=True)
        sheet.save(os.path.join(OUT, f"sprite{suffix}.png"))
        with open(os.path.join(OUT, f"sprite{suffix}.json"), "w") as f:
            json.dump(index, f, indent=1, sort_keys=True)
        print(f"sprite{suffix}.png  {sheet.size[0]}x{sheet.size[1]}  {len(index)} icons")

if __name__ == "__main__":
    build()
