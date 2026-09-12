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
| Undo and redo | **Build** — nothing has it today |

### Import and export

| Feature | Status |
| --- | --- |
| GPX import, including Garmin extensions | **Have** |
| GPX export with shaping points | **Have** |
| GPX 1.0 read | **Have** |
| **GDB import** | **Build** — see below, this is the migration blocker |
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
| Create a route by clicking the map | **Build** — next up |
| Drag a point to move it | **Build** |
| Insert a point into a leg | **Build** |
| Delete a point | **Build** |
| Via points versus shaping points | **Partial** — the model distinguishes them, the writer does not honour it |
| Reverse a route | **Build**, trivial |
| Route from a track | **Build** |
| Track from a route | **Build** — this is how riders defeat device re-routing |
| Activity profiles: motorcycling, driving, walking | **Build**, needs routing |
| Routing preferences: faster time, shorter distance | **Build**, needs routing |
| Avoidances: tolls, ferries, unpaved, highways | **Build**, needs routing |
| Road snapping and recalculation on drag | **Build** — Stage 2, Valhalla |
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
| Garmin symbols | **Partial** — carried through GPX, not rendered or editable |
| Notes, description, comment | **Partial** — stored, not editable |
| Proximity alarms | **Build**, low priority |
| Categories | **Build**, low priority |
| Photos attached to a waypoint | **Build**, low priority |

### Find

| Feature | Status |
| --- | --- |
| Coordinate entry and goto | **Build**, easy |
| Address search | **Build** — needs a geocoder; a real dependency decision |
| POI search | **Build** — the tiles carry POIs we do not draw yet |
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
| Send and receive over MTP | **Build** — large, and possibly unnecessary |
| Strip shaping points on transfer | **Build** |
| Simplify tracks to a device point limit | **Build** |
| Browse device contents | **Build** |

## The three hard problems

Everything above is ordinary work except these.

### 1. Device transfer on macOS

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
3. **MTP only if the card proves insufficient.** `libmtp` over `libusb` is the
   route, and Subsurface's `libdc` is a precedent for driving Garmin hardware
   through it. Each model needs its USB identifiers registered. Weeks of work
   plus hardware to test against, and worth doing only if a device the author
   cares about has no card slot.

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

### 3. Routing

Stage 2 of `docs/data-architecture.md`, unchanged: Valhalla on device, region
packs, no macOS build confirmed. Everything under "needs routing" above waits
on it. The model is already shaped for it — via points and the geometry
between them are separate — so it drops in rather than rewriting anything.

## Order of work

Each stage is useful on its own, which matters because the deadline is real
and a half-finished replacement that nobody can use is worth nothing.

**Stage A — a usable planner.** Route editing: click, drag, insert, delete,
undo. Via versus shaping points, honoured on export. Waypoint creation and
editing. Reverse a route, route from track, track from route. Lists in the
sidebar with drag and drop. Search and sort. *At the end of this, someone can
plan a ride and hand it to a device by hand.*

**Stage B — migration.** GDB import. Backup and restore. Rename and duplicate.
Track split, join, filter. Elevation profiles and real statistics. *At the end
of this, a BaseCamp user can move their library across and not lose anything.*

**Stage C — the device.** Memory-card and mass-storage transfer, which are the
same code and cover every unit with a card slot. Shaping-point stripping and
track simplification on the way out. MTP only if a device that matters turns
out to need it. *At the end of this, Swiftcamp replaces BaseCamp.*

This stage got much cheaper once the card path was understood, and it could
reasonably move ahead of Stage B.

**Stage D — routing.** Valhalla, region packs, activity profiles, avoidances,
snapping and recalculation on drag. *At the end of this, Swiftcamp is better
than BaseCamp at the thing BaseCamp was for.*

**Stage E — the rest.** 3-D and tilt, contours, printing, measuring tools,
address and POI search, photos.

Curated route discovery, the second half of what was asked for originally,
sits after Stage D because it is built on the same road data as snapping.

## Open questions

- **Is MTP ever needed?** Answered for now: no. The zūmo XT3 has a card slot
  and the Navigator VI mounts as a volume, so both devices on hand are served
  without it. It becomes a question again only for a unit with no card slot.
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
