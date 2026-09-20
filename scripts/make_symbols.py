#!/usr/bin/env python3
"""Draws the waypoint symbols for the sprite sheet, and writes their catalog.

Not a script of its own: `make_shields.py` imports this and packs what it
returns into the same sheet as the highway shields, so one command builds
the one sprite file the style names. Run that.

A waypoint's appearance on a Garmin is its *symbol*, `<sym>` in GPX, and
the names are Garmin's: `Flag, Blue`, `Gas Station`, `Summit`. The set here
is the slice of Garmin's list a touring rider reaches for, in the order the
menu offers them. Anything outside it still round-trips through the library
untouched; it is drawn with the generic marker until artwork exists.

Two kinds of artwork:

  shapes      Garmin's flags, pins, blocks, diamonds and the circle-with-X,
              drawn here, in the three colours Garmin gives them. The hexes
              are `ItemColor`'s: one palette, and it is Garmin's.
  pictograms  a white glyph on a coloured pin. The glyphs are Maki
              (Mapbox, CC0): https://github.com/mapbox/maki

Every image is anchored either at its bottom-centre (a pin's tip, a flag's
foot) or at its centre (a block sits on the place). The catalog carries
which, and the style reads it off the feature, because MapLibre has no
per-image anchor.
"""
import os, re, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "..", "Swiftcamp", "Map", "SymbolCatalog.swift")
CACHE = os.path.join(HERE, ".symbol-cache")
MAKI = "https://raw.githubusercontent.com/mapbox/maki/main/icons/"

# ItemColor's hexes, by Garmin's names.
BLUE, GREEN, RED = "#0a58ff", "#00a000", "#e02020"
MAGENTA = "#8b008b"
ORANGE = "#f5a623"          # what a waypoint has always been drawn in
SEARCH = "#d62828"          # the search pin's red
INK = "#1d1d1d"

# (Garmin name, kind, colour, Maki glyph or None). Order is menu order;
# a group change becomes a separator in the menu.
SYMBOLS = [
    ("Markers", [
        ("Waypoint",       "drop",    ORANGE, None),
        ("Flag, Blue",     "flag",    BLUE,   None),
        ("Flag, Green",    "flag",    GREEN,  None),
        ("Flag, Red",      "flag",    RED,    None),
        ("Pin, Blue",      "pin",     BLUE,   None),
        ("Pin, Green",     "pin",     GREEN,  None),
        ("Pin, Red",       "pin",     RED,    None),
        ("Block, Blue",    "block",   BLUE,   None),
        ("Block, Green",   "block",   GREEN,  None),
        ("Block, Red",     "block",   RED,    None),
        ("Diamond, Blue",  "diamond", BLUE,   None),
        ("Diamond, Green", "diamond", GREEN,  None),
        ("Diamond, Red",   "diamond", RED,    None),
        ("Circle with X",  "circlex", INK,    None),
    ]),
    ("Services", [
        ("Gas Station",      "drop", BLUE, "fuel"),
        ("Lodging",          "drop", BLUE, "lodging"),
        ("Restaurant",       "drop", BLUE, "restaurant"),
        ("Bar",              "drop", BLUE, "bar"),
        ("Shopping Center",  "drop", BLUE, "shop"),
        ("Parking Area",     "drop", BLUE, "parking"),
        ("Restroom",         "drop", BLUE, "toilet"),
        ("Information",      "drop", BLUE, "information"),
        ("Post Office",      "drop", BLUE, "post"),
        ("Medical Facility", "drop", RED,  "hospital"),
        ("Police Station",   "drop", BLUE, "police"),
        ("Residence",        "drop", BLUE, "home"),
        ("Museum",           "drop", BLUE, "museum"),
        ("Airport",          "drop", MAGENTA, "airport"),
        ("Ferry",            "drop", MAGENTA, "ferry"),
    ]),
    ("Outdoors", [
        ("Campground",    "drop", GREEN, "campsite"),
        ("Picnic Area",   "drop", GREEN, "picnic-site"),
        ("Park",          "drop", GREEN, "park"),
        ("Scenic Area",   "drop", GREEN, "viewpoint"),
        ("Summit",        "drop", GREEN, "mountain"),
        ("Swimming Area", "drop", GREEN, "swimming"),
        ("Bike Trail",    "drop", GREEN, "bicycle"),
        ("Danger Area",   "drop", RED,   "danger"),
    ]),
]

# Where a search landed: the same drop, red, and a size up, so it reads
# as the thing being looked at rather than one waypoint among many.
SEARCH_IMAGE = "symbol-search"

def slug(name):
    return "symbol-" + re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

def anchor(kind):
    return "center" if kind in ("block", "diamond", "circlex") else "bottom"

def fetch_glyph(name):
    os.makedirs(CACHE, exist_ok=True)
    key = os.path.join(CACHE, name + ".svg")
    if os.path.exists(key):
        return open(key).read()
    with urllib.request.urlopen(MAKI + name + ".svg") as r:
        data = r.read().decode()
    open(key, "w").write(data)
    return data

def glyph_body(name):
    """The drawing inside a Maki SVG, which is a 15x15 viewBox."""
    svg = fetch_glyph(name)
    m = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S)
    return m.group(1)

# MARK: - Artwork, in CSS pixels; rsvg scales it.

def svg(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}">{body}</svg>')

def drop(w, h, color, glyph=None, dot=True):
    """A map pin: a round head drawn out to a point at the bottom-centre."""
    r = (w - 2) / 2.0
    cx, cy = w / 2.0, r + 1
    ax, ay = 0.72 * r, 0.694 * r
    path = (f"M{cx},{h - 1} L{cx - ax:.2f},{cy + ay:.2f} "
            f"A{r},{r} 0 1 1 {cx + ax:.2f},{cy + ay:.2f} Z")
    body = f'<path d="{path}" fill="{color}" stroke="{INK}" stroke-width="1" stroke-linejoin="round"/>'
    if glyph:
        # Maki glyphs are 15 units square; drawn at 60% of the head.
        s = (2 * r * 0.6) / 15.0
        body += (f'<g fill="#ffffff" transform="translate({cx - 7.5 * s:.2f},{cy - 7.5 * s:.2f}) scale({s:.3f})">'
                 f'{glyph_body(glyph)}</g>')
    elif dot:
        body += f'<circle cx="{cx}" cy="{cy}" r="{r * 0.36:.2f}" fill="#ffffff"/>'
    return svg(w, h, body)

def flag(color):
    # The pole stands at the centre so the image's bottom-centre is its
    # foot; the empty left half is the price of a shared anchor.
    w, h = 22, 24
    x = w / 2.0
    cloth = f"M{x + 0.5},2 L{w - 1},2 L{w - 3},6.5 L{w - 1},11 L{x + 0.5},11 Z"
    body = (f'<path d="{cloth}" fill="{color}" stroke="{INK}" stroke-width="1" stroke-linejoin="round"/>'
            f'<line x1="{x}" y1="1" x2="{x}" y2="{h}" stroke="{INK}" stroke-width="1.6"/>')
    return svg(w, h, body)

def pin(color):
    """A pushpin: a round head on a needle whose point is the place."""
    w, h = 18, 26
    x, r = w / 2.0, 7
    body = (f'<line x1="{x}" y1="{h}" x2="{x}" y2="{2 * r - 1}" stroke="{INK}" stroke-width="2.4"/>'
            f'<line x1="{x}" y1="{h}" x2="{x}" y2="{2 * r - 1}" stroke="#c8c8c8" stroke-width="1.2"/>'
            f'<circle cx="{x}" cy="{r + 1}" r="{r}" fill="{color}" stroke="{INK}" stroke-width="1"/>'
            f'<circle cx="{x - 2.2}" cy="{r - 1.2}" r="1.8" fill="#ffffff" fill-opacity="0.75"/>')
    return svg(w, h, body)

def block(color):
    s = 14
    return svg(s, s, f'<rect x="1" y="1" width="{s - 2}" height="{s - 2}" fill="{color}" '
                     f'stroke="{INK}" stroke-width="1"/>')

def diamond(color):
    s = 16
    c = s / 2.0
    return svg(s, s, f'<path d="M{c},1 L{s - 1},{c} L{c},{s - 1} L1,{c} Z" fill="{color}" '
                     f'stroke="{INK}" stroke-width="1" stroke-linejoin="round"/>')

def circlex():
    s = 16
    c = s / 2.0
    return svg(s, s, f'<circle cx="{c}" cy="{c}" r="{c - 1}" fill="#ffffff" stroke="{INK}" stroke-width="1.2"/>'
                     f'<path d="M5,5 L11,11 M11,5 L5,11" stroke="{INK}" stroke-width="1.6" stroke-linecap="round"/>')

def artwork(kind, color, glyph):
    if kind == "drop":
        return drop(22, 30, color, glyph)
    if kind == "flag":
        return flag(color)
    if kind == "pin":
        return pin(color)
    if kind == "block":
        return block(color)
    if kind == "diamond":
        return diamond(color)
    if kind == "circlex":
        return circlex()
    raise ValueError(kind)

# MARK: - What make_shields.py calls

def sources():
    """Sprite image name -> SVG text, for every symbol and the search pin."""
    out = {}
    for _, entries in SYMBOLS:
        for name, kind, color, glyph in entries:
            out[slug(name)] = artwork(kind, color, glyph)
    out[SEARCH_IMAGE] = drop(26, 36, SEARCH)
    return out

def write_catalog():
    lines = []
    for group, entries in SYMBOLS:
        for name, kind, _, _ in entries:
            lines.append(f'        Entry(name: "{name}", image: "{slug(name)}", '
                         f'anchor: "{anchor(kind)}", group: "{group}"),')
    entries = "\n".join(lines)
    groups = ", ".join(f'"{g}"' for g, _ in SYMBOLS)
    with open(CATALOG, "w") as f:
        f.write(f"""// Generated by scripts/make_shields.py from scripts/make_symbols.py.
// Do not edit by hand.

/// The waypoint symbols the app can draw, by Garmin's names.
///
/// Generated beside the sprite sheet so an image name here cannot name an
/// image that is not there: MapLibre answers a missing image by logging
/// every frame rather than failing once. A symbol outside this list is kept
/// on the waypoint and exported untouched; it draws as the generic marker.
enum SymbolCatalog {{
    struct Entry: Hashable, Sendable {{
        /// Garmin's name, as `<sym>` carries it.
        let name: String
        /// The sprite image.
        let image: String
        /// Where the image sits on the place: `bottom` for a pin's tip or a
        /// flag's foot, `center` for a shape that sits on the spot.
        let anchor: String
        /// The menu section.
        let group: String
    }}

    /// In menu order.
    static let entries: [Entry] = [
{entries}
    ]

    /// The menu sections, in order.
    static let groups: [String] = [{groups}]

    /// What draws when a waypoint has no symbol, or one without artwork.
    static let fallback = entries[0]

    /// Where a search result is drawn until it is saved or dismissed.
    static let search = Entry(name: "", image: "{SEARCH_IMAGE}", anchor: "bottom", group: "")

    /// The entry for a stored symbol name, or nil for none or one without
    /// artwork. Case-insensitive because the names travel through files
    /// other software wrote.
    static func known(_ symbol: String?) -> Entry? {{
        symbol.flatMap {{ byName[$0.lowercased()] }}
    }}

    /// The entry to draw a stored symbol name with: its own, or the fallback.
    static func entry(for symbol: String?) -> Entry {{
        known(symbol) ?? fallback
    }}

    private static let byName: [String: Entry] =
        Dictionary(uniqueKeysWithValues: entries.map {{ ($0.name.lowercased(), $0) }})
}}
""")
    print(f"SymbolCatalog.swift  {len(lines)} symbols")
