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
| Lists and list folders, nested | **Have** — a lists pane above the items; the map follows the selected list |
| Rename, duplicate, delete | **Have** — Duplicate on every item's menu and ⌘D on the selection; the copy is named after the original and selected |
| Cut, copy, paste between lists | **Have** — Edit menu and each row's menu; a paste lands in the list being looked at, or the list whose menu it came from. Inside the app it is exact: a copy pastes as copies, a cut moves the items themselves. The pasteboard carries GPX, so a route pastes into another app as a file, and GPX copied elsewhere, as text or as files in the Finder, pastes in as an import |
| Drag items between lists | **Have** — drag onto a list, or Move to List in the menu; a list dragged onto a list nests |
| Search within the collection | **Have** — the filter field, over name, comment and notes |
| Sort and filter by type, name, date, length | **Have** |
| Multiple databases | **Build**, low priority |
| Backup and restore | **Have** — File, Back Up Library writes the library file with `VACUUM INTO`; Restore replaces everything from one, row by row through the open pool, after a warning |
| Undo and redo | **Have** — every edit in the planner, and deleting anything: a route or a track comes back whole, points and all, unfiled if its list went meanwhile |

### Import and export

| Feature | Status |
| --- | --- |
| GPX import, including Garmin extensions | **Have** |
| GPX export with shaping points | **Have** — and to a device the road itself goes as shaping points by default, which is what a zūmo XT3 takes for a route of any length; see the Transfer window's Road picker |
| GPX 1.0 read | **Have** |
| **GDB import** | **Have** — BaseCamp's Export and MapSource files, and BaseCamp's autosaved `AllData.gdb` in its newer layout, each verified against a real file of the same route; see below |
| **Restore from BaseCamp's own files** | **Have** — File, Import BaseCamp Library finds the autosave under Application Support and brings it across with its lists from `FolderData.gfi`; a BaseCamp Backup file goes through Import and is read the same way from inside its zip |
| GDB export | **Build**, low priority |
| KML/KMZ export, "view in Google Earth" | **Build**, low priority |
| Loc, TCX, FIT | **Build**, low priority |

### Map display

| Feature | Status |
| --- | --- |
| Street map with labels and route shields | **Have** |
| Terrain shading, ground cover | **Have** |
| Pan, zoom, rotate | **Have** — ⌥-drag turns the map, and in 3-D tilts it; two fingers twisting on a trackpad turn it too (not yet tried on a real trackpad); Rotate Left, Rotate Right and Face North in the View menu on Maps' keys, and a compass on the map while it is turned, which faces north when clicked |
| 2-D and 3-D views, tilt, elevation exaggeration | **Have** — the 2D/3D button at the map's top right (⌘3) tilts the map over the DEM at a mild exaggeration, and lays it flat and north-up again; a navigator's track-up has no meaning on a desk |
| Overview map inset | **Build**, low priority |
| Map product switching | **Build** — our equivalent is a layer picker |
| Contour lines | **Have**, macOS only — Show Contour Lines in the View menu: drawn in the page from the same DEM as the hillshade by maplibre-contour, in feet, every 500 ft at a regional zoom down to every 40 ft close in, majors labelled. iOS would need pre-built contour tiles |
| Dirt bike trails (not in BaseCamp) | **Have** — Show Dirt Bike Trails in the View menu draws the Forest Service's Motor Vehicle Use Maps and OpenStreetMap's motorcycle-legal ways, coloured by who may ride them, seasonal ones dashed, with the dates in the hover; `docs/data-architecture.md` |
| Show and hide items on the map | **Have** — a checkbox on every sidebar row and Hide on Map in its menu, per list for everything filed in it, and Show Routes, Tracks and Waypoints in the View menu, with Show Everything on Map as the way back; editing a hidden route ticks it back on |
| Draw order of overlays | **Build**, low priority |
| Print, including multi-page posters | **Partial** — File, Print prints the map as it is on screen, with its attribution, and under it the selected route's stops and turn-by-turn directions, a track's statistics or a waypoint's notes, running onto further pages. Multi-page posters of the map itself are not built |

### Route planning

| Feature | Status |
| --- | --- |
| Create a route by clicking the map | **Have** — straight legs until routing lands |
| Drag a point to move it | **Have** |
| Insert a point into a leg | **Have** — click the line, or drag it |
| Delete a point | **Have** |
| Waypoints into a route | **Have** — drag one, or the selection, onto a route in the sidebar to append it, or onto a stop to go in before it; Add to Route on the waypoint's menu; click or right-click it on the map while editing. The stop is pinned, wears the waypoint's symbol, and follows the waypoint when it is moved, renamed or given a new icon |
| Reorder a route's points | **Have** — drag the rows under the route; only legs with new neighbours are routed again |
| Via points versus shaping points | **Have** — dragging the line makes a shaping point, clicking makes a via point, either converts; written as `trp:ShapingPoint` and `trp:ViaPoint` |
| Reverse a route | **Have** |
| Route from a track | **Have** — the track is the route's shape, with its bends as shaping points |
| Track from a route | **Have** — this is how riders defeat device re-routing |
| Activity profiles: motorcycling, driving, walking | **Have** — Road, Adventure, Driving, Walking and Direct per route, written as Garmin's transportation mode: Motorcycling, Automotive, Walking, Direct. Driving is Valhalla's car costing, Walking its pedestrian costing on trails up to demanding hiking. `Walking` on a unit is not yet measured |
| Routing preferences: faster time, shorter distance | **Have** — plus Some Curves and Many Curves, the zūmo's curvy roads, from Valhalla's edge curvature |
| Avoidances: tolls, ferries, unpaved, highways | **Have** — unpaved and tracks through the mode; highways, tolls and ferries per route |
| Road snapping and recalculation on drag | **Have** — the whole US graph streams from the CDN, tile by tile, and is cached |
| Turn-by-turn directions | **Have** — under the route in the inspector, from Valhalla's narrative; a click looks at the turn. Screen and print only: the device narrates the road itself |
| Trip planner with departure and arrival times | **Build**, later — the directions already carry each leg's time |

### Tracks

| Feature | Status |
| --- | --- |
| Display with per-track colour | **Have** |
| Segments preserved | **Have** |
| Split and join | **Have** — Split Track Here on the map's menu cuts at the nearest fix, both halves keeping it; Join on the sidebar's menu with two or more selected, each ride staying its own segments |
| Invert | **Have** |
| Filter and simplify, point count reduction | **Have** — Simplify Track to 500, 2,000 or 10,000 points, each segment keeping its share and its ends |
| Insert, move, erase points | **Have** — Edit Points on the track's menu puts its fixes out as handles: drag one to move it, click or drag the line to add one with its time and height read off its neighbours, right-click to delete it or trim everything before or after it. In place, each edit one undo, and a few rows of SQL however long the ride; handles are drawn for the fixes in view, up to 1,500 |
| Elevation profile | **Have** — under the route or track in the inspector, hover for the height at a distance; a recording's own heights, else the DEM read straight from the terrain archive by our own reader (`PMTiles`, `TerrainSampler`) |
| Playback along a track | **Build**, low priority |
| Statistics: distance, time, ascent, moving average | **Have** — moving and elapsed time, moving speed, climb and descent with a five-metre noise gate, in the inspector when the recording has a clock and an altimeter |

### Waypoints

| Feature | Status |
| --- | --- |
| Create, name, place | **Have** — from the map's right-click menu, the toolbar or ⇧⌘N; dragged into place |
| Garmin symbols | **Partial** — 37 of them drawn on the map and in the sidebar and picked from either's right-click menu (`SymbolCatalog`); the rest carried through GPX untouched and drawn as the generic pin |
| Notes, description, comment | **Have** — in the inspector under the sidebar, for waypoints, routes and tracks |
| Proximity alarms | **Build**, low priority |
| Categories | **Build**, low priority |
| Photos attached to a waypoint | **Build**, low priority |

### Find

| Feature | Status |
| --- | --- |
| Coordinate entry and goto | **Have** — decimal, degrees-minutes, DMS, with or without hemisphere letters |
| Address search | **Have** — house numbers from the US Census geocoder, online; places and streets from our own index, offline once fetched |
| POI search | **Have** — fuel, food, lodging, camping, hospitals, pharmacies, motorcycle shops, peaks, passes, viewpoints, from our index |
| Find near a selected item | **Have** — Find Near on a waypoint, the pinned result or empty map, and Find Along Route on a route: fuel, food, lodging, camping, motorcycle shops, groceries, medical, EV charging, sights, from our own index. A panel over the map lists them nearest first, or in the order the road meets them within two miles of it, and dots mark them; a click pins one to keep. A long route reads every index cell it crosses, each fetched once |
| Geocaching | **Won't for now** — CLAUDE.md defers it explicitly |

### Measuring

| Feature | Status |
| --- | --- |
| Distance and heading between points | **Have** — Measure on the toolbar or ⇧⌘M; every click adds a point, the bar shows the total, the last leg and its heading, and the straight line; Delete takes a point back, Escape finishes |
| Enclosed area | **Have** — from the ruler's third point on, the bar says what the clicks enclose, in acres or square miles, and the map fills it, closed back to the first point |
| Elevation readout under the cursor | **Have** — position and height at the pointer, bottom right of the map, read off the terrain tiles in the page |

### Device transfer

| Feature | Status |
| --- | --- |
| Send and receive via a memory card | **Have** — a volume with a `Garmin` folder appears in the Transfer window beside the USB units and is browsed, read and written as `Garmin/GPX` through the same panes; a unit that mounts as a disk is the same path |
| Send and receive over MTP | **Have** — built against a zūmo XT3, see below |
| Strip shaping points on transfer | **Have** — a checkbox in the Transfer window; each stop carries the whole road to the next, so the line is unchanged |
| Simplify tracks to a device point limit | **Have** — on by default in the Transfer window, to Garmin's 10,000; and by hand from the track's menu |
| Track beside an off-road route | **Have** — on by default in the Transfer window: an Adventure or Direct route goes with a track of its planned line, because the unit re-routes on its own map and moves a trail it lacks onto pavement. Not yet measured on the zūmo |
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

**Update, 2026-09-23:** `GDBReader` reads the format through 1.9, which is
what MapSource wrote, what BaseCamp's Export writes as "version 3", and
what GPSBabel writes: waypoints with symbol and notes, routes with their
via points, hidden turn points as shaping points and the road between
them as leg geometry, tracks with times and elevation, colours, and the
auto-route settings as our preferences. Written from Herbert Oppmann's
2024 notes on the format, checked against MapSource's own files from the
GPSBabel repository, and imported through the same door as GPX, decided
by the file's signature. The one thing GPSBabel never writes is the road
shape, so the geometry test is a hand-built record, and the real one is a
BaseCamp 4.7.5 export of a route it calculated on City Navigator, Santa
Clara to Reno: 1,083 route points, the same road as GPSBabel's decode
vertex for vertex, 343 miles. The 1,081 turn points BaseCamp places fold
into the road on import, as BaseCamp's own GPX export folds them, rather
than becoming 1,081 shaping points.

**Update, later the same day:** BaseCamp 4.8 still runs on this Mac
under Rosetta, and its library turned out to be the Windows layout
exactly: `AllData.gdb` in format 1.88 and `FolderData.gfi` beside it,
under `~/Library/Application Support/Garmin/BaseCamp/Database/4.8/`. The
newer layout was corrected against that file byte by byte, where the
notes had it wrong: the autosave keeps the router's turns inside the via
point they follow, each with its class, an eighteen-byte subclass, a leg
time in seconds and the turn instruction as text, and the same road came
out as the export's to a hundredth of a metre. The folder file's items
are the user's lists and its folders group them; BaseCamp's own Unlisted
Data and smart lists stay out. `GFIReader`, and `FileImport` reads the
folder file beside any library. File, Import BaseCamp Library does the
whole thing from where BaseCamp keeps it, without opening BaseCamp.

Still open: whether a shaping point the user placed in BaseCamp can be
told from a turn point in either file; and what BaseCamp's Windows
autosave adds, if anything, that the Mac's does not.

**Backups, 2026-09-27.** BaseCamp's File, Back Up writes a plain zip under
a `.backup` name, holding its Application Support folder as it stands, the
same on the Mac and on Windows; Garmin's forums say so, and renaming one to
`.zip` opens it in Finder. So the library inside is `Database/<version>/
AllData.gdb` with `FolderData.gfi` beside it, and Import reads a backup by
its zip signature, takes the newest version folder, and inflates only those
two files, since a backup can carry photos. `ZipArchive` is the reader,
central directory only, on Apple's Compression. The fixture is built by
hand in that layout from the real Mac autosave; **no backup BaseCamp wrote
has been read yet**, and one should be before this is called verified.

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

**Stage A — a usable planner. Done 2026-09-23.** Route editing: click, drag,
insert, delete, undo. Via versus shaping points, honoured on export. Waypoint
creation and editing. Reverse a route, route from track, track from route.
Lists in the sidebar with drag and drop. Search and sort. *Someone can plan a
ride and hand it to a device.*

**Stage B — migration.** GDB import, and restoring straight from BaseCamp's
own database and backup files. Backup and restore of our own. Rename and
duplicate. Track split, join, filter. Elevation profiles and real statistics.
*At the end of this, a BaseCamp user can move their library across and not
lose anything.* Done 2026-10-05.

**Stage C — the device. Done 2026-10-05.** MTP, the memory card and
mass-storage path, which are the same code and cover every unit with a card
slot, and shaping-point stripping and track simplification on the way out.
*Swiftcamp replaces BaseCamp.*

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
- **Address search needs a geocoder.** Settled: our own index of places,
  streets and addresses on the CDN, with the US Census geocoder only for
  what it lacks. `docs/data-architecture.md` has the four sources.
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
