#!/usr/bin/env bash
#
# Builds the libraries libvalhalla needs, static, for the oldest macOS the
# app supports, into Vendor/deps. build-valhalla.sh runs it first.
#
# Homebrew's protobuf and abseil were the first choice and cannot ship.
# They are dylibs under /opt/homebrew, so the app ran only on a Mac with
# those exact Homebrew versions installed; and copying them into the app
# would not have helped, because a Homebrew bottle is built for the Mac it
# was poured on: every one of them said minos 27.0, and dyld refuses to
# load a library newer than the running system. The app's own deployment
# target was 14.0 the whole time, and meant nothing. So the three are
# built here from the same releases Homebrew uses, pinned by checksum,
# with the same deployment target as the app, and linked in whole.
#
# Apple Silicon only. An Intel Mac runs BaseCamp natively for as long as
# its macOS does; the Macs losing BaseCamp are the ones losing Rosetta.
#
# Requires: Xcode, and brew install cmake ninja

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/Vendor/deps"
SRC="$DEPS/src"
DEPLOYMENT_TARGET=14.0
ARCH=arm64

# The releases Homebrew's formulae build, with their checksums, so the
# headers Valhalla was written against do not move under it.
ABSEIL_VERSION=20260817.0
ABSEIL_URL=https://github.com/abseil/abseil-cpp/archive/refs/tags/$ABSEIL_VERSION.tar.gz
ABSEIL_SHA=f7e05179df39c45434cad433f5783840bb3788ef322976f9138bc6b72b3a107d
PROTOBUF_VERSION=36.2
PROTOBUF_URL=https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOBUF_VERSION/protobuf-$PROTOBUF_VERSION.tar.gz
PROTOBUF_SHA=3d9642a662d10e68ebae5e53f14dcce5105684212d5078f8e0d47d1ab3ae6b64
LZ4_VERSION=1.10.0
LZ4_URL=https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VERSION.tar.gz
LZ4_SHA=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b

for tool in cmake ninja; do
  command -v "$tool" >/dev/null || { echo "error: $tool is missing: brew install cmake ninja" >&2; exit 1; }
done

# Everything here is rebuilt when any of it changes, since protobuf is
# compiled against this abseil and Valhalla against both.
stamp="$DEPS/.swiftcamp-deps"
want="$ABSEIL_SHA $PROTOBUF_SHA $LZ4_SHA $DEPLOYMENT_TARGET $ARCH"
if [[ "$(cat "$stamp" 2>/dev/null)" == "$want" ]]; then
  echo "dependencies are built: $DEPS"
  exit 0
fi

rm -rf "$DEPS"
mkdir -p "$SRC"

# Downloads a release, checks it, and unpacks it into $SRC/<name>.
fetch() {
  local name=$1 url=$2 sha=$3
  local archive="$SRC/$name.tar.gz"
  echo "fetching $name"
  curl -fsSL "$url" -o "$archive"
  echo "$sha  $archive" | shasum -a 256 -c --quiet
  mkdir -p "$SRC/$name"
  tar -xzf "$archive" -C "$SRC/$name" --strip-components 1
}

common=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$DEPS"
  -DCMAKE_PREFIX_PATH="$DEPS"
  -DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET
  -DCMAKE_OSX_ARCHITECTURES=$ARCH
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_SHARED_LIBS=OFF
  # Homebrew's standard for both, so abseil's choice of std::string_view
  # and friends is the one protobuf and Valhalla see.
  -DCMAKE_CXX_STANDARD=17
  # Nothing from /opt/homebrew may leak in: a stray find_package hit
  # there is exactly the dependency this script exists to remove.
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
)

fetch abseil "$ABSEIL_URL" "$ABSEIL_SHA"
cmake -S "$SRC/abseil" -B "$SRC/abseil/build" "${common[@]}" \
  -DABSL_BUILD_TESTING=OFF -DABSL_PROPAGATE_CXX_STD=ON
cmake --build "$SRC/abseil/build"
cmake --install "$SRC/abseil/build" >/dev/null

fetch protobuf "$PROTOBUF_URL" "$PROTOBUF_SHA"
cmake -S "$SRC/protobuf" -B "$SRC/protobuf/build" "${common[@]}" \
  -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_ABSL_PROVIDER=package \
  -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_INSTALL=ON
cmake --build "$SRC/protobuf/build"
cmake --install "$SRC/protobuf/build" >/dev/null

fetch lz4 "$LZ4_URL" "$LZ4_SHA"
cmake -S "$SRC/lz4/build/cmake" -B "$SRC/lz4/build/cmake/out" "${common[@]}" \
  -DBUILD_STATIC_LIBS=ON -DLZ4_BUILD_CLI=OFF -DLZ4_BUILD_LEGACY_LZ4C=OFF
cmake --build "$SRC/lz4/build/cmake/out"
cmake --install "$SRC/lz4/build/cmake/out" >/dev/null

# A dylib in lib/ would win over the archive at link time and put a path
# into Vendor/ inside the app. There should be none; make sure.
find "$DEPS/lib" -name '*.dylib' -delete
rm -rf "$SRC"
echo "$want" > "$stamp"
echo "dependencies built: $DEPS"
