#!/usr/bin/env python3
"""
Builds the address index from the National Address Database: one SQLite
shard per 1° tile of house numbers with their rooftop points, published
beside the search index and fetched by the app for the tile under the map.

    scripts/build-addresses.py ~/valhalla-data/nad/NAD_TXT.zip out/addresses-us-YYYYMMDD \
        --places out/search-us-YYYYMMDD/places.sqlite

Why the NAD. The US Department of Transportation compiles it from state and
county address programmes, so a point is the parcel or the roof rather than
the Census geocoder's estimate along the block, and it is public domain in
one schema, where OpenAddresses is a thousand sources each under its own
licence. Coverage is by state participation, so the Census geocoder stays
behind it for what it lacks.

Why this shape. A shard holds streets and addresses separately: a street is
one row per name, town and state, with an FTS5 index over its name in the
words the app searches with, and an address is one row per house number on
it, keyed by street and number, so a lookup is a text match on a few
thousand streets and then an exact fetch. Eighty million rows at eight
bytes for a coordinate would be most of the file, so positions are integer
microdegrees. Tiles are Valhalla's level-1 grid, which the app already
knows how to name; a 4° cell like the search index uses would put all of
Los Angeles in one file.

Sources spell a street inconsistently, "N JUNIPER ST" here and "North
Juniper Street" there, so every name is also stored in one spelling, lower
case with abbreviations written out, and that is what the index is built
over. The app writes its query the same way.
"""
import argparse, collections, csv, io, json, math, multiprocessing, os, re, resource, sqlite3, sys, time, zipfile

EXPAND = {
    "n": "north", "s": "south", "e": "east", "w": "west",
    "ne": "northeast", "nw": "northwest", "se": "southeast", "sw": "southwest",
    "st": "street", "ave": "avenue", "av": "avenue", "blvd": "boulevard", "dr": "drive",
    "rd": "road", "ln": "lane", "ct": "court", "pl": "place", "cir": "circle",
    "hwy": "highway", "pkwy": "parkway", "ter": "terrace", "trl": "trail",
}

# What the point marks, best first. The app shows the word so the rider
# knows whether the pin is the roof or the middle of the parcel.
def placement_code(value):
    v = (value or "").lower()
    if "rooftop" in v: return 0
    if "entrance" in v: return 1
    if "parcel" in v: return 2
    if v.startswith("site"): return 3
    if "street" in v: return 4
    return 5

LEVEL_SIZE = 1.0
COLUMNS = int(360 / LEVEL_SIZE)

def tile_of(lat, lon):
    """Valhalla's level-1 tile id: 1° tiles, row-major from the south-west."""
    return int((lat + 90) // LEVEL_SIZE) * COLUMNS + int((lon + 180) // LEVEL_SIZE)

WORD = re.compile(r"[a-z0-9]+")

def search_words(name):
    return " ".join(EXPAND.get(w, w) for w in WORD.findall(name.lower()))

def display(text):
    """Sources shout inconsistently, "3RD Avenue" and "DAVENPORT": a word
    in capitals is brought down, except a compass point."""
    return " ".join(w.capitalize() if w.isupper() and w not in ("NE", "NW", "SE", "SW") else w
                    for w in text.split())

# What a source writes when it has no town. Colorado's whole submission
# says "Unincorporated" for its municipality and nothing for its postal
# city or Census place, and 6.5 million rows nationwide would have had
# that as their town. A row with none gets the nearest town from the
# place index, which is what the street index does too, so an address
# and its street agree on where they are; the county only when there is
# no place index to ask.
NOT_A_TOWN = {"", "not stated", "unknown", "none", "n/a", "null", "county", "other"}

# The same weighting as build-search.py: a town claims a street, or an
# address, from farther away than a hamlet does.
PLACE_REACH = {"city": 4.0, "town": 3.0, "village": 2.0, "hamlet": 1.0}

class PlaceGrid:
    def __init__(self): self.buckets = collections.defaultdict(list)
    def add(self, lat, lon, name, kind):
        self.buckets[(int(lat * 10), int(lon * 10))].append((lat, lon, name, PLACE_REACH.get(kind, 1.0)))
    def nearest(self, lat, lon, radius=3):
        best, bd = None, 1e9
        r, c = int(lat * 10), int(lon * 10)
        k = math.cos(math.radians(lat))
        for dr in range(-radius, radius + 1):
            for dc in range(-radius, radius + 1):
                for plat, plon, name, reach in self.buckets.get((r + dr, c + dc), ()):
                    d = ((plat - lat) ** 2 + ((plon - lon) * k) ** 2) / (reach * reach)
                    if d < bd: best, bd = name, d
        return best

GRID = None

def load_places(path):
    """Once per worker process: the towns of the place index."""
    global GRID
    if not path: return
    GRID = PlaceGrid()
    db = sqlite3.connect(path)
    for name, kind, lat, lon in db.execute("SELECT name, kind, lat, lon FROM feature WHERE kind IN ('city','town','village','hamlet')"):
        GRID.add(lat, lon, name, kind)
    db.close()

def town_of(*candidates):
    for c in candidates:
        c = c.strip()
        if c.lower() in NOT_A_TOWN or c.lower().startswith("unincorp"): continue
        if c.upper().endswith(" CDP"): c = c[:-4]
        return c
    return ""

SCHEMA = """
CREATE TABLE street (id INTEGER PRIMARY KEY, name TEXT NOT NULL, town TEXT NOT NULL, state TEXT NOT NULL,
                     zips TEXT NOT NULL, search TEXT NOT NULL, lat INTEGER NOT NULL, lon INTEGER NOT NULL,
                     count INTEGER NOT NULL);
CREATE VIRTUAL TABLE street_fts USING fts5(search, town, state, zips, content='street', content_rowid='id',
                                           tokenize='unicode61 remove_diacritics 2');
CREATE TABLE address (street INTEGER NOT NULL, number INTEGER NOT NULL, suffix TEXT NOT NULL,
                      lat INTEGER NOT NULL, lon INTEGER NOT NULL, zip INTEGER, placement INTEGER NOT NULL,
                      PRIMARY KEY (street, number, suffix)) WITHOUT ROWID;
"""

def build_tile(args):
    """One shard from its partition file: (tile, partition path, out path)."""
    tile, partition, out = args
    streets, addresses = {}, {}
    with open(partition, encoding="utf-8") as f:
        for line in f:
            name, town, county, state, zipcode, number, suffix, lat, lon, placement = line.rstrip("\n").split("\t")
            if not town:
                town = (GRID.nearest(int(lat) / 1e6, int(lon) / 1e6) if GRID else None) or (county + " County" if county else "")
                if not town: continue
            search = search_words(name)
            key = (search, town.lower(), state)
            street = streets.get(key)
            if street is None:
                street = streets[key] = [len(streets) + 1, display(name), display(town), state, set(), search, 0, 0, 0]
            lat, lon, number, placement = int(lat), int(lon), int(number), int(placement)
            street[6] += lat; street[7] += lon; street[8] += 1
            if zipcode: street[4].add(zipcode)
            akey = (street[0], number, suffix)
            # Every unit of a building is a row; keep one per number, the
            # best-placed of them.
            have = addresses.get(akey)
            if have is None or placement < have[2]:
                addresses[akey] = (lat, lon, placement, int(zipcode) if zipcode.isdigit() else None)
    if os.path.exists(out): os.remove(out)
    db = sqlite3.connect(out)
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO street VALUES (?,?,?,?,?,?,?,?,?)",
                   ((s[0], s[1], s[2], s[3], " ".join(sorted(s[4])), s[5], s[6] // s[8], s[7] // s[8], s[8])
                    for s in streets.values()))
    db.executemany("INSERT INTO address VALUES (?,?,?,?,?,?,?)",
                   ((k[0], k[1], k[2], v[0], v[1], v[3], v[2]) for k, v in sorted(addresses.items())))
    db.execute("INSERT INTO street_fts(street_fts) VALUES ('rebuild')")
    db.commit(); db.execute("VACUUM"); db.close()
    os.remove(partition)
    return tile, os.path.getsize(out), len(addresses), len(streets)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("nad"); ap.add_argument("out_dir")
    ap.add_argument("--places", help="places.sqlite of the search index, for rows whose source names no town")
    ap.add_argument("--jobs", type=int, default=max(1, os.cpu_count() - 2))
    a = ap.parse_args()
    started = time.time()
    def log(msg): print("%6.0fs %s" % (time.time() - started, msg), flush=True)

    # One partition file per tile, open at once: about a thousand tiles
    # have addresses, and the default limit on open files is 256.
    resource.setrlimit(resource.RLIMIT_NOFILE, (10240, 10240))
    partitions_dir = os.path.join(a.out_dir, "partitions")
    os.makedirs(partitions_dir, exist_ok=True)
    os.makedirs(os.path.join(a.out_dir, "tiles"), exist_ok=True)

    if a.nad.endswith(".zip"):
        archive = zipfile.ZipFile(a.nad)
        member = next(n for n in archive.namelist() if n.lower().endswith((".txt", ".csv")))
        log(f"reading {member} from {a.nad}")
        stream = io.TextIOWrapper(archive.open(member), encoding="utf-8", errors="replace", newline="")
    else:
        stream = open(a.nad, encoding="utf-8", errors="replace", newline="")
    reader = csv.reader(stream)
    header = [h.strip().lower() for h in next(reader)]
    col = {name: header.index(name) for name in header}
    def column(*names):
        for n in names:
            if n.lower() in col: return col[n.lower()]
        sys.exit(f"no column among {names}; header is {header}")
    c_state, c_lat, c_lon = column("State"), column("Latitude"), column("Longitude")
    c_number, c_full = column("Add_Number"), column("AddNo_Full")
    c_name, c_post, c_muni, c_place = column("StNam_Full"), column("Post_City"), column("Inc_Muni"), column("Census_Plc")
    c_community, c_county = column("Uninc_Comm"), column("County")
    c_zip, c_placement = column("Zip_Code"), column("Placement")
    parts = [column(n) for n in ("St_PreMod", "St_PreDir", "St_PreTyp", "St_Name", "St_PosTyp", "St_PosDir", "St_PosMod")]

    files = {}
    kept = skipped = 0
    for row in reader:
        try:
            lat, lon = float(row[c_lat]), float(row[c_lon])
            number = int(float(row[c_number]))
        except (ValueError, IndexError):
            skipped += 1; continue
        name = row[c_name].strip() or " ".join(row[i].strip() for i in parts if row[i].strip())
        town = town_of(row[c_post], row[c_muni], row[c_place], row[c_community])
        county = row[c_county].strip()
        state = row[c_state].strip().upper()
        if not name or len(state) != 2 or not (-90 < lat < 90) or not (-180 < lon < 180):
            skipped += 1; continue
        full = row[c_full].strip()
        suffix = full[len(str(number)):].strip() if full.startswith(str(number)) else ""
        zipcode = row[c_zip].strip()[:5]
        tile = tile_of(lat, lon)
        f = files.get(tile)
        if f is None:
            f = files[tile] = open(os.path.join(partitions_dir, f"{tile}.tsv"), "w", encoding="utf-8")
        f.write("\t".join((name.replace("\t", " "), town.replace("\t", " "), county.replace("\t", " "), state, zipcode, str(number), suffix,
                           str(int(round(lat * 1e6))), str(int(round(lon * 1e6))), str(placement_code(row[c_placement])))) + "\n")
        kept += 1
        if kept % 5000000 == 0: log(f"  {kept} addresses into {len(files)} tiles")
    for f in files.values(): f.close()
    log(f"{kept} addresses kept, {skipped} skipped, {len(files)} tiles")

    jobs = [(tile, os.path.join(partitions_dir, f"{tile}.tsv"), os.path.join(a.out_dir, "tiles", f"{tile}.sqlite"))
            for tile in sorted(files)]
    index = {"version": 1, "archive": os.path.basename(a.out_dir.rstrip("/")), "level": 1, "tiles": {}}
    with multiprocessing.Pool(a.jobs, initializer=load_places, initargs=(a.places,)) as pool:
        for n, (tile, size, count, streets) in enumerate(pool.imap_unordered(build_tile, jobs), 1):
            index["tiles"][str(tile)] = {"bytes": size, "count": count, "streets": streets}
            if n % 100 == 0: log(f"  {n} tiles written")
    os.rmdir(partitions_dir)
    total = sum(t["bytes"] for t in index["tiles"].values())
    largest = max(index["tiles"].items(), key=lambda t: t[1]["bytes"])
    log(f"{len(index['tiles'])} tiles, {total // 1000000} MB, largest {largest[0]} at {largest[1]['bytes'] // 1000000} MB "
        f"with {largest[1]['count']} addresses")
    json.dump(index, open(os.path.join(a.out_dir, "index.json"), "w"), separators=(",", ":"))
    log("done")

if __name__ == "__main__":
    main()
