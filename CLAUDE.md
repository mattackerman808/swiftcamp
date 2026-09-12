# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Getting started on a fresh machine

```bash
git clone https://github.com/mattackerman808/swiftcamp.git && cd swiftcamp
brew install xcodegen pmtiles librsvg rclone
./scripts/fetch-basemap.sh      # ~43 MB, not in git, ~1 second
xcodegen generate               # .xcodeproj is gitignored
open Swiftcamp.xcodeproj
```

Without the basemap fetch the app builds but asserts at launch with no map.

Only `rclone` needs configuring, and only to publish tiles. Set up a remote
named `r2` against Cloudflare R2 with `no_check_bucket = true`; a
bucket-scoped token cannot list buckets, so without that flag rclone tries
`CreateBucket` and gets a 403.

## Current state

**The macOS basemap is done. The product is not started.**

Working: street detail to z15 and terrain streamed from our own CDN,
ground cover coloured by kind, hypsometric elevation tint, hillshade,
buildings, place and street labels, and authentic route shields for all 50
states. Both platforms render, though only macOS is being actively worked
on.

Not started: any data model, waypoints, tracks, routes, GPX import or
export, or route editing. There is a map and nothing to put on it.

## Project Overview

Swiftcamp is a native macOS reimagining of Garmin BaseCamp — plan, share, and manage GPS routes, tracks, waypoints, and related data. Garmin's app is old, unmaintained, and never made the jump to Apple Silicon natively.

Primary use case is **motorcycle and auto touring**: plan a road route on a map, then export GPX to load onto a Garmin (or other) navigator device. Hiking, geocaching, and other outdoor modes are explicitly deferred.

The GPX export path is the product. A route that looks right on screen but imports wrong on the device is a failed feature.

## Prior art: the tachbase projects

The author built [tachbase](https://tachbase.com), an aviation electronic flight bag, across four sibling repos in `~/git`. `tachbase-ios` is a native SwiftUI app with a mature map, offline tile, and route-planning stack. **Read from it before building anything map-shaped here.** Its patterns are proven against real device constraints and its comments explain *why* — several encode expensive lessons.

| Repo | What it is | Relevance |
| --- | --- | --- |
| `~/git/tachbase-ios` | SwiftUI iOS/iPadOS app | **High.** Map, tiles, offline packs, route builder, GRDB store |
| `~/git/tachbase-api` | FastAPI + MariaDB backend | Only if Swiftcamp grows a server |
| `~/git/tachbase-web` | Vanilla JS web app | Low |
| `~/git/tachbase` | Combined/legacy monorepo | Low; its `CLAUDE.md` documents the whole system |

### Specific files worth reading

Paths relative to `~/git/tachbase-ios`:

- `Tachbase/Offline/TileURLProtocol.swift` — a `URLProtocol` that intercepts every MapLibre tile request and serves from disk when the file exists, network otherwise. This is the single "local vs network" decision point, which collapses the usual stacked local+CDN source hack into one source per visual layer. The 256×256 transparent-PNG fallback for 404s (rather than 1×1) is a real fix for MapLibre checkerboarding at coverage boundaries.
- `Tachbase/Map/MapStyle.swift` — builds a MapLibre `style.json` on disk at runtime. The offline max-zoom comment is important: below a source's declared maxzoom MapLibre *requests* tiles instead of overzooming, so declaring a depth the offline pack doesn't carry paints nothing rather than degrading gracefully.
- `Tachbase/Offline/TilePackManifest.swift` and `DownloadManager.swift` — chunked, sha256-verified, resumable region downloads driven by a CDN manifest.
- `Tachbase/Map/RouteBuilder/` — waypoint model, route state, map layers for the route line, and the editing panel. `RouteWaypoint.swift` and `RouteBuilderState.swift` are the cleanest starting points.
- `Tachbase/Sync/Database.swift` — GRDB `DatabasePool` under `Library/NoCloud/`, versioned via `registerMigration("vN")` blocks that are never edited once shipped.
- `Tachbase/Design/Theme.swift` — palette funneled through one `@Observable` store so every view re-renders on theme switch.
- `project.yml` — the XcodeGen manifest this project should be modeled on.

### What does NOT carry over

- **No GPX code exists in tachbase.** Reading and writing GPX 1.1, and matching the quirks of Garmin's extensions, is net-new work here.
- Aviation domain logic (airways, procedures, holds, METARs, ADS-B, W&B) is irrelevant.
- tachbase-ios is **iOS/iPadOS only** — `SUPPORTS_MACCATALYST: NO`. UI code is touch-first and does not transfer to a Mac-native document app. The non-UI layers (tiles, storage, sync) are the reusable part.
- The tachbase account/subscription/entitlement stack assumes a tachbase backend. Swiftcamp has no server.

## Data & infrastructure

Settled, and written up in full in `docs/data-architecture.md`. Read that before touching anything that fetches, builds, or hosts map or routing data. Summary:

- Map tiles stream from a single `.pmtiles` archive on Cloudflare R2 via HTTP range requests. MapLibre Native has a PMTiles v3 reader compiled in, verified against the shipped 6.29.0 binary. No tile server.
- Routing tiles cannot stream. Valhalla needs the graph on local disk, so road snapping requires a per-region download.
- Sources are Protomaps daily planet builds (map) and Geofabrik extracts (routing input). Both free, both ODbL, attribution required. Never hotlink either from the shipping app.
- No backend. Static object storage plus a `manifest.json` that drives the region picker.
- Stage 0 of the app needs no infrastructure at all: a bundled z0–6 basemap renders a world map offline, which is enough to build the data model, waypoints, tracks, and GPX import/export against.

## Architectural decisions

Resolved:

- **Routing runs on-device** via Valhalla, shipped as per-region packs. A hosted API was rejected because BaseCamp-style planning re-routes on every waypoint drag, which makes metered per-request billing hostile and puts a network round trip in the middle of a drag gesture.
- **Data hosting is Cloudflare R2**, chosen for zero egress fees and Range support on `GetObject`.

- **Map renderer is a split backend**, now built and working. MapLibre Native ships iOS-only slices, confirmed by reading `Info.plist` in the 6.29.0 XCFramework: `ios-arm64` and `ios-arm64_x86_64-simulator`, no macOS and no Mac Catalyst. Upstream considers the AppKit port bit-rotted. So iOS uses MapLibre Native and macOS uses MapLibre GL JS in a `WKWebView`. The divergence is confined to `MapContainer.swift`; both consume the same `MapStyle` and the same archives, so cartography cannot drift.
- **XcodeGen**, with `project.yml` committed and `.xcodeproj` gitignored. Regenerate after pulling.

Still open:

- **Persistence.** GRDB is the tachbase precedent. SwiftData fits a document-shaped Mac app more naturally.
- **App shape.** `NSDocument`-based, versus a single-library app with an internal database the way BaseCamp works.
- **Contours.** The usual generator, `maplibre-contour`, is JavaScript, so it would work on macOS and not on iOS. Either pre-generate contour vector tiles for both or accept contours as macOS-only. Hillshade already works on both.


## Conventions carried from tachbase

These are the author's established habits; follow them unless told otherwise.

- **Comments explain why, not what.** tachbase's best comments document the failed approach and the constraint that forced the current one. Match that density on anything non-obvious.
- **Migrations are append-only.** Add a new numbered migration; never edit a shipped one.
- **`main` is production.** Work on feature branches, merge via PR.
- Commit subjects are imperative and scoped, e.g. `Map: chart-stack chip replaces the hidden "bring chart to front" tap`.
- Never add Co-Authored-By or Claude attribution to commits or PRs.

## Map layer reference

Source lives under `Swiftcamp/Map/`. The style is built in Swift and handed
to whichever renderer the platform uses.

| File | Role |
| --- | --- |
| `MapContainer.swift` | The one place the two backends diverge |
| `MapStyle.swift` | All cartography: sources, layers, filters, colours |
| `MapOverlay.swift` | What the map shows, as a value the renderer can be handed |
| `OverlayGeoJSON.swift` | Library content to GeoJSON, pure and testable |
| `BasemapSource.swift` | CDN URLs, bundled asset paths, attribution, max zoom |
| `ShieldCatalog.swift` | **Generated.** Do not edit; see below |
| `macOS/MapWebView.swift` | macOS host, MapLibre GL JS in a web view |
| `macOS/BundleSchemeHandler.swift` | Serves bundle assets with HTTP range support |
| `MapLibreMapView.swift` | iOS host, MapLibre Native |

### Hosting

Tiles are on Cloudflare R2 at `cdn.swiftcamp.app`, bucket `swiftcamp-tiles`,
about 26 GB for roughly $0.24/month with free egress. `manifest.json` in the
bucket records archive names, bounds and attribution.

Archive filenames carry a build date on purpose. PMTiles is read as a long
sequence of range requests against one file, so overwriting in place while a
client has it open lands their next range at the same offset in a *different*
file and the reads corrupt. Publish under a new name and switch the reference.

**CORS is required, and its absence looks like a macOS bug.** Without
`Access-Control-Allow-Origin` *and* `ExposeHeaders` including `content-range`,
WebKit blocks every range request and MapLibre GL JS reports only "Load
failed". MapLibre Native ignores same-origin entirely, so iOS works fine and
the misconfiguration presents as a macOS rendering fault.

### Scripts

```bash
./scripts/fetch-basemap.sh        # bundled z0-6 world archive
python3 scripts/make_shields.py   # sprite sheet + ShieldCatalog.swift
python3 scripts/audit_shields.py  # contrast/legibility check over all 108
```

`make_shields.py` pulls artwork *and* its metadata from
[openstreetmap-americana](https://github.com/osm-americana/openstreetmap-americana)
(CC0), parsing their `shield_defs.js` for each network's artwork, numeral
colour and text padding. It regenerates `ShieldCatalog.swift` in the same run
so colours cannot drift from the sheet they describe.

## The product layer

| Directory | Role |
| --- | --- |
| `Swiftcamp/Model/` | Records, and the only copy of the geo math |
| `Swiftcamp/Store/` | GRDB database, migrations, and the library store |
| `Swiftcamp/GPX/` | GPX 1.1 and 1.0 reader, GPX 1.1 writer |
| `Swiftcamp/Views/` | Window shell, sidebar, and the library model |
| `SwiftcampTests/` | The whole of it, minus the renderer |

A route is via points plus the shaped path between them, and those are
different things. `RoutePoint.geometry` holds the path; today it is a straight
line and when Valhalla lands it is the road, with nothing above that column
changing. Garmin's format draws the same distinction, which is why this is
also the GPX shape.

## Hard-won lessons

Each of these cost real time. They are documented at the code that
implements them; this is the index.

- **Query the renderer, do not reason about it.** Three cartography bugs
  (phantom water, doubled roads, missing numerals) were each diagnosed in
  minutes by calling `queryRenderedFeatures` at the offending pixel, after
  longer spent reasoning wrongly. Do that first.
- **Synthetic checks lie.** A hand-drawn contact sheet twice passed a shield
  bug that the live map showed immediately, because it placed text slightly
  differently from MapLibre. Verify on the real map, or make the check
  measure the property rather than the picture.
- **A layer can mix geometry types.** Protomaps' `water` holds lake polygons
  *and* stream centrelines; filling the linestrings turned creeks into huge
  blobs. Filter on `geometry-type`.
- **`path` is not a road class.** It covers sidewalks, footways, crossings
  and tracks. Drawing it at street width makes every US suburban road look
  doubled.
- **Declaring a depth the data does not have produces confident nonsense.**
  Past a source's maxzoom MapLibre overzooms rather than stopping, so the
  bundled z0-6 archive smeared coastline across the detailed map until its
  layers were capped.
- **A missing sprite image is a per-frame log, not a one-time failure.** Match
  names against a known list rather than concatenating them blind.
- **Ground cover lives in two layers at two depths.** Protomaps puts coarse
  `landcover` at z0-7 and per-polygon `landuse` at z2-15. Colour both without
  a fade and every forest in view blinks out between z7 and z8, because the
  deeper tiles do not contain the features at all — absence, not a maxzoom
  MapLibre can overzoom past.
- **A `didSet` that publishes, behind a SwiftUI binding, is a loop.**
  `List(selection:)` writes through its binding during layout, and assigning a
  `Set` fires `didSet` whether or not the value changed. Rebuilding published
  state there invalidates the view, which lays out again. The window pegs the
  main thread and macOS reports it as not responding. Guard on inequality at
  both ends: the `didSet`, and the assignment it triggers.
- **Reading a file on the main actor freezes the window.** A day's recorded
  track is a few hundred thousand fixes. Parsing and inserting belong on a
  detached task, and so does encoding the overlay, which is proportional to
  the whole library.
- **The snapshot harness photographs the first settled frame, not the last.**
  Overlay data arrives after the basemap and on its own schedule, so a
  one-shot snapshot caught an empty map and looked exactly like a broken
  overlay. Every idle now overwrites the file, and the harness waits past the
  first one.
- **A Garmin route's shape lives in `gpxx:rpt`, not in its via points.** Each
  `<rtept>` carries the road geometry leading away from it inside its
  extension. Drop it and the device re-routes from scratch on import, which is
  precisely "looks right on screen, imports wrong". `RoutePoint.geometry` is
  that list, and it is also where Valhalla's output will go.
- **Match GPX elements on namespace, never on prefix.** `gpxx:` is a
  convention. A file is free to bind Garmin's extensions to any prefix and
  still be valid, so string-matching `gpxx:rpt` silently drops the route shape
  from a perfectly good file. `SwiftcampTests/Fixtures/odd-prefix.gpx` is that
  file.
- **GRDB's snake_case strategies are not inverse over a trailing acronym.**
  `routeID` encodes to `route_id`, and `route_id` decodes back to `routeId`.
  A non-optional property throws and you find it at once; an optional one
  reads back `nil`, so a waypoint saved into a folder comes out unfiled with
  nothing reported. `ColumnNaming` replaces both strategies and
  `ColumnNamingTests` pins the round trip.
- **A launch argument whose value starts with `-` never arrives.** The
  `UserDefaults` argument domain reads any dashed token as a key, so
  `-SwiftcampCenter -105.6,40.3` silently leaves the default nil and the map
  opens where it always did. Every western longitude hits this. Read
  `CommandLine.arguments` directly for anything that can be negative.

