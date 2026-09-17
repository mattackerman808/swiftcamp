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

In the file, Road and Adventure are both `Motorcycling` to Garmin, and
Direct is `Direct`; which of the first two it was is written in our own
namespace so a re-import keeps it. New routes take their mode from
Settings.

## Building libvalhalla for the Mac

There is no Homebrew formula and the `valhalla-mobile` Swift package targets
iOS and Android only, so the Mac links a CMake build from a sibling checkout.
This is a developer-machine dependency for now, in the same spirit as the
fetched basemap; packaging it as an XCFramework is the next step.

```bash
brew install cmake ninja pkgconf boost protobuf geos libspatialite \
             spatialite-tools luajit openssl@3 expat
cd ~/git && git clone --recurse-submodules --shallow-submodules --depth 1 \
    https://github.com/valhalla/valhalla.git
cd valhalla
cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_STATIC_LIBRARY_MODULES=ON \
  -DENABLE_SERVICES=OFF -DENABLE_PYTHON_BINDINGS=OFF -DENABLE_TESTS=OFF \
  -DENABLE_HTTP=OFF -DENABLE_GEOTIFF=OFF -DENABLE_CCACHE=OFF \
  -DENABLE_TOOLS=ON -DENABLE_DATA_TOOLS=ON -DENABLE_SINGLE_FILES_WERROR=OFF \
  -DCMAKE_PREFIX_PATH="/opt/homebrew;/opt/homebrew/opt/openssl@3" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build build
```

A few minutes on an M5 Max. What matters afterwards:

| Path | What |
| --- | --- |
| `build/src/libvalhalla.a` and `build/src/<module>/libvalhalla-<module>.a` | The library, one archive per module |
| `build/src/valhalla/proto/` | Generated protobuf headers |
| `build/valhalla_build_tiles` | The graph builder |
| `scripts/valhalla_build_config` | Writes the JSON config the engine reads |

`project.yml` points the macOS target at these under `$(HOME)/git/valhalla`,
and links protobuf and its abseil dependencies from Homebrew. The abseil
list came from `pkg-config --libs protobuf`; regenerate it if protobuf is
upgraded, because abseil's library names carry its release date.

Services, Python bindings and HTTP are off because the app needs none of
them and each brings a dependency (prime_server, nanobind, curl). Data tools
are on so the same build produces `valhalla_build_tiles`.

## Building a region's graph

```bash
mkdir -p ~/valhalla-data/colorado && cd ~/valhalla-data
curl -sLO https://download.geofabrik.de/north-america/us/colorado-latest.osm.pbf
python3 ~/git/valhalla/scripts/valhalla_build_config \
  --mjolnir-tile-dir ~/valhalla-data/colorado/tiles \
  --mjolnir-tile-extract ~/valhalla-data/colorado/tiles.tar \
  --mjolnir-timezone "" --mjolnir-admin "" > colorado/valhalla.json
~/git/valhalla/build/valhalla_build_tiles -c colorado/valhalla.json colorado-latest.osm.pbf
```

Admin and timezone databases are left empty here. Routing works without
them; what they add, and why only a planet build produces a usable admin
database, is in `docs/data-architecture.md`. Delete the `tile_extract` and
`traffic_extract` keys from the generated config, or the engine warns about
a missing tar on every launch.

Measured 2026-09-16 on an M5 Max: 22 seconds, 599 tiles, 534 MB on disk.

The M3 Ultra builds with the planet admin database and the timezone
database from the earlier admin work instead, both under
`~/swiftcamp-build` (see `docs/data-architecture.md` for why only a planet
build yields a usable one). Measured 2026-09-17: 31 seconds, 599 tiles,
522 MB on disk, so admin data costs nothing at rest.

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

## Next

- Rebuild with `ENABLE_HTTP=ON` and try `mjolnir.tile_url` against tiles on
  R2 with an empty local cache, and measure the first route. That is the
  streaming model discussed in `docs/data-architecture.md`.
- Package libvalhalla and its dependencies as an XCFramework so the app
  builds on a machine without the sibling checkout.
- Decide what `access=permit` should mean.
