#!/usr/bin/env python3
"""
Builds the search index from an OSM extract: a national database of places
and one shard per 4° cell of streets and points of interest, each a SQLite
file with an FTS5 index, published beside the map and fetched by the app as
the map moves.

    osmium tags-filter us-latest.osm.pbf n/place=city,town,village,hamlet,suburb,locality,neighbourhood \
        nwr/amenity=fuel,restaurant,cafe,fast_food,bar,pub,hospital,pharmacy,charging_station \
        nwr/tourism=hotel,motel,camp_site,caravan_site,guest_house,hostel,viewpoint,attraction,information \
        nwr/shop=motorcycle,motorcycle_repair,supermarket,convenience n/natural=peak nwr/mountain_pass=yes \
        -o search/pois.osm.pbf
    osmium export search/pois.osm.pbf -f geojsonseq --geometry-types=point,linestring,polygon -o search/pois.geojsonseq
    osmium tags-filter us-latest.osm.pbf w/highway=motorway,trunk,primary,secondary,tertiary,unclassified,residential,living_street \
        -o search/streets.osm.pbf
    osmium export search/streets.osm.pbf -f geojsonseq --geometry-types=linestring -o search/streets.geojsonseq
    scripts/build-search.py search out/search-us-YYYYMMDD --admins admins.sqlite

Why these shapes. A place is what people type first and there are few
enough for the whole country to be one small file, always on hand. Streets
and points of interest are millions, so they live in the cell under the map
and arrive when the map does; the cells are Valhalla's level-0 grid so the
app already knows how to name them. A street is one row per name and
county, at the centroid of its ways, not one row per way: "Main Street"
occurs in every town and the town is what tells them apart. The state on a
place comes from the admin polygons of the routing build, which is the one
lookup slow enough to do only for places; everything else takes its state
from TIGER's county tag or from the nearest place.

Requires: python3 with sqlite3 able to load mod_spatialite (Homebrew's can).
"""
import argparse, collections, json, math, os, sqlite3, sys, time

PLACE_KINDS = ("city", "town", "village", "hamlet", "suburb", "locality", "neighbourhood")
NEAREST_KINDS = ("city", "town", "village", "hamlet")
KIND_LABEL = {
    "city": "City", "town": "Town", "village": "Village", "hamlet": "Hamlet", "suburb": "Suburb",
    "locality": "Locality", "neighbourhood": "Neighbourhood",
    "fuel": "Fuel", "restaurant": "Restaurant", "cafe": "Café", "fast_food": "Fast food", "bar": "Bar",
    "pub": "Pub", "hospital": "Hospital", "pharmacy": "Pharmacy", "charging_station": "Charging",
    "hotel": "Hotel", "motel": "Motel", "camp_site": "Campground", "caravan_site": "RV park",
    "guest_house": "Guest house", "hostel": "Hostel", "viewpoint": "Viewpoint", "attraction": "Attraction",
    "information": "Visitor information", "motorcycle": "Motorcycle dealer",
    "motorcycle_repair": "Motorcycle repair", "supermarket": "Supermarket", "convenience": "Convenience store",
    "peak": "Peak", "pass": "Pass",
}
STATES = {"AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA","KS","KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ","NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN","TX","UT","VT","VA","WA","WV","WI","WY","DC","PR","VI","GU","AS","MP"}
STATE_NAMES = {"alabama":"AL","alaska":"AK","arizona":"AZ","arkansas":"AR","california":"CA","colorado":"CO","connecticut":"CT","delaware":"DE","florida":"FL","georgia":"GA","hawaii":"HI","idaho":"ID","illinois":"IL","indiana":"IN","iowa":"IA","kansas":"KS","kentucky":"KY","louisiana":"LA","maine":"ME","maryland":"MD","massachusetts":"MA","michigan":"MI","minnesota":"MN","mississippi":"MS","missouri":"MO","montana":"MT","nebraska":"NE","nevada":"NV","new hampshire":"NH","new jersey":"NJ","new mexico":"NM","new york":"NY","north carolina":"NC","north dakota":"ND","ohio":"OH","oklahoma":"OK","oregon":"OR","pennsylvania":"PA","rhode island":"RI","south carolina":"SC","south dakota":"SD","tennessee":"TN","texas":"TX","utah":"UT","vermont":"VT","virginia":"VA","washington":"WA","west virginia":"WV","wisconsin":"WI","wyoming":"WY","district of columbia":"DC","puerto rico":"PR"}

def cell_of(lat, lon):
    """Valhalla's level-0 tile id: 4° cells, row-major from the south-west."""
    return int((lat + 90) // 4) * 90 + int((lon + 180) // 4)

def centroid(geometry):
    t, c = geometry["type"], geometry["coordinates"]
    if t == "Point": return c[1], c[0]
    if t == "LineString": pts = c
    elif t == "Polygon": pts = c[0]
    elif t == "MultiPolygon": pts = c[0][0]
    else: return None
    if not pts: return None
    return sum(p[1] for p in pts) / len(pts), sum(p[0] for p in pts) / len(pts)

def kind_of(p):
    if p.get("place") in PLACE_KINDS: return p["place"]
    for key in ("amenity", "tourism", "shop"):
        if p.get(key) in KIND_LABEL: return p[key]
    if p.get("natural") == "peak": return "peak"
    if p.get("mountain_pass") == "yes": return "pass"
    return None

def state_code(value):
    if not value: return None
    v = value.strip()
    if v.upper() in STATES: return v.upper()
    return STATE_NAMES.get(v.lower())

def records(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                yield json.loads(line.lstrip("\x1e"))
            except json.JSONDecodeError:
                continue

# A town claims a street from farther away than a hamlet does: Estes
# Park's main street belongs to Estes Park, not to the hamlet a mile
# nearer its centroid. Distance is divided by this before comparing.
PLACE_REACH = {"city": 4.0, "town": 3.0, "village": 2.0, "hamlet": 1.0}

class PlaceGrid:
    """Nearest named place to a point, by 0.1° buckets, towns preferred."""
    def __init__(self): self.buckets = collections.defaultdict(list)
    def add(self, lat, lon, name, state, kind):
        self.buckets[(int(lat * 10), int(lon * 10))].append((lat, lon, name, state, PLACE_REACH.get(kind, 1.0)))
    def nearest(self, lat, lon, radius=3):
        best, bd = None, 1e9
        r, c = int(lat * 10), int(lon * 10)
        k = math.cos(math.radians(lat))
        for dr in range(-radius, radius + 1):
            for dc in range(-radius, radius + 1):
                for plat, plon, name, state, reach in self.buckets.get((r + dr, c + dc), ()):
                    d = ((plat - lat) ** 2 + ((plon - lon) * k) ** 2) / (reach * reach)
                    if d < bd: best, bd = (name, state), d
        return best

SCHEMA = """
CREATE TABLE feature (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, detail TEXT NOT NULL,
                      lat REAL NOT NULL, lon REAL NOT NULL, rank INTEGER NOT NULL DEFAULT 0);
CREATE VIRTUAL TABLE feature_fts USING fts5(name, detail, content='feature', content_rowid='id',
                                            tokenize='unicode61 remove_diacritics 2');
"""

def write_db(path, rows):
    if os.path.exists(path): os.remove(path)
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO feature(kind, name, detail, lat, lon, rank) VALUES (?,?,?,?,?,?)", rows)
    db.execute("INSERT INTO feature_fts(feature_fts) VALUES ('rebuild')")
    db.execute("CREATE INDEX feature_rank ON feature(rank DESC)")
    db.commit(); db.execute("VACUUM"); db.close()
    return os.path.getsize(path)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("extract_dir"); ap.add_argument("out_dir"); ap.add_argument("--admins", required=True)
    a = ap.parse_args()
    started = time.time()
    def log(msg): print("%6.0fs %s" % (time.time() - started, msg), flush=True)

    admins = sqlite3.connect(a.admins)
    admins.enable_load_extension(True); admins.load_extension("/opt/homebrew/lib/mod_spatialite.dylib")
    def state_at(lat, lon):
        row = admins.execute("""SELECT iso_code FROM admins WHERE admin_level=4 AND rowid IN
            (SELECT rowid FROM SpatialIndex WHERE f_table_name='admins' AND search_frame=MakePoint(?, ?, 4326))
            AND ST_Contains(geom, MakePoint(?, ?, 4326)) LIMIT 1""", (lon, lat, lon, lat)).fetchone()
        return row[0] if row and row[0] in STATES else None

    # Pass 1: places and points of interest.
    places, pois, grid = [], [], PlaceGrid()
    for feat in records(os.path.join(a.extract_dir, "pois.geojsonseq")):
        p = feat["properties"]; name = p.get("name")
        kind = kind_of(p)
        if not name or not kind: continue
        ll = centroid(feat["geometry"])
        if not ll: continue
        lat, lon = ll
        if kind in PLACE_KINDS:
            try: population = int(float(p.get("population", "0") or 0))
            except ValueError: population = 0
            places.append([name, kind, lat, lon, population, state_code(p.get("addr:state")) or state_code(p.get("is_in:state"))])
        else:
            pois.append((name, kind, lat, lon, p.get("addr:city"), state_code(p.get("addr:state")), p.get("ele")))
    log(f"read {len(places)} places and {len(pois)} points of interest")

    for place in places:
        if place[5] is None: place[5] = state_at(place[2], place[3])
    log("states assigned to places")
    for name, kind, lat, lon, population, state in places:
        if kind in NEAREST_KINDS and state: grid.add(lat, lon, name, state, kind)

    # A place's rank is its population, and most have none tagged, so a
    # kind stands in: a city outranks a town outranks a hamlet, which is
    # what "Estes" should find before five hamlets of that name.
    default_population = {"city": 50000, "town": 5000, "suburb": 2000, "village": 1000,
                          "neighbourhood": 500, "hamlet": 100, "locality": 50}
    place_rows = []
    for name, kind, lat, lon, population, state in places:
        if not state: continue
        near = grid.nearest(lat, lon) if kind not in NEAREST_KINDS else None
        detail = KIND_LABEL[kind] + ", " + state if not near else f"{KIND_LABEL[kind]} in {near[0]}, {state}"
        place_rows.append((kind, name, detail, lat, lon, population or default_population[kind]))
    # One row per place of business: OSM often has both a node and the
    # building for the same shop, and a shop that sells fuel is tagged as
    # both a shop and a station. The same name within about a hundred
    # metres is the same place.
    poi_rows = collections.defaultdict(list)
    seen_pois = set()
    for name, kind, lat, lon, city, state, ele in pois:
        signature = (name.lower(), round(lat, 3), round(lon, 3))
        if signature in seen_pois: continue
        seen_pois.add(signature)
        near = grid.nearest(lat, lon)
        town = city or (near[0] if near else None)
        st = state or (near[1] if near else None)
        if not town or not st: continue
        label = KIND_LABEL[kind]
        if kind in ("peak", "pass") and ele:
            try: label += " · %s ft" % format(int(float(ele) * 3.28084), ",")
            except ValueError: pass
        poi_rows[cell_of(lat, lon)].append((kind, name, f"{label} · {town}, {st}", lat, lon, 0))
    log(f"{len(place_rows)} places kept, {sum(len(v) for v in poi_rows.values())} points of interest in {len(poi_rows)} cells")

    # Pass 2: streets, one row per name and nearest town. The town is
    # found per way, not per merged row: keyed by county, every Main
    # Street in a county became one row at the average of two towns, and
    # ways with no county tag, a third of them, merged across the whole
    # country and landed somewhere in between. TIGER's county tag now
    # only says which state a way is in when the nearest town disagrees.
    streets = {}
    n = 0
    for feat in records(os.path.join(a.extract_dir, "streets.geojsonseq")):
        p = feat["properties"]; name = p.get("name")
        if not name: continue
        ll = centroid(feat["geometry"])
        if not ll: continue
        lat, lon = ll
        state = None
        tc = p.get("tiger:county")
        if tc and "," in tc:
            state = state_code(tc.rsplit(",", 1)[1])
        near = grid.nearest(lat, lon)
        if not near: continue
        town, st = near[0], state or near[1]
        key = (name.lower(), st, town)
        acc = streets.get(key)
        if acc: acc[1] += lat; acc[2] += lon; acc[3] += 1
        else: streets[key] = [name, lat, lon, 1]
        n += 1
        if n % 2000000 == 0: log(f"  {n} street ways")
    log(f"{n} named street ways into {len(streets)} streets")
    street_rows = collections.defaultdict(list)
    for (lname, st, town), (name, slat, slon, count) in streets.items():
        lat, lon = slat / count, slon / count
        street_rows[cell_of(lat, lon)].append(("street", name, f"Street · {town}, {st}", lat, lon, count))
    log(f"streets placed in {len(street_rows)} cells")

    # Write.
    os.makedirs(os.path.join(a.out_dir, "cells"), exist_ok=True)
    index = {"version": 1, "archive": os.path.basename(a.out_dir.rstrip("/")), "cells": {}}
    size = write_db(os.path.join(a.out_dir, "places.sqlite"), place_rows)
    index["places"] = {"bytes": size, "count": len(place_rows)}
    log(f"places.sqlite {size // 1000000} MB")
    for cell in sorted(set(poi_rows) | set(street_rows)):
        rows = poi_rows.get(cell, []) + street_rows.get(cell, [])
        size = write_db(os.path.join(a.out_dir, "cells", f"{cell}.sqlite"), rows)
        index["cells"][str(cell)] = {"bytes": size, "count": len(rows)}
    total = sum(c["bytes"] for c in index["cells"].values())
    log(f"{len(index['cells'])} cells, {total // 1000000} MB, largest {max(c['bytes'] for c in index['cells'].values()) // 1000000} MB")
    json.dump(index, open(os.path.join(a.out_dir, "index.json"), "w"), separators=(",", ":"))
    log("done")

if __name__ == "__main__":
    main()
