#!/usr/bin/env bash
#
# Fetches the bundled low-zoom basemap.
#
# The app ships a world basemap at zoom 0-6 so it has something to draw on
# first paint with no network. It is ~43 MB, which is small enough to bundle
# and far too big to keep in git — every regenerated copy would live in
# history forever. It is also trivially reproducible: PMTiles is a single
# file read by byte range, so cutting the low zooms out of the ~138 GB
# Protomaps planet build costs about five HTTP requests and a second, with
# no need to download the planet.
#
# Run once after cloning, and again whenever you want fresher OSM data.
#
# Requires: pmtiles (brew install pmtiles)

set -euo pipefail

MAXZOOM=6
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Swiftcamp/Resources/basemap"
OUT="$OUT_DIR/world-z6.pmtiles"

if ! command -v pmtiles >/dev/null 2>&1; then
  echo "error: pmtiles not found. Install it with: brew install pmtiles" >&2
  exit 1
fi

# Protomaps keeps roughly a week of daily builds, so today's may not exist
# yet and an old pinned date will 404. Walk back until one answers.
find_build() {
  for offset in 1 2 3 4 5 6 7; do
    local date
    date=$(date -u -v-"${offset}"d +%Y%m%d 2>/dev/null || date -u -d "${offset} days ago" +%Y%m%d)
    local url="https://build.protomaps.com/${date}.pmtiles"
    if curl -sfI --max-time 30 "$url" >/dev/null 2>&1; then
      echo "$url"
      return 0
    fi
  done
  return 1
}

echo "looking for a recent Protomaps planet build..."
if ! URL=$(find_build); then
  echo "error: no build found in the last 7 days at build.protomaps.com" >&2
  exit 1
fi

echo "extracting zoom 0-${MAXZOOM} from ${URL}"
mkdir -p "$OUT_DIR"
pmtiles extract "$URL" "$OUT" --maxzoom="$MAXZOOM"

echo
ls -lh "$OUT"
echo "done. Basemap data © OpenStreetMap contributors, ODbL."
