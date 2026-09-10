# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status: greenfield

**This repository is empty.** No source, no `git init`, no build system yet. Everything below the "Project Overview" section is *intent and prior art*, not description of existing code. As real code lands, replace the speculative sections with what was actually built and delete this notice.

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

Leaning, not final:

- **Map renderer is a split backend.** MapLibre Native ships iOS-only slices, confirmed by reading `Info.plist` in the 6.29.0 XCFramework: `ios-arm64` and `ios-arm64_x86_64-simulator`, no macOS and no Mac Catalyst. Upstream considers the AppKit port bit-rotted. Plan is one `MapSurface` protocol with MapLibre Native on iOS and MapLibre GL JS in a `WKWebView` on macOS, sharing one style JSON and one `.pmtiles` so cartography never diverges.

Still open:

- **Persistence.** GRDB is the tachbase precedent. SwiftData fits a document-shaped Mac app more naturally.
- **App shape.** `NSDocument`-based, versus a single-library app with an internal database the way BaseCamp works.
- **Project generation.** XcodeGen with a committed `project.yml` and gitignored `.xcodeproj`, as in tachbase-ios, versus a checked-in Xcode project.


## Conventions carried from tachbase

These are the author's established habits; follow them unless told otherwise.

- **Comments explain why, not what.** tachbase's best comments document the failed approach and the constraint that forced the current one. Match that density on anything non-obvious.
- **Migrations are append-only.** Add a new numbered migration; never edit a shipped one.
- **`main` is production.** Work on feature branches, merge via PR.
- Commit subjects are imperative and scoped, e.g. `Map: chart-stack chip replaces the hidden "bring chart to front" tap`.
- Never add Co-Authored-By or Claude attribution to commits or PRs.

## Build commands

None yet. If XcodeGen is adopted, tachbase-ios's `Makefile` is the model:

```bash
xcodegen generate     # regenerate the .xcodeproj from project.yml
```

Regenerate after pulling new files or adding sources, since the `.xcodeproj` is gitignored.
