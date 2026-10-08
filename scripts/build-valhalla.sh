#!/usr/bin/env bash
#
# Builds libvalhalla, the routing engine the macOS target links statically.
#
# There is no Homebrew formula and valhalla-mobile targets iOS and Android
# only, so the Mac links a CMake build. It lives inside the repo at
# Vendor/valhalla, gitignored like the basemap: the source is ~300 MB with
# submodules and the build is larger, and both are reproducible from the
# pinned tag below plus our patches in scripts/.
#
# Run once after cloning, and again after pulling a change to the pin or to
# either patch; it rebuilds only what changed. docs/routing.md has the why
# behind each CMake option and each patch.
#
# Requires: Xcode, and
#   brew install cmake ninja pkgconf boost geos libspatialite \
#                spatialite-tools luajit openssl@3 expat

set -euo pipefail

# The patches were written against this tree. Moving the pin means checking
# they still apply and re-measuring what they fix.
VALHALLA_TAG=3.9.0
VALHALLA_COMMIT=a3a5631c4d243eee9a09241f4ffe6680a67dd55a

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Vendor/valhalla"
PATCHES=(
  "$ROOT/scripts/valhalla-intersecting-edges.patch"
  "$ROOT/scripts/valhalla-curvature.patch"
)

missing=()
for f in cmake ninja pkgconf boost geos libspatialite \
         spatialite-tools luajit openssl@3 expat; do
  brew list --versions "$f" >/dev/null 2>&1 || missing+=("$f")
done
if ((${#missing[@]})); then
  echo "error: missing Homebrew packages. Install them with:" >&2
  echo "  brew install ${missing[*]}" >&2
  exit 1
fi

if [[ ! -d "$SRC/.git" ]]; then
  echo "cloning valhalla $VALHALLA_TAG into Vendor/valhalla"
  mkdir -p "$ROOT/Vendor"
  git clone --quiet --depth 1 --branch "$VALHALLA_TAG" \
      --recurse-submodules --shallow-submodules \
      https://github.com/valhalla/valhalla.git "$SRC"
fi

head=$(git -C "$SRC" rev-parse HEAD)
if [[ "$head" != "$VALHALLA_COMMIT" ]]; then
  echo "error: Vendor/valhalla is at $head, the pin is $VALHALLA_COMMIT ($VALHALLA_TAG)." >&2
  echo "  Delete Vendor/valhalla and run this again." >&2
  exit 1
fi

# Reapply only when a patch changed, so an unchanged tree keeps its mtimes
# and ninja has nothing to do.
stamp="$SRC/.swiftcamp-patches"
want=$(cat "${PATCHES[@]}" | shasum -a 256 | cut -d' ' -f1)
if [[ "$(cat "$stamp" 2>/dev/null)" != "$want" ]]; then
  echo "applying patches"
  git -C "$SRC" checkout --quiet -- .
  for p in "${PATCHES[@]}"; do
    git -C "$SRC" apply "$p"
  done
  echo "$want" > "$stamp"
fi

# protobuf, abseil and lz4, static and for macOS 14, so the app carries
# them inside rather than loading Homebrew's; see build-deps.sh.
"$ROOT/scripts/build-deps.sh"
DEPS="$ROOT/Vendor/deps"

# Configured afresh whenever the configuration changes. CMake's cache
# remembers every library it found, so a tree configured against
# Homebrew's protobuf keeps linking it after the prefix path changes;
# the cache has to go with the change.
config=(
  -G Ninja -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF -DENABLE_STATIC_LIBRARY_MODULES=ON
  -DENABLE_SERVICES=OFF -DENABLE_PYTHON_BINDINGS=OFF -DENABLE_TESTS=OFF
  -DENABLE_HTTP=ON -DENABLE_GEOTIFF=OFF -DENABLE_CCACHE=OFF
  -DENABLE_TOOLS=ON -DENABLE_DATA_TOOLS=ON -DENABLE_SINGLE_FILES_WERROR=OFF
  # Our own build first, so protobuf, abseil and lz4 come from it; the
  # graph tools still take GEOS, SpatiaLite and the rest from Homebrew,
  # which is fine for programs that only ever run here.
  -DCMAKE_PREFIX_PATH="$DEPS;/opt/homebrew;/opt/homebrew/opt/openssl@3"
  -DProtobuf_PROTOC_EXECUTABLE="$DEPS/bin/protoc"
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DCMAKE_OSX_ARCHITECTURES=arm64
)
configured="$SRC/build/.swiftcamp-config"
if [[ "$(cat "$configured" 2>/dev/null)" != "${config[*]}" ]]; then
  rm -f "$SRC/build/CMakeCache.txt"
  PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" cmake -S "$SRC" -B "$SRC/build" "${config[@]}"
  echo "${config[*]}" > "$configured"
fi

PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" cmake --build "$SRC/build"

echo
ls -lh "$SRC/build/src/libvalhalla.a"
echo "done. Regenerate the project if you have not: xcodegen generate"
