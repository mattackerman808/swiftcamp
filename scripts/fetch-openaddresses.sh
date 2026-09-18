#!/bin/bash
# Fetches the OpenAddresses US collections and the source definitions
# that carry each source's licence and attribution.
#
#   scripts/fetch-openaddresses.sh ~/valhalla-data/oa
#
# Listing the batch API is open; downloading is not. "Authentication
# Required" comes back for every collection and every source output, so a
# free account at https://batch.openaddresses.io is needed, and a token
# from its profile page, read here from $OPENADDRESSES_TOKEN or the file
# ~/.config/swiftcamp/openaddresses-token. The four US collections are
# about 24 GB; the global one is 52 GB and carries nothing we index.
set -euo pipefail
out=${1:?output directory}
token=${OPENADDRESSES_TOKEN:-$(cat ~/.config/swiftcamp/openaddresses-token 2>/dev/null || true)}
[ -n "$token" ] || { echo "no token: set OPENADDRESSES_TOKEN or write ~/.config/swiftcamp/openaddresses-token" >&2; exit 1; }
mkdir -p "$out/collections"

# The collection ids are stable; the names are checked against the API
# so a renumbering fails loudly rather than downloading Canada as Texas.
curl -sf https://batch.openaddresses.io/api/collections > "$out/collections.json"
for name in us-northeast us-south us-west us-midwest; do
    id=$(python3 -c "import json,sys; print(next(c['id'] for c in json.load(open('$out/collections.json')) if c['name']=='$name'))")
    echo "collection $name (id $id)"
    curl -fL --retry 5 --retry-delay 10 -C - -H "Authorization: Bearer $token" \
        -o "$out/collections/$name.zip" "https://batch.openaddresses.io/api/collections/$id/data"
done

# The licences: one JSON per source, addresses layer, `license` with
# `share-alike`, `attribution` and `url`. Only the US tree is checked out.
if [ ! -d "$out/sources/sources/us" ]; then
    git clone -q --depth 1 --filter=blob:none --sparse https://github.com/openaddresses/openaddresses.git "$out/sources"
    (cd "$out/sources" && git sparse-checkout set sources/us)
fi
ls -la "$out/collections"
