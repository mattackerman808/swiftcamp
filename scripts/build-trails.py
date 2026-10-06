#!/usr/bin/env python3
"""
Builds the dirt bike trails overlay: one PMTiles archive of the roads and
trails a motorcycle may legally ride, from the Forest Service's Motor
Vehicle Use Maps and from OpenStreetMap, published beside the street map
and drawn over it.

    scripts/build-trails.py ~/valhalla-data/us-latest.osm.pbf out/ --name us

Output is out/trails-<name>-<date>.pmtiles, dated for the same reason as
every archive on the CDN: a client mid-read must never have the file
change under it.

Why two sources. The MVUM is the legal record for every national forest:
under 36 CFR 212 a road or trail there is open to a motor vehicle only if
the map says so, with the vehicle classes and the dates. It is public
domain and national, and it says nothing about BLM, state or private land,
which is where much Western riding is. OpenStreetMap covers that, but only
where a mapper wrote the access down, so it is taken only where it says
yes. The two are drawn as separate layers, not conflated: where both have
a trail the MVUM line is the one that carries the law.

Why only positive evidence. A trail drawn as open that is closed is a
ticket, or a closure for everyone if riders keep using it. So nothing is
inferred from a tag's absence: a path with no motorcycle tag is not here
at all, and an MVUM "special designation" with no motorcycle entry is
marked unknown rather than open.

The Forest Service serves the MVUM from an ArcGIS map service with a page
limit of 2,000 features; the pages are cached under out/mvum-cache, so a
rerun after a tiling change asks for nothing. Delete the cache to refresh.
A box query returns fewer trails than the service's count, 34,183 of
62,778 on 2026-10-05, and that is not loss: the other 28,595 rows have no
line and no length, and the box query carries every one of the 43,958
trail miles.

Requires: osmium-tool, tippecanoe (both Homebrew), python3.
"""
import argparse, collections, datetime, json, math, os, subprocess, sys, time, urllib.parse, urllib.request

MVUM = "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_MVUM_01/MapServer"
MVUM_ROADS, MVUM_TRAILS = 1, 2
# The layers' schemas differ, and asking a layer for a field it lacks is a
# bare "Failed to execute query" with no detail.
MVUM_COMMON = ("objectid", "id", "name", "symbol", "seasonal", "motorcycle", "motorcycle_datesopen", "forestname")
MVUM_FIELDS = {1: MVUM_COMMON + ("surfacetype",), 2: MVUM_COMMON + ("trailclass",)}
USER_AGENT = "Swiftcamp trails build (https://github.com/mattackerman808/swiftcamp)"

# The MVUM's own legend, by symbol. Every symbol means one rule for a
# motorcycle, except special designations, whose rule is in the per-vehicle
# column and is often missing there (2,200 of 5,000 trail segments
# nationally on 2026-10-05). Measured by grouping the whole service on
# symbol and motorcycle before this table was written.
#
#   legal: who may ride it. "any" is any motorcycle, plated or not;
#   "street" is highway-legal only, so a plated dual-sport and not an
#   unplated dirt bike.
MVUM_SYMBOLS = {
    # Roads layer
    "1":  ("road",  "any"),     # Roads open to all vehicles, yearlong
    "2":  ("road",  "any"),     # Roads open to all vehicles, seasonal
    "3":  ("road",  "street"),  # Roads open to highway legal vehicles only, yearlong
    "4":  ("road",  "street"),  # ... seasonal
    # Trails layer
    "5":  ("trail", "any"),     # Trails open to all vehicles
    "6":  ("trail", "any"),
    "7":  ("trail", "any"),     # Trails open to vehicles 50" or less in width
    "8":  ("trail", "any"),
    "9":  ("single", "any"),    # Trails open to motorcycles only
    "10": ("single", "any"),
    "16": ("trail", "any"),     # Wheeled OHV <50"
    "17": ("trail", "any"),
}
SPECIAL = {"11", "12"}           # Special designation: read the motorcycle column

# OpenStreetMap access values that mean a motorcycle may ride here.
# `permit` is left out: Swiftcamp's router treats it as closed (see
# docs/routing.md), and the map should not promise more than the router.
OSM_YES = {"yes", "designated", "permissive", "official"}
OSM_HIGHWAYS = ("path", "track", "bridleway", "unclassified")


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


# MARK: Forest Service

def mvum_pages(layer, bbox, cache):
    """Every feature of an MVUM layer inside bbox, paged and cached."""
    # Keyed by the box as well as the page: a page is an offset into the
    # answer for one box, and the same offset for another box is a
    # different page.
    cache = os.path.join(cache, "bbox_" + "_".join(f"{v:.4f}" for v in bbox))
    os.makedirs(cache, exist_ok=True)
    offset, page = 0, 2000
    while True:
        path = os.path.join(cache, f"layer{layer}-{offset:07d}.geojson")
        if not os.path.exists(path):
            q = urllib.parse.urlencode({
                "where": "1=1", "outFields": ",".join(MVUM_FIELDS[layer]), "f": "geojson", "outSR": 4326,
                "geometry": ",".join(map(str, bbox)), "geometryType": "esriGeometryEnvelope",
                "inSR": 4326, "spatialRel": "esriSpatialRelIntersects",
                "orderByFields": "objectid", "resultOffset": offset, "resultRecordCount": page,
            })
            req = urllib.request.Request(f"{MVUM}/{layer}/query?{q}", headers={"User-Agent": USER_AGENT})
            for attempt in range(4):
                try:
                    with urllib.request.urlopen(req, timeout=180) as r:
                        body = r.read()
                    doc = json.loads(body)
                    if "error" in doc: raise RuntimeError(doc["error"])
                    break
                except Exception as e:
                    if attempt == 3: raise
                    log(f"MVUM layer {layer} offset {offset}: {e}; retrying")
                    time.sleep(5 * (attempt + 1))
            with open(path + ".part", "wb") as f: f.write(body)
            os.replace(path + ".part", path)
        doc = json.load(open(path))
        feats = doc.get("features", [])
        yield from feats
        # ArcGIS says whether there is more; a short page alone is not proof,
        # since the server may cap a page below what was asked for.
        if not feats or not (doc.get("exceededTransferLimit") or doc.get("properties", {}).get("exceededTransferLimit")):
            return
        offset += len(feats)


def clean(v):
    """MVUM text columns hold None, "" and " " for the same nothing."""
    if v is None: return None
    v = str(v).strip()
    return v or None


def mvum_features(bbox, cache):
    counts = collections.Counter()
    for layer in (MVUM_ROADS, MVUM_TRAILS):
        for f in mvum_pages(layer, bbox, cache):
            p, g = f.get("properties") or {}, f.get("geometry")
            if not g: continue
            sym = clean(p.get("symbol"))
            moto = (clean(p.get("motorcycle")) or "").lower()
            if sym in MVUM_SYMBOLS:
                kind, legal = MVUM_SYMBOLS[sym]
                if legal == "any" and moto not in ("open", ""):
                    # The symbol says open and the column disagrees. Rare;
                    # the column is the narrower statement, so believe it.
                    legal = "unknown"
            elif sym in SPECIAL:
                kind = "road" if layer == MVUM_ROADS else "trail"
                legal = "any" if moto == "open" else "unknown"
            else:
                counts["skipped symbol " + str(sym)] += 1
                continue
            seasonal = (clean(p.get("seasonal")) or "").lower() == "seasonal"
            dates = clean(p.get("motorcycle_datesopen"))
            if dates == "01/01-12/31": dates = None
            props = {"kind": kind, "legal": legal, "source": "mvum"}
            if seasonal and dates: props["dates"] = dates
            elif seasonal: props["dates"] = "seasonal"
            for key, out in (("name", "name"), ("id", "ref"), ("forestname", "forest")):
                if clean(p.get(key)): props[out] = clean(p.get(key))
            counts[(kind, legal)] += 1
            yield {"type": "Feature", "geometry": g, "properties": props, "tippecanoe": {"layer": "mvum"}}
    log("MVUM", dict(counts))


# MARK: OpenStreetMap

def osm_access(p):
    """The most specific access tag that applies to a motorcycle, OSM's own precedence."""
    for key in ("motorcycle", "motor_vehicle", "vehicle", "access"):
        v = (p.get(key) or "").split(";")[0].strip().lower()
        if v: return key, v
    return None, None


def osm_features(pbf, work):
    highways = os.path.join(work, "osm-highways.osm.pbf")
    ways = os.path.join(work, "osm-ways.osm.pbf")
    seq = os.path.join(work, "osm-ways.geojsonseq")
    subprocess.run(["osmium", "tags-filter", pbf, "w/highway=" + ",".join(OSM_HIGHWAYS),
                    "-o", highways, "--overwrite"], check=True)
    # Then only ways that say something about vehicles, so the national
    # export is the few hundred thousand that can pass rather than every
    # unclassified road in the country. A `motor_vehicle=yes` that a
    # `motorcycle=no` overrides gets through here and is decided below.
    subprocess.run(["osmium", "tags-filter", highways, "-o", ways, "--overwrite"]
                   + [f"w/{key}=" + ",".join(sorted(OSM_YES)) for key in ("motorcycle", "motor_vehicle", "vehicle")],
                   check=True)
    subprocess.run(["osmium", "export", ways, "-f", "geojsonseq", "--geometry-types=linestring",
                    "-o", seq, "--overwrite"], check=True)
    counts = collections.Counter()
    with open(seq, encoding="utf-8") as f:
        for line in f:
            try: feat = json.loads(line.lstrip("\x1e"))
            except json.JSONDecodeError: continue
            p = feat["properties"]
            key, value = osm_access(p)
            # `access=yes` on a track says nothing about motor vehicles in
            # particular: it is the default everyone already assumes, and
            # half of Colorado's tracks are private behind it. Only a
            # vehicle-specific yes counts.
            if key == "access" or value not in OSM_YES:
                counts["no"] += 1
                continue
            kind = "single" if p.get("highway") in ("path", "bridleway") else "trail"
            if p.get("highway") == "unclassified": kind = "road"
            props = {"kind": kind, "legal": "any", "source": "osm", "highway": p["highway"]}
            for key2, out in (("name", "name"), ("ref", "ref"), ("surface", "surface"),
                              ("tracktype", "tracktype"), ("width", "width")):
                if p.get(key2): props[out] = p[key2]
            # Kept apart from the MVUM's `dates`, which are when a trail is
            # open: OSM's conditional is usually when it is closed, written
            # as "no @ (Nov 23-Jun 30)", and one field would invert one of them.
            cond = p.get("motorcycle:conditional") or p.get("motor_vehicle:conditional")
            if cond: props["restriction"] = cond
            counts[kind] += 1
            yield {"type": "Feature", "geometry": feat["geometry"], "properties": props,
                   "tippecanoe": {"layer": "osm"}}
    log("OSM", dict(counts))


# MARK: Build

def bbox_of(pbf):
    out = subprocess.run(["osmium", "fileinfo", "-g", "header.boxes", pbf],
                         check=True, capture_output=True, text=True).stdout.strip()
    return tuple(float(x) for x in out.strip("()").split(")")[0].split(","))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pbf"); ap.add_argument("out_dir")
    ap.add_argument("--name", required=True, help="region name for the archive, e.g. colorado or us")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    bbox = bbox_of(args.pbf)
    log("bbox", bbox)

    seq = os.path.join(args.out_dir, "trails.geojsonseq")
    with open(seq, "w", encoding="utf-8") as out:
        for feat in mvum_features(bbox, os.path.join(args.out_dir, "mvum-cache")):
            out.write(json.dumps(feat, separators=(",", ":")) + "\n")
        for feat in osm_features(args.pbf, args.out_dir):
            out.write(json.dumps(feat, separators=(",", ":")) + "\n")

    archive = os.path.join(args.out_dir, f"trails-{args.name}-{datetime.date.today():%Y%m%d}.pmtiles")
    # z9 is where a rider starts choosing between forests; below it the
    # lines are noise over the street map. z14 matches the street map's
    # detail, and MapLibre overzooms past it, which for a line is exact.
    # No dropping: a trail missing from the map is the one failure this
    # layer cannot have, so tippecanoe is told to fail instead.
    subprocess.run(["tippecanoe", "-o", archive, "--force", "-P", "--quiet",
                    "-Z9", "-z14", "--no-feature-limit", "--no-tile-size-limit",
                    "--simplification=4", "--name", f"Swiftcamp trails ({args.name})",
                    "--attribution", "USDA Forest Service MVUM; © OpenStreetMap contributors",
                    seq], check=True)
    log("wrote", archive, f"{os.path.getsize(archive) / 1e6:.1f} MB")
    print(f"  rclone copy {archive} r2:swiftcamp-tiles/")


if __name__ == "__main__":
    main()
