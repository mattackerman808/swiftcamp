#!/usr/bin/env python3
"""Builds the highway shield sprite sheet from openstreetmap-americana.

Artwork *and* its metadata come from americana (CC0, public domain):

    https://github.com/osm-americana/openstreetmap-americana

Three things are needed per route network, and americana hand-maintains
all three in `src/js/shield_defs.js`. Taking them from there rather than
inferring them is the whole point of this script:

  spriteBlank  which artwork, with separate 2- and 3-digit shapes where a
               wider number needs a genuinely different outline
  textColor    Idaho's plate is black and California's spade is green;
               dark numerals vanish on both
  padding      *where* the numerals belong. Rarely the middle: Idaho puts
               them upper-right of the state outline, Colorado below the
               flag band. An earlier version of this script guessed
               placement from pixel centroids and got Colorado, Oklahoma,
               Texas and Louisiana wrong while only half-fixing Idaho.

MapLibre always centres a symbol's text on its icon and has no per-image
offset. So rather than emit offsets the style would have to apply, each
sprite is padded with transparent margin until the padding-defined text
box is centred in the image. Centred text then lands correctly, and the
style stays free of per-shield special cases.

The waypoint symbols from `make_symbols.py` go into the same sheet, because
a style names one sprite and the shields and the symbols are drawn on the
same map.

Requires: rsvg-convert (brew install librsvg), Pillow.

    python3 scripts/make_shields.py
"""
import io, json, os, re, subprocess, urllib.request
from PIL import Image, ImageDraw
import make_symbols

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Swiftcamp", "Resources", "sprites")
CATALOG = os.path.join(HERE, "..", "Swiftcamp", "Map", "ShieldCatalog.swift")
CACHE = os.path.join(HERE, ".shield-cache")
BASE = "https://raw.githubusercontent.com/osm-americana/openstreetmap-americana/main/"

BASE_H = 20          # shield height in CSS pixels; also americana's SVG height

STATES = ("al ak az ar ca co ct de dc fl ga hi id il in ia ks ky la me md ma mi mn ms mo "
          "mt ne nv nh nj nm ny nc nd oh ok or pa ri sc sd tn tx ut vt va wa wv wi wy").split()

# Approximations of americana's Pantone references; only the ones actually
# used as *text* colours matter.
COLORS = {"white": "#ffffff", "black": "#1d1d1d", "blue": "#003f87",
          "green": "#006b3f", "yellow": "#ffcd00", "red": "#c8102e",
          "brown": "#603d20", "orange": "#e87500", "purple": "#5f259f",
          "pink": "#d986ba", "tan": "#c8b48b", "yellow_green": "#b5bd00"}

def fetch(path):
    os.makedirs(CACHE, exist_ok=True)
    key = os.path.join(CACHE, path.rsplit("/", 1)[-1])
    if os.path.exists(key):
        return open(key, "rb").read()
    with urllib.request.urlopen(BASE + path) as r:
        data = r.read()
    open(key, "wb").write(data)
    return data

def parse_defs():
    """Extracts {network: {blanks, textColor, padding}} from shield_defs.js.

    A regex parser over someone else's JavaScript is not lovely, but the
    file is regular in shape and the alternative is hand-copying several
    hundred hand-tuned numbers, which would be stale within a release.

    Two indirections have to be followed or most networks come back empty.
    Shared shapes are declared as `const usInterstateShield = {...}` and
    spread into each network with `...usInterstateShield`, and many networks
    are plain aliases of another. Networks built by helper *functions*
    (`trapezoidDownShield(...)` and friends) are drawn procedurally upstream
    with no SVG behind them, so they legitimately fall through to our plate.
    """
    src = fetch("src/js/shield_defs.js").decode()

    def block_at(i):
        depth = 0
        for j in range(i, len(src)):
            depth += (src[j] == "{") - (src[j] == "}")
            if depth == 0:
                return src[i:j + 1]
        return None

    def fields(body):
        out = {}
        blanks = re.search(r'spriteBlank:\s*(\[[^\]]*\]|"[^"]*")', body)
        if blanks:
            out["blanks"] = re.findall(r'"([^"]+)"', blanks.group(1))
        color = re.search(r'textColor:\s*Color\.shields\.(\w+)', body)
        if color:
            out["color"] = COLORS.get(color.group(1), "#1d1d1d")
        pm = re.search(r'padding:\s*\{([^}]*)\}', body)
        if pm:
            pad = {}
            for side in ("left", "right", "top", "bottom"):
                v = re.search(rf'{side}:\s*([\d.]+)', pm.group(1))
                pad[side] = float(v.group(1)) if v else 0.0
            out["pad"] = pad
        out["spreads"] = re.findall(r'\.\.\.(\w+)\b', body)
        return out

    consts = {}
    for m in re.finditer(r'(?:const|let|var)\s+(\w+)\s*=\s*\{', src):
        body = block_at(m.end() - 1)
        if body:
            consts[m.group(1)] = fields(body)

    def resolve(f, seen=()):
        out = {}
        for name in f.get("spreads", []):
            if name in consts and name not in seen:
                out.update(resolve(consts[name], seen + (name,)))
        for k in ("blanks", "color", "pad"):
            if k in f:
                out[k] = f[k]
        return out

    defs = {}
    for m in re.finditer(r'shields\[\"([^\"]+)\"\]\s*=\s*\{', src):
        body = block_at(m.end() - 1)
        if not body:
            continue
        r = resolve(fields(body))
        if "blanks" in r:
            defs[m.group(1)] = {"blanks": r["blanks"],
                                "color": r.get("color", "#1d1d1d"),
                                "pad": r.get("pad", {"left": 2, "right": 2, "top": 2, "bottom": 2})}

    for m in re.finditer(r'shields\[\"([^\"]+)\"\]\s*=\s*shields\[\"([^\"]+)\"\]\s*;', src):
        if m.group(2) in defs and m.group(1) not in defs:
            defs[m.group(1)] = defs[m.group(2)]
    return defs

def render(svg_name, scale):
    svg = fetch("icons/" + svg_name + ".svg")
    p = subprocess.run(["rsvg-convert", "-h", str(BASE_H * scale), "-f", "png"],
                       input=svg, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(f"rsvg-convert failed on {svg_name}: {p.stderr.decode()[:200]}")
    return Image.open(io.BytesIO(p.stdout)).convert("RGBA")

def rasterize(name, svg_text, scale):
    """An SVG drawn at its own size, times the scale."""
    p = subprocess.run(["rsvg-convert", "-z", str(scale), "-f", "png"],
                       input=svg_text.encode(), capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(f"rsvg-convert failed on {name}: {p.stderr.decode()[:200]}")
    return Image.open(io.BytesIO(p.stdout)).convert("RGBA")

def plate(scale, digits):
    """Generic marker for a network americana has no artwork for. Its own
    fallback is a plain rectangle too, because those states' real markers
    are plain rectangles."""
    h = BASE_H * scale
    w = int(h * (1.15 if digits == 2 else 1.45))
    ss = 8
    img = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = int(min(w, h) * ss * 0.18)
    d.rounded_rectangle([0, int(h*ss*0.06), w*ss-1, int(h*ss*0.94)], radius=r, fill=(40, 40, 40, 255))
    m = int(min(w, h) * ss * 0.10)
    d.rounded_rectangle([m, int(h*ss*0.06)+m, w*ss-1-m, int(h*ss*0.94)-m],
                        radius=max(1, r-m), fill=(255, 255, 255, 255))
    return img.resize((w, h), Image.LANCZOS)

def centre_text_box(img, pad, scale):
    """Pads the canvas until the padding-defined text box is centred.

    MapLibre centres text on the icon and offers no per-image offset, so the
    offset has to live in the artwork. Transparent margin costs nothing to
    draw and keeps the style free of per-shield cases.
    """
    w, h = img.size
    left, right = pad["left"] * scale, pad["right"] * scale
    top, bottom = pad["top"] * scale, pad["bottom"] * scale
    cx, cy = (left + (w - right)) / 2.0, (top + (h - bottom)) / 2.0

    # Solve for padding that puts the text box at the new image centre.
    # With padding pt/pb the box sits at cy + pt and the centre at
    # (h + pt + pb) / 2, so pt - pb = h - 2*cy. A text box BELOW centre
    # therefore needs padding on the BOTTOM, which pushes the image centre
    # down onto it. Getting this backwards moves the text the wrong way by
    # exactly the amount it should have moved the right way, which on
    # Colorado put the number in the flag band instead of under it.
    pr = int(round(max(0, (cx - w / 2) * 2)))
    pl = int(round(max(0, (w / 2 - cx) * 2)))
    pb = int(round(max(0, (cy - h / 2) * 2)))
    pt = int(round(max(0, (h / 2 - cy) * 2)))
    if pl + pr + pt + pb == 0:
        return img
    out = Image.new("RGBA", (w + pl + pr, h + pt + pb), (0, 0, 0, 0))
    out.alpha_composite(img, (pl, pt))
    return out

def build():
    defs = parse_defs()
    print(f"parsed {len(defs)} shield definitions from americana")

    # our sprite name -> (network key or None)
    targets = {"shield-interstate": "US:I", "shield-us": "US:US"}
    for st in STATES:
        # A few states publish their state network under a qualifier rather
        # than a bare code — Tennessee is `US:TN:primary`. Only `:primary`
        # is accepted: an earlier version took any qualified key and picked
        # up the Maine Turnpike, Merritt Parkway and New Jersey Turnpike
        # logos as those states' route markers.
        key = f"US:{st.upper()}"
        if key not in defs and f"{key}:primary" in defs:
            key = f"{key}:primary"
        targets[f"shield-{st}"] = key
    targets["shield-plate"] = None

    colors, missing = {}, []
    for scale, suffix in ((1, ""), (2, "@2x")):
        images = {}
        for base, net in sorted(targets.items()):
            d = defs.get(net) if net else None
            if d is None:
                if scale == 2 and net:
                    missing.append(base)
                colors[base] = "#1d1d1d"
                for digits in (2, 3):
                    images[f"{base}-{digits}"] = plate(scale, digits)
                continue
            colors[base] = d["color"]
            for digits in (2, 3):
                blanks = d["blanks"]
                name = blanks[min(digits - 2, len(blanks) - 1)]
                try:
                    art = render(name, scale)
                except Exception:
                    if scale == 2:
                        missing.append(base)
                    art = plate(scale, digits)
                    images[f"{base}-{digits}"] = art
                    continue
                images[f"{base}-{digits}"] = centre_text_box(art, d["pad"], scale)

        for name, text in make_symbols.sources().items():
            images[name] = rasterize(name, text, scale)

        pad = 2 * scale
        total_w = sum(im.width + pad for im in images.values()) + pad
        max_h = max(im.height for im in images.values()) + 2 * pad
        sheet = Image.new("RGBA", (total_w, max_h), (0, 0, 0, 0))
        index, x = {}, pad
        for key, im in sorted(images.items()):
            sheet.alpha_composite(im, (x, pad))
            index[key] = {"x": x, "y": pad, "width": im.width, "height": im.height,
                          "pixelRatio": scale}
            x += im.width + pad

        os.makedirs(OUT, exist_ok=True)
        sheet.save(os.path.join(OUT, f"sprite{suffix}.png"))
        with open(os.path.join(OUT, f"sprite{suffix}.json"), "w") as f:
            json.dump(index, f, indent=1, sort_keys=True)
        print(f"sprite{suffix}.png  {sheet.size[0]}x{sheet.size[1]}  {len(index)} icons")

    if missing:
        print(f"{len(set(missing))} using the generic plate: {' '.join(sorted(set(missing)))}")
    write_catalog(colors)
    make_symbols.write_catalog()

def write_catalog(colors):
    states = ", ".join(f'"{s}"' for s in STATES)
    pairs = "\n".join(f'        "{k}": "{v}",' for k, v in sorted(colors.items()))
    with open(CATALOG, "w") as f:
        f.write(f"""// Generated by scripts/make_shields.py — do not edit by hand.
//
// Regenerate after changing shield artwork:
//     python3 scripts/make_shields.py

enum ShieldCatalog {{
    /// State codes with an entry in the sprite sheet. A code outside this
    /// list falls back to the generic plate; the style matches against it
    /// rather than building an image name blind, because MapLibre answers a
    /// missing image by logging every frame rather than failing once.
    static let states: [String] = [{states}]

    /// Numeral colour per shield, taken from openstreetmap-americana's own
    /// definitions. Not derivable from the artwork: Idaho's plate is black,
    /// Minnesota's is blue, California's spade is green, and each needs
    /// white numerals that a light-background shield must not use.
    static let textColors: [String: String] = [
{pairs}
    ]
}}
""")
    print(f"ShieldCatalog.swift  {len(colors)} shields")

if __name__ == "__main__":
    build()
