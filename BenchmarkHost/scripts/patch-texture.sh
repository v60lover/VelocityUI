#!/usr/bin/env bash
# Patches Texture 3.0.3's ASTextLayout.mm so Clang 16's -Wparentheses hard
# error on chained comparisons (A < B < C) doesn't block the build.
#
# Xcode always resolves and builds a target's package dependencies to
# completion before running that target's own preBuildScripts, so a
# preBuildScript on BenchmarkHost can never run early enough to patch
# Texture before AsyncDisplayKit compiles. This script must therefore run
# as a standalone step between package resolution and the actual build,
# against the same -derivedDataPath used for both.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST_DIR="$REPO_ROOT/BenchmarkHost"
PROJ="$HOST_DIR/BenchmarkHost.xcodeproj"
SCHEME="BenchmarkHost"

DD="${1:-$HOST_DIR/build/DerivedData}"

xcodebuild -resolvePackageDependencies \
  -project "$PROJ" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DD"

# SourcePackages/checkouts lives directly under the DerivedData <proj>-<hash>
# dir, one level below Build/Products — no /../ needed to reach it.
TEXTURE_MM="$DD/SourcePackages/checkouts/Texture/Source/TextExperiment/Component/ASTextLayout.mm"

if [ ! -f "$TEXTURE_MM" ]; then
  echo "error: $TEXTURE_MM not found after package resolution — Texture checkout is missing or moved" >&2
  exit 1
fi

# Guards against re-patching an already-patched checkout (warm DerivedData
# reused across invocations) and against a future Texture release that has
# already fixed the chained comparison upstream.
if grep -q 'point\.y) < fabs(right' "$TEXTURE_MM"; then
  sed -i '' 's/= fabs(left - point\.y) < fabs(right - point\.y) < /= (fabs(left - point.y) < fabs(right - point.y)) < /g' "$TEXTURE_MM"
  sed -i '' 's/= fabs(left - point\.x) < fabs(right - point\.x) < /= (fabs(left - point.x) < fabs(right - point.x)) < /g' "$TEXTURE_MM"
fi
