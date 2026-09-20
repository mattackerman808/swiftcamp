# BaseCamp parity

What Garmin BaseCamp does, what Swiftcamp would have to do to replace it, and
in what order. Written 2026-09-12 against BaseCamp 4.8.x.

## Why this is worth doing, and why now

BaseCamp is not a competitor. It is an abandoned incumbent with a dated
expiry.

- **Garmin has discontinued BaseCamp development.** The team was disbanded;
  changes happen "as necessary" and nothing more.
- **The Mac build is Intel-only and runs under Rosetta.** macOS 26 Tahoe was
  the last release supporting Intel Macs. Rosetta 2 remains generally
  available through macOS 27 and is withdrawn in macOS 28, leaving only a
  subset for old games. Since macOS 26.4 the system already warns users on
  launching an Intel-only app.
- **Garmin's stated replacement is the Explore web portal**, which users
  report as far less capable for device management.

So BaseCamp on the Mac stops working around autumn 2027, its users have
nowhere good to go, and the thing that replaces it does not exist yet. That
is the whole opportunity, and it also sets the deadline.

The competition worth knowing: **MyRouteApp** is web and subscription, and its
paid tier licenses HERE maps specifically so a planned route reproduces
exactly on a Garmin. **Kurviger** optimises for curvy roads and is strong at
what it does but is not a library manager. **Scenic** and **Rever** are
phone-first. None of them is a Mac-native desktop library application, which
is precisely the hole BaseCamp leaves.

## What "parity" cannot mean

Some of BaseCamp is Garmin-proprietary and is not available to us at any
price. Naming these up front stops them being treated as gaps.

| BaseCamp feature | Why not |
| --- | --- |
| City Navigator, Topo, other Garmin map products | Licensed Garmin data, sold per region. We use OpenStreetMap. |
| BirdsEye satellite imagery | A Garmin subscription tied to Garmin accounts and devices. |
| Garmin Custom Maps (KMZ) | Possible in principle, low value, Garmin-specific. |
| Garmin Adventures publishing | The service is effectively dead. |
| Picasa upload | Google shut Picasa down in 2016. |
| BaseStation live dog and contact tracking | Requires Garmin radio hardware. |
| Device firmware updates | Garmin Express does this and owns the update channel. |
| "Match route to device map" | Needs the device's own map. Shaping points are the answer instead, and a better one. |

Everything else is fair game.

## The inventory

Compiled from Garmin's own BaseCamp help and the GPSrChive function
reference. Verdicts: **Have** works today, **Partial** exists but is
incomplete, **Build** is planned, **Won't** is out of scope above.

### Library and organisation

| Feature | Status |
| --- | --- |
| Waypoints, routes, tracks as first-class types | **Have** |
| Lists and list folders, nested | **Partial** — schema exists, no UI |
| Rename, duplicate, delete | **Partial** — delete only |
| Cut, copy, paste between lists | **Build** |
| Drag items between lists | **Build** |
| Search within the collection | **Build** |
| Sort and filter by type, name, date, length | **Build** |
| Multiple databases | **Build**, low priority |
| Backup and restore | **Build** — `VACUUM INTO` makes this nearly free |
| Undo and redo | **Partial** — route edits and route creation; nothing else yet |

### Import and export

| Feature | Status |
| --- | --- |
| GPX import, including Garmin extensions | **Have** |
| GPX export with shaping points | **Have** |
| GPX 1.0 read | **Have** |
| **GDB import** | **Build** — see below, this is the migration blocker |
| **Restore from BaseCamp's own files** | **Build** — its on-disk library and its backups, read in place; see below |
| GDB export | **Build**, low priority |
| KML/KMZ export, "view in Google Earth" | **Build**, low priority |
| Loc, TCX, FIT | **Build**, low priority |

### Map display

| Feature | Status |
| --- | --- |
| Street map with labels and route shields | **Have** |
| Terrain shading, ground cover | **Have** |
| Pan, zoom, rotate | **Partial** — no rotate control |
| 2-D and 3-D views, tilt, elevation exaggeration | **Build**, and cheap: the renderer already does pitch and terrain |
| Overview map inset | **Build**, low priority |
| Map product switching | **Build** — our equivalent is a layer picker |
| Contour lines | **Build** — noted in CLAUDE.md as the one place the split-backend plan costs something |
| Draw order of overlays | **Build**, low priority |
| Print, including multi-page posters | **Build** |

### Route planning

| Feature | Status |
| --- | --- |
| Create a route by clicking the map | **Have** — straight legs until routing lands |
| Drag a point to move it | **Have** |
| Insert a point into a leg | **Have** — click the line, or drag it |
| Delete a point | **Have** |
| Via points versus shaping points | **Have** — dragging the line makes a shaping point, clicking makes a via point, either converts; written as `trp:ShapingPoint` and `trp:ViaPoint` |
| Reverse a route | **Have** |
| Route from a track | **Build** |
| Track from a route | **Build** — this is how riders defeat device re-routing |
| Activity profiles: motorcycling, driving, walking | **Partial** — Road, Adventure and Direct per route, written as Garmin's transportation mode; driving and walking to come |
| Routing preferences: faster time, shorter distance | **Build**, needs routing |
| Avoidances: tolls, ferries, unpaved, highways | **Partial** — unpaved and tracks through the mode; tolls, ferries and highways to come |
| Road snapping and recalculation on drag | **Partial** — live against a local Valhalla graph; region packs and streaming to come |
| Trip planner with departure and arrival times | **Build**, later |

### Tracks

| Feature | Status |
| --- | --- |
| Display with per-track colour | **Have** |
| Segments preserved | **Have** |
| Split and join | **Build** |
| Invert | **Build** |
| Filter and simplify, point count reduction | **Build** — also needed for device limits |
| Insert, move, erase points | **Build** |
| Elevation profile | **Build** — we already stream the DEM |
| Playback along a track | **Build**, low priority |
| Statistics: distance, time, ascent, moving average | **Partial** — distance only |

### Waypoints

| Feature | Status |
| --- | --- |
| Create, name, place | **Build** |
| Garmin symbols | **Partial** — 37 of them drawn on the map and in the sidebar and picked from either's right-click menu (`SymbolCatalog`); the rest carried through GPX untouched and drawn as the generic pin |
| Notes, description, comment | **Partial** — stored, not editable |
| Proximity alarms | **Build**, low priority |
| Categories | **Build**, low priority |
| Photos attached to a waypoint | **Build**, low priority |

### Find

| Feature | Status |
| --- | --- |
| Coordinate entry and goto | **Have** — decimal, degrees-minutes, DMS, with or without hemisphere letters |
| Address search | **Have** — house numbers from the US Census geocoder, online; places and streets from our own index, offline once fetched |
| POI search | **Have** — fuel, food, lodging, camping, hospitals, pharmacies, motorcycle shops, peaks, passes, viewpoints, from our index |
| Find near a selected item | **Build** |
| Geocaching | **Won't for now** — CLAUDE.md defers it explicitly |

### Measuring

| Feature | Status |
| --- | --- |
| Distance and heading between points | **Build** — `GeoMath` already has both |
| Enclosed area | **Build** |
| Elevation readout under the cursor | **Build** |

### Device transfer

| Feature | Status |
| --- | --- |
| Send and receive via a memory card | **Build** — small, see below |
| Send and receive over MTP | **Have** — built against a zūmo XT3, see below |
| Strip shaping points on transfer | **Build** |
| Simplify tracks to a device point limit | **Build** |
| Browse device contents | **Have** |

## The three hard problems

Everything above is ordinary work except these.

### 1. Device transfer on macOS

**Update:** MTP was built anyway, in two days, on the `swift-hakchi2` USB
transport described below, and works against the zūmo XT3 in both
directions. The reasoning that follows is kept because it is why the card
path is still worth building for units without MTP, and because it was
right about the cost: the transport was the hard half and it already existed.
The lessons the protocol taught are indexed in `CLAUDE.md`.

Smaller than it first looked, because the memory card sidesteps the hard part.

**What MTP is.** Media Transfer Protocol, Microsoft's, now a USB device class,
and yes — it is the same thing Android phones use. It is not a filesystem. The
device serves *objects* in reply to commands, and the host never sees a block
device, so there is nothing for macOS to mount. Devices prefer it because USB
mass storage requires handing the raw disk to the computer and giving up use of
its own storage while plugged in; MTP lets the unit keep working. macOS has no
MTP support at all, which is why Mac users are pointed at OpenMTP, MacDroid or
Android File Transfer. BaseCamp works because Garmin shipped their own stack.

**The memory card avoids all of it.** A microSD card in a reader mounts as an
ordinary FAT volume. Garmin units read GPX from `Garmin/GPX` on the card —
case-sensitive, and it walks subfolders, so `Garmin/GPX/2026 Rockies/` works —
and the files are then imported through Trip Planner. Experienced riders
already prefer this to internal memory, because the device rewrites and prunes
what it finds there and leaves the card alone.

So the plan is:

1. **Write to a mounted card.** Detect a volume with a `Garmin` folder, or let
   the user pick one, and read and write `Garmin/GPX`. This is ordinary file
   handling and is the smallest useful version of device support.
2. **Mass storage for older units**, which is the same code: they mount as a
   volume with the same layout.
3. **MTP if it is ever wanted, and it is cheaper than it looks.** The hard
   part of talking to a USB device from a Mac app is already solved in the
   author's own `~/git/swift-hakchi2`, whose `USBBridge/src/usb_device.c` is a
   664-line IOKit implementation of exactly the transport MTP needs: open by
   vendor and product id, bulk read and write with timeouts, control
   transfers, clear-halt, reset, multi-interface claiming, and endpoint-to-pipe
   discovery. It is C, wrapped in Swift actors, and proven against real
   hardware.

   Two details from it worth carrying over. It opens with `USBDeviceOpen` and
   falls back to `USBDeviceOpenSeize`, which is what takes a device another
   driver is already holding. And despite that project's own notes claiming
   otherwise, it ships **no entitlements file at all** — an unsandboxed Mac app
   reaches IOKit USB without one. That stops being true the day either app is
   sandboxed for the App Store.

   What would be left is the protocol itself: PTP container framing and the
   dozen operations that matter, plus Garmin's per-model product ids. A week,
   not a quarter. `libmtp` over `libusb` remains the alternative, but vendoring
   a second USB stack when one already exists in the next repository along
   would be strange.

**The hardware on hand covers both paths.** The author's zūmo XT3 speaks MTP
over USB but has a microSD slot, so the card path serves it. A BMW Motorrad
Navigator VI — the same platform as a zūmo 595 — still connects as mass
storage on a Mac, so it exercises the mounted-volume path directly. Between
them, device support can be built and tested without MTP and without hunting
for old hardware.

### 2. GDB import

BaseCamp's library lives in `AllData.gdb`, an undocumented Garmin binary
format. A user with years of waypoints and routes cannot move to Swiftcamp
without it, and telling them to export everything to GPX first is both a chore
and lossy.

It is tractable: GPSBabel implements GDB read and write, and there is a
published reverse-engineering write-up of the format. Reimplementing the read
path is real work but bounded, and it is the single feature most likely to
decide whether someone actually switches.

**This deserves to be earlier than its glamour suggests.**

Alongside it: **restore from BaseCamp's own files, in place.** BaseCamp on
the Mac keeps its library under `~/Library/Application Support/Garmin/
BaseCamp/Database/<version>/`, and its Backup command writes a bundle of the
same database plus settings. Once GDB reads, both of those are a file to
find rather than a format to learn, and reading them directly means a user
never has to open BaseCamp to leave it — which matters most on the day
BaseCamp stops launching. What the settings half should carry over (activity
profiles, avoidances, display preferences) is a separate, smaller question.

### 3. Routing

Stage 2 of `docs/data-architecture.md`, unchanged: Valhalla on device, region
packs, no macOS build confirmed. Everything under "needs routing" above waits
on it. The model is already shaped for it — via points and the geometry
between them are separate — so it drops in rather than rewriting anything.

The remaining unknown is building a large C++ library into a Mac app, and
there is precedent for that too: `swift-hakchi2` vendors mbedTLS and libssh2
as source targets and links them into a Swift app. Valhalla is bigger and
brings its own dependency graph, but the shape of the problem is one the
author has already solved once. That project builds with Swift Package
Manager and this one with XcodeGen, so the mechanism differs; the approach
does not.

## Order of work

Each stage is useful on its own, which matters because the deadline is real
and a half-finished replacement that nobody can use is worth nothing.

**Stage A — a usable planner.** Route editing: click, drag, insert, delete,
undo. Via versus shaping points, honoured on export. Waypoint creation and
editing. Reverse a route, route from track, track from route. Lists in the
sidebar with drag and drop. Search and sort. *At the end of this, someone can
plan a ride and hand it to a device by hand.*

**Stage B — migration.** GDB import, and restoring straight from BaseCamp's
own database and backup files. Backup and restore of our own. Rename and
duplicate. Track split, join, filter. Elevation profiles and real statistics.
*At the end of this, a BaseCamp user can move their library across and not
lose anything.*

**Stage C — the device.** MTP is done. Left: memory-card and mass-storage
transfer, which are the same code and cover every unit with a card slot;
shaping-point stripping and track simplification on the way out. *At the end
of this, Swiftcamp replaces BaseCamp.*

**Stage D — routing.** Valhalla, region packs, activity profiles, avoidances,
snapping and recalculation on drag. *At the end of this, Swiftcamp is better
than BaseCamp at the thing BaseCamp was for.*

**Stage E — the rest.** 3-D and tilt, contours, printing, measuring tools,
address and POI search, photos.

Curated route discovery, the second half of what was asked for originally,
sits after Stage D because it is built on the same road data as snapping.

## Open questions

- **Is MTP ever needed?** Overtaken: it was built, and it is the path the
  zūmo XT3 uses. The card path remains for units that mount as a volume.
- **Address search needs a geocoder.** Self-hosting Nominatim is a real
  service with real cost, and every hosted option has terms. This is the first
  feature that would put a vendor back in the serving path, which
  `docs/data-architecture.md` deliberately avoided.
- **Is GDB export needed, or only import?** Export matters only for users
  keeping a foot in BaseCamp during the transition.
- **Trips, as distinct from routes.** BaseCamp models an itinerary with
  departure and arrival times separately from the route geometry. Worth
  deciding whether that is a real need for touring or just BaseCamp's
  furniture.

## Sources

- [BaseCamp (Mac) help: routes, trips, tracks and adventures](https://www8.garmin.com/manuals/webhelp/basecampmac/EN-US/GUID-D6147E58-01AF-4472-AB5D-94946B0C20B0.html)
- [GPSrChive BaseCamp function reference](https://www.gpsrchive.com/BaseCamp/Function.html)
- [Garmin forums: the end is nigh for BaseCamp Mac users](https://forums.garmin.com/apps-software/mac-windows-software/f/basecamp-mac/434619/the-end-is-nigh-for-basecamp-mac-users)
- [MacRumors: macOS 27 is the last to support Intel apps via Rosetta 2](https://www.macrumors.com/2026/06/10/macos-golden-gate-last-to-support-intel-apps/)
- [Garmin: automotive devices that use mass storage or MTP mode](https://support.garmin.com/en-US/?faq=77D481cWq24G0Uuvqdycj5)
- [zūmo XT owner's manual: transferring GPX files from your computer](https://www8.garmin.com/manuals/webhelp/GUID-E024D22C-EA17-40B3-A63F-E9535D86014B/EN-US/GUID-CACE2D6E-A614-4AB9-9924-35BAFDE21913.html)
- [GPSBabel: Garmin MapSource GDB format](https://www.gpsbabel.org/htmldoc-1.7.0/fmt_gdb.html)
- [Reverse-engineered notes on the Garmin MPS, GDB and GFI formats](https://www.memotech.franken.de/FileFormats/Garmin_MPS_GDB_and_GFI_Format.pdf)
- [MyRouteApp forum: is MRA the replacement for BaseCamp?](https://forum.myrouteapp.com/topic/3093/is-mra-the-replacement-for-basecamp)
