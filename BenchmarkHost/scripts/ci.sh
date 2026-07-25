#!/usr/bin/env bash
# CI wrapper for BenchmarkHost.
#
# Two modes:
#   smoke (default)  — --quick matrix on the booted simulator. Cheap; runs
#                      on every PR to catch broken plumbing. Numbers from a
#                      simulator are NOT publishable — this is liveness only.
#   full             — full matrix on a connected physical device. Manual
#                      invocation; numbers from here ARE publishable.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/BenchmarkHost/scripts"

MODE="${1:-smoke}"

case "$MODE" in
  smoke)
    # Pick whichever simulator is currently booted. Falls back to a sensible default.
    SIM=$(xcrun simctl list devices booted -j 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; \
            ids=[dev["udid"] for runs in d.values() for dev in runs if dev.get("state")=="Booted"]; \
            print(ids[0] if ids else "")')
    if [[ -z "$SIM" ]]; then
      SIM="iPhone 15"
      xcrun simctl boot "$SIM" 2>/dev/null || true
    fi
    echo "CI smoke on sim: $SIM"
    exec "$SCRIPTS_DIR/run.sh" --sim "$SIM" --quick
    ;;
  full)
    shift || true
    DEVICE="${1:-iPhone Catmood}"
    echo "CI full on device: $DEVICE"
    exec "$SCRIPTS_DIR/run.sh" --device "$DEVICE"
    ;;
  *)
    echo "Usage: $0 [smoke|full [device]]" >&2
    exit 2
    ;;
esac
