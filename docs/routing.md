# Routing on device

How Valhalla gets into the Mac app, and how a region's graph gets built.
Written 2026-09-16 from the first working spike. `docs/data-architecture.md`
covers why routing is on-device and what a region pack costs; this is the
how.

## Shape of it

`RouteEditing.LegShaper` is the seam. Every edit that changes a leg asks it
for the path between two via points, and `LibraryModel` resolves it once:
the engine's shaper when a graph is loaded, a straight line otherwise. The
store, the overlay and the GPX writer only ever see `RoutePoint.geometry`,
so nothing above the editor knows whether roads exist.

The engine is `RoutingEngine`, a process-wide singleton wrapping Valhalla's
`actor_t` behind a four-function C API in `Swiftcamp/Routing/ValhallaBridge`.
JSON in, JSON out; the route shape comes back as a polyline encoded at
Valhalla's 1e6 precision, which `Polyline` decodes.

A drag routes live. Every mouse move re-routes the two legs either side of
the moving via point, off the main actor with only the newest position ever
routed, so the line follows the road under the pointer instead of going
straight and snapping on release. Grabbing the line itself grows a shaping
point at the grab and drags that, which is the Google Maps gesture; a click
on the line inserts a via point instead, and the right-click menu converts
either way. Any route can be grabbed, and grabbing selects it; no editing
mode is needed. `LibraryModel.Drag` has the mechanics.

## Modes

Each route has a routing mode, Garmin's activity profile by another name.
It lives on the route because a library holds both kinds of ride, and it
travels in the file as the trip's transportation mode so the device
recalculates the way the planner did. `RoutingMode` in `Library.swift`.

| Mode | Legs follow | A dropped point |
| --- | --- | --- |
| Road | Paved ways the map knows: `exclude_unpaved`, no tracks or trails | Moves onto the nearest one, however far |
| Adventure | Any way the map knows, unpaved and tracks included | Moves onto a way within 50 m; otherwise stays, with a straight leg to the nearest way |
| Driving | Paved roads for a car: Valhalla's `auto` costing, `exclude_unpaved` | Moves onto the nearest one, however far |
| Walking | Footpaths, trails and streets: the `pedestrian` costing, `max_hiking_difficulty` 3 | Moves onto a way within 50 m; otherwise stays |
| Direct | Straight lines, no routing | Stays |

Road cannot promise a *named* way, only a known one: the router knows
paved from unpaved and road from track, not whether a road has a name.

Snapping is `RouteEditing.Snap`. The shaper returns the routed path with
both landings, and each end moves onto its landing when the rule allows;
an end that stays keeps its landing as the first vertex of the leg, so the
spur from the point runs to exactly where the road begins. A via point
made from a waypoint never snaps in any mode: a campsite is where it is.
Changing a route's mode routes every leg again, and undo restores the legs
exactly rather than re-routing in the old mode, because a point Road
snapped onto the pavement would otherwise stay there under Adventure.

In the file, Road and Adventure are both `Motorcycling` to Garmin,
Driving is `Automotive`, Walking is `Walking` and Direct is `Direct`;
which of the first two it was is written in our own namespace so a
re-import keeps it. The curvy preferences are a patch on the motorcycle
costing alone, so Driving and Walking offer only Faster Time and Shorter
Distance, and Walking avoids only ferries. Driving, Walking and the
motorcycle modes all route on the same graph, which carries every mode's
access. New routes take their mode from Settings.

## Preferences

Each route also carries what its legs optimise for and which kinds of
road they keep off, which is the zūmo's own route settings kept on the
route. `RoutePreferences` in `Library.swift`; the inspector, both route
menus and Settings expose it, and changing any of it routes every leg
again, undoably, the way a change of mode does.

| Prefer | Valhalla | Estes Park to Boulder |
| --- | --- | --- |
| Faster Time | the default | 37 mi, 49 min, US 36 |
| Shorter Distance | `shortest` | 36.9 mi, 50 min |
| Some Curves | `use_curvature: 0.4` | 38 mi, 52 min, a change of canyon |
| Many Curves | `use_curvature: 1` | 47 mi, 84 min: Marys Lake Road, CO 7, the Peak to Peak, James Canyon, Lefthand Canyon, Lee Hill |

Avoid highways, tolls and ferries are `use_highways`, `use_tolls` and
`use_ferry` at zero, which Valhalla treats as a heavy penalty rather than
a ban, so a route that can only end past the toll booth still gets there.
Avoiding highways on the same leg gives 58 mi over the Peak to Peak.

`use_curvature` is ours: `scripts/valhalla-curvature.patch`. Valhalla's
graph builder already scores every edge's curvature 0 to 15 from its
shape and stores it on the directed edge, and nothing upstream reads it.
The patch adds the option to the motorcycle costing as a penalty on
straightness: at full preference a straight edge costs thirteen times its
time, falling quadratically to one at curvature 8 and above, with
residential and service roads counted as straight whatever their shape so
a rider is not steered through a winding subdivision. A discount on curvy
edges was tried first and moved nothing, because the twisty alternative
is seventy percent longer and no discount short of free pays for that; a
penalty also keeps the A* heuristic admissible. The response is a step
rather than a slope: on that leg nothing changes below 0.45 and
everything above it, which is why the setting is levels and not a
slider. The graph does not need rebuilding for the patch; the library
does.

In the file, the preference is Garmin's `trp:CalculationMode` on every
via point, which a zūmo honours on import, with both curvy levels as its
one Curvy Roads; which level it was, and the avoidances, are written in
our namespace. A BaseCamp file's first via point speaks for the route.

Scenic byways are the natural next preference, and the public-domain
FHWA National Scenic Byways geometry is the source; Valhalla's
`cost_factor_edges` request option can favour edges along supplied
polylines without touching the graph, which is the way to try it.

## Directions

A selected route's turns, under its fields in the inspector, with the
trip's length and time at the top and a click on any turn looking at it
on the map. `RouteDirections` is the value and `DirectionsPane` the view.

The list is one more request to the engine, every point of the route as
a location with `directions_type` set to instructions, under the route's
own mode and preferences: via points are `break` and named, so an
arrival reads "Camp is on the left", and shaping points are `via`, which
allows a reversal there the way routing leg by leg did. A fresh search
rather than a narration of the stored legs, because Valhalla narrates a
given shape only by map-matching it back onto the graph, and a search
under the same settings finds the same road: on a 62-mile test the
narrative's length matched the drawn line's. Computed off the main actor
when the pane is open and the route is not being routed, kept against
the edit signature it was computed for, and never stored: Garmin's
format carries no instructions and the device narrates the road it is
given, so the list is for planning and printing, as BaseCamp's was. The
leg requests still ask for no narrative, since a drag does not want it.

## Streaming the graph

The graph is not bundled and not downloaded up front. It is one gzipped
object per tile on the CDN under a dated prefix, `graph-us-20260917/`,
plus an `index.json` listing the tiles per level. Valhalla's graph reader
accepts a `mjolnir.tile_url` with a `{tilePath}` pattern, fetches each
tile as a route first needs it and caches it in `mjolnir.tile_dir`; with
`tile_url_gz` it keeps the bytes as served and writes them gzipped, which
is a third of the size on disk too. It records the graph's build id beside
the cache and refuses to mix tiles from a rebuilt graph, which is why a
graph is published under a dated name and never overwritten, the same rule
as the archives. It uses curl rather than a browser, so the CORS lesson
that bit the map does not apply here.

The first cut was a single 21 GB tar read by byte range, which the reader
also supports and which matched the map exactly. It lost to per-tile
objects on two counts: the tar holds tiles uncompressed, and a
cross-country leg fetched 361 MB of them; and a 21 GB object is past
Cloudflare's per-object cache limit, where a 700 KB `.gz` is on its
default list of cacheable types and comes from the edge on the second
request. `scripts/build-graph.sh` still packs the tar, since Valhalla's
own extract tool wants one; the gzipped tree is made beside it with
`gzip -6` per tile and `index.json` from the result.

`RoutingEngine.init(streaming:)` fills the bundled config template,
`Resources/routing/valhalla.json`, with `BasemapSource.routingURL` and a
cache folder under Caches keyed by the graph's name. The template is
`valhalla_build_config`'s output with the extract keys removed, because a
`tile_extract` makes the reader treat it as the whole graph and ignore
`tile_dir`. `-SwiftcampRouting <valhalla.json>` remains the developer
override for a graph on local disk, and the macOS scheme lists it
unchecked.

### Ahead of the route

The engine fetches one tile at a time, the moment a search needs it, and
a cold cross-country leg was sixty-one of them in series. `RoutingPrefetch`
gets there first: after launch it fills the highway and arterial levels for
the whole graph, 102 and 1,044 tiles, about a gigabyte compressed, twelve
at a time, with progress in the sidebar's footer; and after each map move
from zoom 9 it fetches the local tiles under the view, a screenful at
most. Both write into the engine's own cache with the engine's own names,
`RoutingTiles` doing the id-to-path arithmetic ported from
`GraphTile::FileSuffix`, so a launch that finds the tiles on disk costs a
listing. Measured 2026-09-17 on the M3 Ultra's connection: the whole fill
in 18 seconds. A scratch run does neither: a click check should not pull
a gigabyte.

### What a route costs, and where

Instrumented 2026-09-18 behind `-SwiftcampTiming YES`, which the macOS
scheme passes: one console line per stage with the prefix
`Swiftcamp/timing`, so the console filters to the breakdown. What it
found, and what changed:

| Stage | Before | After |
| --- | --- | --- |
| Engine, cold cross-country leg | 7 s, 24 local tiles along the corridor fetched one at a time | 0.45 s after a 20-tile parallel prefetch at the ends; the engine fetched one tile itself |
| Engine, cold local leg, Estes Park to Grand Lake | 2.9 s, 11 serial fetches | 0.6 s prefetch plus 0.1 s search |
| Drag preview of a cross-country leg | 1.2 s per move, the whole search again | 0 ms: straight above 150 km, routed on release in 0.09 s |
| Page, worker parse and first tile of a 13,000-point line | 30 ms | 30 ms |
| Page, to idle | 300 ms | 300 ms, which is the label crossfade settling, not drawing |
| Reply decode, store write, overlay encode, bridge, summaries | 1 to 18 ms each | unchanged |

The corridor fetches were Valhalla's trip leg builder listing each path
node's side streets, which means following its transitions down to the
local level whether or not anyone asked; on a streamed graph each of
those is a fetch. `scripts/valhalla-intersecting-edges.patch` guards that
on the request's attribute filter, and every request now excludes the
intersecting-edge attributes.

### After the edit

Routing is a derivation that follows the write, not part of it. An edit
writes straight legs and returns at once; `LibraryModel.routeStraightLegs`
then routes whatever is straight off the main actor and writes the roads
back, with no undo entry of their own, so undo restores the edit's straight
legs and they are routed again, warm. The sidebar says "routing…" beside
the route meanwhile. A leg the engine refuses stays straight and is not
asked again until one of its ends moves. This is what ended the beachball:
a cross-country click over a cold cache used to run twenty seconds of
fetching inside the click, and now the click returns with a straight leg
and the road follows.

`scripts/build-graph.sh <geofabrik-path> <name>` downloads an extract,
builds the tiles with the planet admin and timezone databases, packs the
tar and prints the `rclone` line that publishes it. Building libvalhalla
with `ENABLE_HTTP=ON` is what makes the fetch possible and adds the system
libcurl to the link.

## Building libvalhalla for the Mac

There is no Homebrew formula and the `valhalla-mobile` Swift package targets
iOS and Android only, so the Mac links a CMake build. It lives inside the
repo at `Vendor/valhalla`, gitignored in the same spirit as the fetched
basemap.

```bash
brew install cmake ninja pkgconf boost geos libspatialite \
             spatialite-tools luajit openssl@3 expat
./scripts/build-valhalla.sh
```

The script clones Valhalla at a pinned release tag, applies both patches
below, configures CMake with the options explained at the end of this
section, and builds. Rerunning it is cheap: it reapplies the patches only
when one has changed and lets ninja rebuild what they touched. The pin is
3.9.0; upstream had not touched any of the three patched files since
before that release when it was chosen, so moving it means checking the
patches still apply and re-measuring what they fix.

A few minutes on an M5 Max. What matters afterwards, under `Vendor/valhalla`:

| Path | What |
| --- | --- |
| `build/src/libvalhalla.a` and `build/src/<module>/libvalhalla-<module>.a` | The library, one archive per module |
| `build/src/valhalla/proto/` | Generated protobuf headers |
| `build/valhalla_build_tiles` | The graph builder |
| `scripts/valhalla_build_config` | Writes the JSON config the engine reads |

The first patch is one guard in the trip leg builder: when a request filters
every intersecting-edge attribute out, as `RoutingEngine` does, the
builder no longer follows each path node's transitions to the local level.
Unpatched, a cross-country leg on the highway levels fetched every local
tile along its corridor, twenty-four of them and seven seconds for a leg
that needed none, because the builder lists the side streets at every
node whether or not anyone asked. It is written to be sent upstream.
The second adds `use_curvature` to the motorcycle costing; see
Preferences above.

`project.yml` points the macOS target at these under
`$(SRCROOT)/Vendor/valhalla`, with a Check Valhalla build phase that stops
early, and says what to run, when the library is missing.

### Its libraries, inside the app

protobuf, abseil and lz4 are built by `scripts/build-deps.sh`, which
`build-valhalla.sh` runs first: static, Apple Silicon, for macOS 14, from
the releases Homebrew's formulae use, pinned by checksum, into
`Vendor/deps`. Valhalla is configured against that prefix first, and the
app links the archives, so the shipped binary loads nothing but the system.

They were Homebrew's dylibs until it came to shipping, and that could not
ship twice over. They load from `/opt/homebrew`, so the app ran on no Mac
without those exact versions installed; and copying them into the app
would not have helped, because a bottle is built for the macOS it was
poured on and every one of them said `minos 27.0`, which dyld refuses on
an older system whatever the app's own deployment target says. Boost
still comes from Homebrew, as headers, which leave nothing in the binary;
the graph tools still link GEOS and SpatiaLite from there, which is fine
for programs that only run on the machine that builds graphs.

The abseil list in `project.yml` is `pkg-config --static --libs protobuf`
against `Vendor/deps`; regenerate it when the pin moves, because abseil's
library set changes between releases. `scripts/package-app.sh` checks
every Mach-O in the built app for a load from outside the system and for
a minimum macOS above 14, and refuses to package either.

Services and Python bindings are off because the app needs neither and
each brings a dependency (prime_server, nanobind). HTTP is on: it is how
the graph streams, and its dependency is the libcurl macOS already has.
Data tools are on so the same build produces `valhalla_build_tiles`.

## Building a region's graph

```bash
mkdir -p ~/valhalla-data/colorado && cd ~/valhalla-data
curl -sLO https://download.geofabrik.de/north-america/us/colorado-latest.osm.pbf
python3 ~/git/swiftcamp/Vendor/valhalla/scripts/valhalla_build_config \
  --mjolnir-tile-dir ~/valhalla-data/colorado/tiles \
  --mjolnir-tile-extract ~/valhalla-data/colorado/tiles.tar \
  --mjolnir-timezone "" --mjolnir-admin "" > colorado/valhalla.json
~/git/swiftcamp/Vendor/valhalla/build/valhalla_build_tiles -c colorado/valhalla.json colorado-latest.osm.pbf
```

Admin and timezone databases are left empty here. Routing works without
them; what they add, and why only a planet build produces a usable admin
database, is in `docs/data-architecture.md`. Delete the `tile_extract` and
`traffic_extract` keys from the generated config, or the engine warns about
a missing tar on every launch.

`scripts/build-graph.sh` is the same recipe with both databases filled in.
The timezone database has to be built by the same Valhalla that builds the
tiles: `scripts/valhalla_build_timezones` in the checkout. An older one
named `Pacific/Midway`, which this version resolves only through the
merged "1970" zone set, and the US build aborted on Midway Atoll's two
tiles ten minutes in, after parsing the whole country in eight. Colorado
never noticed because Colorado has no Midway.

Measured 2026-09-16 on an M5 Max: 22 seconds, 599 tiles, 534 MB on disk.

The M3 Ultra builds with the planet admin database from the earlier admin
work under `~/swiftcamp-build` (see `docs/data-architecture.md` for why
only a planet build yields a usable one) and a timezone database built by
this checkout. Measured 2026-09-17: Colorado in 31 seconds, 599 tiles,
522 MB on disk, so admin data costs nothing at rest.

The whole United States, same machine, same day, 28 threads:

| | |
| --- | --- |
| Extract | 12.15 GB from Geofabrik, about an hour to download |
| Parse | 8 minutes |
| Tile build, validate, clean up | 21 minutes |
| Tiles | 17,177: level 0 0.8 GB, level 1 2.3 GB, level 2 19 GB |
| Tar for streaming | 21 GB, packed in under a minute |
| Scratch during the build | about 50 GB of intermediates, deleted at the end |

Nearly twice the 14 GB the Colorado ratios predicted, so road density per
megabyte of extract is not constant across states.

## Running the app against it

```bash
Swiftcamp.app/Contents/MacOS/Swiftcamp -SwiftcampRouting ~/valhalla-data/colorado/valhalla.json
```

The macOS scheme in `project.yml` passes exactly this argument, so Run in
Xcode loads the Colorado graph when it exists at that path.

Without the argument the engine is nil and every leg is a straight line,
which is also what happens when Valhalla finds no path between two points:
the leg falls back rather than the edit failing.

`-SwiftcampScript` works unchanged; a `dump` step reports each via point's
geometry count, which is zero for a straight leg and hundreds for a road.

## Measured

First spike, 2026-09-16, Colorado graph on local disk:

| | |
| --- | --- |
| First route after launch, Estes Park to Grand Lake | 51 ms |
| Next route, tiles warm | 3 ms |
| Shape points on that leg | 5,724 |

Streamed from R2, 2026-09-17, Colorado tar, empty cache, Estes Park to
Grand Lake and on to Granby:

| | |
| --- | --- |
| Opening the engine, index fetch | one round trip at launch, off the main actor |
| First route, tiles fetched on demand | 823 ms |
| Next routes, tiles cached | 28 ms, 1 ms |
| Tiles fetched for the session | 20, of which 16 local-level |
| Cache after the session | 99 MB |

The cache number is the one to watch. The Colorado average is under a
megabyte per tile, but the Front Range's local tiles run to several, and a
first route pays for every tile along its corridor uncompressed. On a fast
connection it is a sub-second stall once; on a tethered phone it is not.
Gzipped per-tile objects would cut the bytes about threefold at the cost
of the single-file layout, and prefetching under the visible map would
hide most of it. Both are listed under Next.

Fast enough to route on every mouse move, which is what a drag does;
`RoutingEngine.route` logs every call so a regression shows up in the
console rather than as a stutter. A drag is two legs per pass, and passes
run back to back for as long as the pointer keeps moving.

## Things the graph taught

**`access=permit` is treated as closed.** Trail Ridge Road through Rocky
Mountain National Park carries `access=permit` for the park's timed-entry
reservation, plus `access:conditional=no @ Oct 14 - May 31`. The first
route from Estes Park to Grand Lake went round by US 36 and US 40, three
hours instead of one, while a later leg happily used the western segments
that lack the tag. Every national park with timed entry (Glacier, Arches,
Yosemite) is tagged the same way, and a touring rider with a reservation
wants to be routed through. This is a graph-build or costing decision to
make deliberately, not a bug in the spike: Valhalla's `graph.lua` decides
what `permit` means, and the seasonal closure needs a `date_time` on the
request to be honoured at all.

**The config generator's service limits apply to a planner.** They are
written for a public server: a motorcycle route may be 500 km, a tenth of
what a car gets, and a leg from California to Colorado is three times
that. The engine refuses it with "exceeds the max distance limit" and the
planner draws the leg straight, which looks exactly like routing being
off. `RoutingEngine.raiseLimits` lifts it to the car's 5,000 km on both
config paths. Measured through `valhalla_service` on the streamed US
graph: Sacramento to Denver, 1,169 miles, 61 tiles and 361 MB fetched,
18.8 s cold. A click that appends a via point routes on the main actor,
so that first cross-country leg is a stall; routing appends off the main
actor the way drags already do is the fix, listed under Next.

## Next

- Decide what `access=permit` should mean.
- Region packs as "keep this area for offline": pre-fill the same cache
  with a region's local tiles, the way the prefetcher fills the highway
  levels.
- A Cache Rule on the graph prefix would keep tiles at the edge longer
  than the default four hours.
