#!/usr/bin/env bash
#
# Builds a Valhalla routing graph for a Geofabrik region and packs it as the
# single tar the app streams by byte range, the way it streams the map.
#
#   scripts/build-graph.sh north-america/us us
#   scripts/build-graph.sh north-america/us/colorado colorado
#
# Output is $VALHALLA_DATA/<name>/graph-<name>-<date>.tar, and the last line
# printed is the rclone command that publishes it. The filename carries the
# date on purpose: the app reads the tar by byte range against a cached
# index, and Valhalla refuses a tar whose build id no longer matches what it
# cached, so a graph is published under a new name and never overwritten.
#
# The admin database is the planet-built one; see docs/data-architecture.md
# for why only a planet build gives usable admin data. The timezone database
# must come from this same Valhalla's scripts/valhalla_build_timezones, not
# from an older build: it names zones from the merged "1970" set, and a
# database with a zone this version no longer knows, Pacific/Midway in the
# US extract, aborts the build ten minutes in. Both are build-time inputs
# baked into the tiles and never shipped.
#
#   cd ~/valhalla-data && ~/git/valhalla/scripts/valhalla_build_timezones > timezones.sqlite
#
# Requires: the libvalhalla build in docs/routing.md, python3, curl.

set -euo pipefail

REGION=${1:?geofabrik path, e.g. north-america/us}
NAME=${2:?short name, e.g. us}
DATE=$(date +%Y%m%d)

DATA=${VALHALLA_DATA:-$HOME/valhalla-data}
SRC=${VALHALLA_SRC:-$HOME/git/valhalla}
# The tools can live apart from the source build, so a library rebuild
# cannot replace a binary that is part way through a long graph build.
BIN=${VALHALLA_BIN:-$SRC/build}
ADMIN=${VALHALLA_ADMIN:-$HOME/swiftcamp-build/admins-planet/admin_data/admins.sqlite}
TIMEZONE=${VALHALLA_TIMEZONE:-$DATA/timezones.sqlite}

OUT="$DATA/$NAME"
PBF="$DATA/$NAME-latest.osm.pbf"
TAR="$OUT/graph-$NAME-$DATE.tar"
CONFIG="$OUT/valhalla.json"
mkdir -p "$OUT"

if [ ! -f "$PBF" ]; then
  echo "downloading $REGION"
  curl -sL --retry 5 -C - -o "$PBF" "https://download.geofabrik.de/$REGION-latest.osm.pbf"
fi

python3 "$SRC/scripts/valhalla_build_config" \
  --mjolnir-tile-dir "$OUT/tiles" \
  --mjolnir-tile-extract "$TAR" \
  --mjolnir-timezone "$TIMEZONE" \
  --mjolnir-admin "$ADMIN" > "$CONFIG"

echo "building tiles from $PBF"
"$BIN/valhalla_build_tiles" -c "$CONFIG" "$PBF"

echo "packing $TAR"
"$BIN/valhalla_build_extract" -c "$CONFIG" -O

ls -la "$TAR"
echo
echo "publish with:"
echo "  rclone copy $TAR r2:swiftcamp-tiles/"
