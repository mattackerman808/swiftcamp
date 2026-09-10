# Data & Infrastructure Architecture

How Swiftcamp gets map and routing data onto a device. Written 2026-09-10, before any code exists.

Every figure here was verified against a primary source on that date. Where a number is an estimate, it says so.

## The central asymmetry

Map data and routing data behave completely differently, and almost every decision below falls out of that.

| | Map tiles | Routing tiles |
| --- | --- | --- |
| Format | PMTiles (single-file archive) | Valhalla graph tiles |
| Can stream over HTTP? | **Yes**, via range requests | **No**, needs local disk |
| Published ready-made? | Yes, Protomaps daily planet | No, you build them |
| Build pipeline needed? | Trivial (`pmtiles extract`) | Real batch job |
| Forces a download? | No | Yes |

MapLibre Native has a PMTiles v3 reader compiled into the shipped iOS binary (verified by inspecting symbols in `MapLibre.dynamic.xcframework` 6.29.0), so a remote `.pmtiles` URL is a first-class tile source with no plugin and no local HTTP server.

Valhalla cannot work this way. It needs the graph on local disk, which is exactly why local routing feels instant and a hosted API does not.

## Three tiers of data

1. **Bundled in the app.** A world basemap at roughly z0–6, about 60 MB. Guarantees a map on first paint with no network and no blank screen. Precedent: `Tachbase/Offline/BundledBasemap.swift`.
2. **Streamed from R2.** Full-detail `.pmtiles`, read by range request as the user pans. Nothing to download, no region picker.
3. **Downloaded region packs.** Regional `.pmtiles` plus Valhalla routing tiles. Required for road snapping, and gives full offline use as a side effect.

## Sources and licensing

| Source | What | Cost |
| --- | --- | --- |
| Protomaps daily builds | Planet PMTiles, ~120 GB, z0–15 | Free |
| Geofabrik | `.osm.pbf` regional extracts, rebuilt daily | Free |
| OpenStreetMap | Upstream of both | Free |

All ODbL. Two obligations: attribution, and share-alike on derivative databases.

**ODbL reaches the data, not the code.** Swiftcamp stays proprietary and can be a paid App Store product. What the license touches is OSM-derived data we redistribute, which in practice means the Valhalla routing tiles in a region pack. The conservative read is that a routing graph is a Derivative Database and those tiles must stay redistributable under ODbL.

A user's exported GPX is almost certainly a Produced Work, like a rendered map image, carrying an attribution obligation only. That is the part that would have been awkward and it looks fine.

**Unresolved:** whether vector tiles and routing graphs are Produced Works or Derivative Databases is genuinely contested, not settled. Protomaps takes the narrower Produced Work position for their own basemap. Needs a real legal read before commercial release.

**Do not hotlink upstream.** Protomaps' builds bucket retains about a week of builds, so a shipping app breaks when one rotates, and it is their bandwidth. Their own guidance is to self-host. Geofabrik publishes no documented rate limit; a weekly cron over a handful of regions is normal use, re-pulling hundreds of regions daily is not.

## Hosting: Cloudflare R2

R2 implements the S3 API. `GetObject` supports Range, which is the single load-bearing feature for PMTiles. aws-cli, rclone, and boto3 all work against `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`. ACLs, bucket policies, versioning, and object locking are not implemented; public read needs a custom domain, since the `r2.dev` subdomain is rate-limited and not for production.

Egress is free, which is what makes this viable.

| Item | Cost |
| --- | --- |
| Storage, 120 GB planet | $1.80/month |
| Egress | $0 |
| Free tier | 10 GB, 10M Class B ops/month |
| Reads beyond free tier | $0.36 per million |

### Bucket layout

```
basemap.pmtiles                     # streamed, full detail
regions/<region>.pmtiles            # offline map for one region
regions/<region>-routing.tar.zst    # Valhalla graph for one region
manifest.json                       # region list, sizes, sha256, build date
```

`manifest.json` drives the in-app region picker. Precedent: `Tachbase/Offline/TilePackManifest.swift`.

**There is no server, no database, and no auth.** Static object storage and a manifest.

## The build pipeline

A batch job, not a service. Runs on the M3 Ultra (96 GB RAM, 725 GB free) and writes to R2.

Per region:

1. `pmtiles extract` against the **remote** Protomaps planet, producing `<region>.pmtiles`. Only the bytes belonging to the region are downloaded, so this never touches 120 GB.
2. Fetch the Geofabrik `.osm.pbf` for the region.
3. Run `valhalla_build_tiles` via the `ghcr.io/gis-ops/docker-valhalla` image, then tar and compress the graph.
4. Checksum both artifacts, upload, regenerate `manifest.json`.

**Two separate toolchains, and conflating them will cause pain:**

- **Pipeline toolchain** builds the tiles. Docker on Linux. Easy, and no macOS build required.
- **App runtime toolchain** embeds Valhalla in the app. Needs a real iOS and macOS build. Harder, and a separate problem. `Rallista/valhalla-mobile` wraps Valhalla as a Swift package advertising iOS and Android; macOS support is unconfirmed. Valhalla's README does state it is "fully functional on many Linux and Mac OS distributions", and there is no Homebrew formula, so the Mac side is a CMake build from source.

## Sizes

Verified Geofabrik `.osm.pbf` extract sizes, 2026-09-09 data:

| Extract | Size |
| --- | --- |
| North America | 18.0 GB |
| United States | 11.3 GB |
| US West | 3.2 GB |
| California | 1.2 GB |
| Texas | 685 MB |
| Colorado | 363 MB |
| Washington | 346 MB |
| Arizona | 287 MB |
| Oregon | 241 MB |
| Utah | 160 MB |
| Nevada | 117 MB |
| Montana | 95 MB |
| New Hampshire | 68 MB |
| Vermont | 43.8 MB |

These are the *input*. Colorado was built on 2026-09-10 to measure the output, using `ghcr.io/gis-ops/docker-valhalla` on 8 cores.

| Colorado | Size |
| --- | --- |
| Input `.osm.pbf` | 364 MB |
| Built graph on disk | 501 MB |
| `valhalla_tiles.tar` | 467 MB |
| **`.tar.zst` (level 19)** | **145 MB** |

Build took 4m19s and produced 599 tiles. Download size and on-disk size differ by more than 3x, so quote them separately: a region pack downloads at roughly **0.40x** the source PBF and occupies roughly **1.28x** on disk.

Extrapolating those ratios by PBF size. Rough, since road density per megabyte varies:

| Region | Est. download | Est. on disk |
| --- | --- | --- |
| Colorado | 145 MB (measured) | 467 MB (measured) |
| California | ~480 MB | ~1.5 GB |
| US West | ~1.3 GB | ~4.1 GB |
| United States | ~4.5 GB | ~14 GB |
| North America | ~7.2 GB | ~23 GB |

This retrospectively explains the "15 to 20 GB for North America" figure quoted by secondary sources: it describes on-disk size, not download size.

Tiles split across Valhalla's three hierarchy levels, and the local level dominates:

| Level | Colorado |
| --- | --- |
| 0 (highway) | 18 MB |
| 1 (arterial) | 44 MB |
| 2 (local) | 441 MB |

A highway-and-arterial-only pack would be 62 MB uncompressed versus 501 MB for full detail. Not needed now, but it is a real lever if pack size becomes a problem.

### Admin and timezone build, measured

Rebuilt on 2026-09-10 with `build_admins=True` and `build_time_zones=True`. **Tile size did not change**: still 501 MB on disk, 467 MB tarred, 145 MB as `.tar.zst`.

The auxiliary databases are build-time inputs and **do not ship to the device**:

| Artifact | Size | Ships? |
| --- | --- | --- |
| `valhalla_tiles.tar` | 467 MB | Yes |
| `admins.sqlite` | 6.7 MB | No, build-time only |
| `timezones.sqlite` | 123 MB | No, build-time only |

Admin and timezone information is baked into the graph by `valhalla_build_tiles`. Verified by serving the tar alone, with neither sqlite present, in a clean directory: a Denver to Grand Junction motorcycle route with a departure time returned 392.2 km over 3.77 hours with 10 maneuvers, and `/locate` reported `time_zone_name: America/Denver`. So the 145 MB download figure stands as the production number.

### Finding: state extracts produce broken admin data

The same `/locate` call returned `country: "None"` and `state: "None"` with empty ISO 3166 codes, while the timezone resolved correctly.

The cause is visible in the build log: `valhalla_build_admins` emitted `NOT NULL constraint failed: admin_access.admin_id` for dozens of countries, and built only 7 admin polygons from 2,145 ways. A Geofabrik state extract is clipped, so it does not contain the complete USA country relation, and country and state names cannot attach to nodes.

Timezones were unaffected because `timezones.sqlite` is built from the global timezone-boundary-builder dataset rather than from the PBF, which is also why it is 123 MB.

#### A US-wide extract does not fix it either

Tested on 2026-09-10. Built `admins.sqlite` from `us-latest.osm.pbf` (11.3 GB), then rebuilt the Colorado tiles against it and re-queried `/locate`.

The database is much richer than the state-extract version:

| Admin level | Rows |
| --- | --- |
| 4 (states) | 50 |
| 2 (countries) | 0 |

All 50 states are present with correct ISO codes. But `country` and `state` **still came back unset on the rebuilt tiles**, and the graph enhancement stage logged nothing about admins at all.

The cause is visible in the schema. `admins` has a `parent_admin` column, and every one of the 50 state rows has it `NULL`, because the country polygon they would point at does not exist. Valhalla resolves admins through a country-to-state hierarchy, so orphaned state polygons never attach.

Geofabrik's US extract is clipped at the national boundary and does not carry the complete USA country relation. Valhalla's own error text is the hint: *"Ignore if not using a planet extract."*

#### North America does not fix it either, and the reason is specific

Tested on 2026-09-10 with `north-america-latest.osm.pbf` (19 GB on disk). The resulting 39 MB database finally contains country rows:

| Admin level | Rows |
| --- | --- |
| 2 (countries) | 6 |
| 4 (subdivisions) | 102 |

The six countries are México, Canada, Bermuda, Kalaallit Nunaat, Île de Clipperton, and Saint-Pierre-et-Miquelon. **The United States is not among them**, and the string "United States" never appears anywhere in the build log.

The parenting mechanism itself works correctly:

| Subdivision | Parent |
| --- | --- |
| Ontario | Canada |
| British Columbia | Canada |
| Jalisco | México |
| Sonora | México |
| Colorado | *none* |
| Texas | *none* |

51 level-4 rows are left orphaned, which is the 50 states plus DC.

So this is not a general failure of extract-based admin building. Canada and Mexico assemble fine. It is the USA boundary relation specifically that cannot be built from a North America extract, and the most likely reason is that the relation includes territories outside North America — Guam, American Samoa, the Northern Mariana Islands — so the extract cannot close its rings.

#### Resolved: only a planet build works

Built from `planet-latest.osm.pbf` on 2026-09-10 and confirmed end to end. Valhalla's own error text was right all along: *"Ignore if not using a planet extract."*

| | Value |
| --- | --- |
| Planet PBF | 89 GB, ~10 min from an OSM community mirror |
| Admin build | ~48 min, single-threaded, 1.4 GB RSS |
| `admins.sqlite` | 517 MB |
| Countries (level 2) | 233 |
| Subdivisions (level 4) | 3,051 |

`United States` is present with `iso_code` `US` and `drive_on_right` set, and the state rows parent to it. Rebuilding the Colorado tiles against it, then querying a Denver intersection on a tiles-only deployment:

```
time_zone_name   'America/Denver'
state            'Colorado'
iso_3166-2       'CO'
country          'United States'
iso_3166-1       'US'
```

Routing is unaffected: Denver to Grand Junction on motorcycle costing still returns 392.2 km over 3.77 hours with 10 maneuvers.

Pack size is essentially unchanged, so correct admin data is free:

| Artifact | Size |
| --- | --- |
| `valhalla_tiles.tar` | 476 MB |
| `valhalla_tiles.tar.zst` | 145 MB |

**Pipeline rule:** build `admins.sqlite` once from the planet, keep the 517 MB file, and reuse it for every regional tile build. Rebuild it only when admin boundaries need refreshing, which is rarely. The 89 GB planet PBF can be deleted immediately afterwards.

Ignore the `GEOS error: TopologyException` lines during the build. They come from invalid boundary geometry (observed near Xiamen, China) and do not affect the result.

Tile size was unchanged at 467 MB across all three builds, so none of this affects the 145 MB download figure.

Impact if left unfixed: missing driving side, ISO codes, and admin-derived access restrictions. Modest within the United States, more significant for routes crossing into Canada or Mexico. Timezones work regardless, so time-dependent routing is unaffected.

### Still omitted

- **No elevation.** Grade-aware routing is attractive for motorcycle touring and is the single largest storage multiplier. Interline reports fusing 1.6 TB of elevation for a planet build.

Continental coverage is not a goal. Touring is regional, and a state or small cluster of neighbouring states is the natural unit.

## First-run experience

The asymmetry buys a better cold start than BaseCamp, which makes you install maps before anything works.

- App opens on a live world map. Streaming tiles, no download, no region picker. Pan, drop waypoints, import GPX, draw manually shaped routes.
- Road snapping is the gated feature. The first time the user asks to snap to roads, prompt for the region covering the current viewport.
- A region pack bundles map and routing together, so an installed region also works with no signal.
- Consider shipping Vermont (43.8 MB of source data) inside the app so routing works before any download.

## Build order

**Stage 0 needs no infrastructure at all.** With the bundled z0–6 basemap the app renders a world map offline. The entire shell can be built here: data model, waypoints, tracks, GPX import and export, manual route shaping.

| Stage | Infrastructure | Unlocks |
| --- | --- | --- |
| 0 | None | World map, GPX I/O, manual routes |
| 1 | One `.pmtiles` in R2 + custom domain | Street-level detail via streaming |
| 2 | Pipeline, manifest, one region pack | Road snapping, offline |
| 3 | More regions, planet basemap | Coverage |

## Open questions

- macOS support in `valhalla-mobile`, or whether the Mac needs its own CMake build.
- ODbL classification of routing graphs, for commercial release.
- Whether to ship elevation for grade-aware routing, which is attractive for motorcycle touring and expensive in storage.

Answered by the 2026-09-10 spikes: per-region tile size (145 MB compressed), whether the sqlite databases ship (they do not), and how to get usable admin data (only a planet-built `admins.sqlite` works).
