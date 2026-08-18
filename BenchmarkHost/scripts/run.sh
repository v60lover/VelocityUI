#!/usr/bin/env bash
# BenchmarkHost run orchestrator.
#
# Iterates the runtime × image-mode × velocity-profile × scenario matrix N times,
# launches BenchmarkHost on a physical device (or simulator) with the right
# launch args, captures the JSON harness report from the console stream, and
# writes one JSON file per (combo, run) to results/<timestamp>/.
#
# Honesty discipline: this script never averages cold + warm, never averages
# across image modes, and never collapses engine cost into a single number.
# That work happens in the reporter (BenchmarkReporter/) — keep it that way.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST_DIR="$REPO_ROOT/BenchmarkHost"
PROJ="$HOST_DIR/BenchmarkHost.xcodeproj"
SCHEME="BenchmarkHost"
BUNDLE_ID="com.velocityui.BenchmarkHost"
SCRIPTS_DIR="$HOST_DIR/scripts"

# Defaults — full matrix.
DEVICE=""
SIM_DEVICE=""
RUNS=5
RUNTIMES="swiftui-lazyvstack,swiftui-list,uicollectionview,texture,velocityui"
MODES="idiomatic,raw"
PROFILES="slow,medium,max"
SCENARIOS="cold,warm,replay"
ITEMS=1000
DURATION=30
STREAM_HOT_RASTERIZE="on,off"
STREAM_RATE=20
STREAM_TEXT_ONLY=0
OUTPUT=""
SKIP_BUILD=0
SKIP_INSTALL=0
SKIP_REPORT=0
QUICK=0
VERBOSE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Target selection (one required):
  --device <id|name>      iOS device identifier or paired name (devicectl)
  --sim <name|udid>       Simulator device name or UDID (uses simctl)

Matrix overrides:
  --quick                 N=3, medium profile only, warm only, idiomatic only
  --runs N                Runs per combo (default 5)
  --runtimes CSV          Comma-separated runtime keys (default: all 5)
  --modes CSV             idiomatic,raw (default: both)
  --profiles CSV          slow,medium,max (default: all)
  --scenarios CSV         cold,warm,replay,stream (default: cold,warm,replay; replay is the
                          Phase 1 contract scenario Q5 gates on — see VelocityUI-ah8.4; stream
                          is the streaming-text scenario — see the "stream" section below)
  --items N               Dataset size (default 1000)
  --duration N            Measurement seconds per run (default 30)

Stream scenario (VelocityUI-xxf7) — include "stream" in --scenarios:
  VelocityUI-only, ignores --runtimes/--modes/--profiles/--items entirely (a single growing
  message, not a scrolled item list). Driven by its own axis instead:
    --stream-hot-rasterize CSV   on,off (default: both) — runs the SAME token stream with
                                 VelocityUI's incremental hot-block rasterizer (VelocityUI-x4q0)
                                 on vs off, so MemoryStats.lateOverEarlyAllocRatio in the two
                                 reports can be compared directly (ON should read ~flat, OFF
                                 should grow — mirrors spike 6qd's late/early ratio).
    --stream-rate N              tokens/second StreamDriver appends at (default 20)
    --stream-text-only           No AsyncImageNode/SpacerNode interleaved (no network/decode
                                 dependency) — the acceptance-criteria run does NOT set this;
                                 use it for a quick device sanity pass or to isolate pure
                                 text-rasterizer cost from image-decode noise.
  Writes stream__hot-<on|off>__<run>.json, independent of the runtime/mode/profile matrix above.

Output:
  --output DIR            Results directory (default: results/<UTC-timestamp>)

Skips (for iteration during dev):
  --skip-build            Reuse last build
  --skip-install          Skip app install
  --skip-report           Don't run the reporter at the end

Misc:
  -v, --verbose           Verbose xcodebuild / devicectl output
  -h, --help              This help

Examples:
  # Smoke run on iPhone Catmood
  $(basename "$0") --device "iPhone Catmood" --quick

  # Full matrix on a connected device
  $(basename "$0") --device "iPhone Catmood"

  # Quick run on the booted simulator
  $(basename "$0") --sim booted --quick
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --sim) SIM_DEVICE="$2"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --runs) RUNS="$2"; shift 2 ;;
    --runtimes) RUNTIMES="$2"; shift 2 ;;
    --modes) MODES="$2"; shift 2 ;;
    --profiles) PROFILES="$2"; shift 2 ;;
    --scenarios) SCENARIOS="$2"; shift 2 ;;
    --items) ITEMS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --stream-hot-rasterize) STREAM_HOT_RASTERIZE="$2"; shift 2 ;;
    --stream-rate) STREAM_RATE="$2"; shift 2 ;;
    --stream-text-only) STREAM_TEXT_ONLY=1; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --skip-report) SKIP_REPORT=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $QUICK -eq 1 ]]; then
  RUNS=3
  PROFILES="medium"
  SCENARIOS="warm"
  MODES="idiomatic"
fi

if [[ -z "$DEVICE" && -z "$SIM_DEVICE" ]]; then
  echo "error: one of --device or --sim is required" >&2
  usage >&2
  exit 2
fi
if [[ -n "$DEVICE" && -n "$SIM_DEVICE" ]]; then
  echo "error: --device and --sim are mutually exclusive" >&2
  exit 2
fi

USE_SIM=0
if [[ -n "$SIM_DEVICE" ]]; then
  USE_SIM=1
fi

# Output dir — UTC timestamp keeps runs reproducible across timezones.
if [[ -z "$OUTPUT" ]]; then
  STAMP="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
  OUTPUT="$HOST_DIR/results/$STAMP"
fi
mkdir -p "$OUTPUT"
echo "results → $OUTPUT"

# Build directory shared across invocations so --skip-build works.
BUILD_DIR="$HOST_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
vlog() { [[ $VERBOSE -eq 1 ]] && echo "[$(date -u +%H:%M:%S)] $*" || true; }

# ─── Build ───────────────────────────────────────────────────────────────────

build_app() {
  if [[ $SKIP_BUILD -eq 1 ]]; then
    log "skip-build: reusing previous build"
    return 0
  fi

  log "regenerating BenchmarkHost.xcodeproj (xcodegen)…"
  (cd "$HOST_DIR" && xcodegen generate --quiet)

  log "building BenchmarkHost (Release)…"
  local dest
  if [[ $USE_SIM -eq 1 ]]; then
    dest="generic/platform=iOS Simulator"
  else
    dest="generic/platform=iOS"
  fi

  local out_filter='cat'
  [[ $VERBOSE -eq 0 ]] && out_filter='grep -E "(error|warning|BUILD SUCCEEDED|BUILD FAILED)" || true'

  set +e
  xcodebuild \
    -project "$PROJ" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "$dest" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -quiet \
    CODE_SIGNING_ALLOWED=YES \
    build 2>&1 | eval "$out_filter"
  local rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "error: xcodebuild failed (exit $rc)" >&2
    exit $rc
  fi
}

resolve_app_path() {
  local product_dir
  if [[ $USE_SIM -eq 1 ]]; then
    product_dir="$DERIVED_DATA/Build/Products/Release-iphonesimulator"
  else
    product_dir="$DERIVED_DATA/Build/Products/Release-iphoneos"
  fi
  APP_PATH="$product_dir/BenchmarkHost.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: .app not found at $APP_PATH" >&2
    exit 1
  fi
  log "app → $APP_PATH"
}

# ─── Install ─────────────────────────────────────────────────────────────────

install_app() {
  if [[ $SKIP_INSTALL -eq 1 ]]; then
    log "skip-install"
    return 0
  fi

  if [[ $USE_SIM -eq 1 ]]; then
    log "installing on simulator '$SIM_DEVICE'…"
    xcrun simctl boot "$SIM_DEVICE" 2>/dev/null || true
    xcrun simctl install "$SIM_DEVICE" "$APP_PATH"
  else
    log "installing on device '$DEVICE'…"
    xcrun devicectl device install app --device "$DEVICE" "$APP_PATH" >/dev/null
  fi
}

# ─── Launch one combo ────────────────────────────────────────────────────────

# Extracts the BenchmarkReport JSON AppDelegate printed between its delimiters out of $raw into
# $out, and validates it parses. Shared by launch_one and launch_stream_one so the two never
# drift on what counts as a successful capture. Returns nonzero (leaving $raw for inspection) on
# either failure.
extract_report_json() {
  local raw="$1" out="$2"

  awk '
    /<<<BENCHMARK_REPORT_BEGIN>>>/ { capture=1; next }
    /<<<BENCHMARK_REPORT_END>>>/   { capture=0 }
    capture { print }
  ' "$raw" > "$out"

  if [[ ! -s "$out" ]]; then
    echo "  ↳ no JSON captured — raw output at $raw" >&2
    return 1
  fi

  # Basic structural validation — orchestrator must never store unparseable JSON.
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$out" 2>/dev/null; then
    echo "  ↳ JSON parse failed at $out — raw output at $raw" >&2
    return 1
  fi

  rm -f "$raw"
  return 0
}

# Launches the app with given args and writes the extracted JSON to $OUT.
# Returns nonzero if the JSON couldn't be extracted (no exit-cleanup on caller).
launch_one() {
  local runtime="$1" mode="$2" profile="$3" scenario="$4" out="$5"
  local raw="${out}.raw"

  if [[ $USE_SIM -eq 1 ]]; then
    xcrun simctl terminate "$SIM_DEVICE" "$BUNDLE_ID" 2>/dev/null || true
    # simctl launch --console-pty streams stdout until the app exits.
    xcrun simctl launch --console-pty --terminate-running-process \
      "$SIM_DEVICE" "$BUNDLE_ID" \
      --runtime "$runtime" \
      --image-mode "$mode" \
      --velocity-profile "$profile" \
      --scenario "$scenario" \
      --items "$ITEMS" \
      --duration "$DURATION" \
      > "$raw" 2>&1 || true
  else
    # devicectl --console attaches stdout and blocks until the app exits.
    xcrun devicectl device process launch \
      --device "$DEVICE" \
      --console \
      --terminate-existing \
      "$BUNDLE_ID" \
      --runtime "$runtime" \
      --image-mode "$mode" \
      --velocity-profile "$profile" \
      --scenario "$scenario" \
      --items "$ITEMS" \
      --duration "$DURATION" \
      > "$raw" 2>&1 || true
  fi

  extract_report_json "$raw" "$out"
}

# Launches the `stream` scenario with a given --hot-rasterize mode ("on"/"off") and writes the
# extracted JSON to $out. Ignores the runtime/mode/profile/items axes entirely — VelocityUI-xxf7
# is VelocityUI-only, a single growing message, not a scrolled item list. See launch_one for the
# simctl/devicectl split this mirrors.
launch_stream_one() {
  local hot_rasterize="$1" out="$2"
  local raw="${out}.raw"

  # Array (not a string) so an unset --stream-text-only cleanly contributes zero args — avoids
  # the classic "" placeholder arg bug when splicing an optional flag into a fixed argv.
  local extra_args=()
  [[ $STREAM_TEXT_ONLY -eq 1 ]] && extra_args+=(--stream-text-only)

  if [[ $USE_SIM -eq 1 ]]; then
    xcrun simctl terminate "$SIM_DEVICE" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch --console-pty --terminate-running-process \
      "$SIM_DEVICE" "$BUNDLE_ID" \
      --scenario stream \
      --hot-rasterize "$hot_rasterize" \
      --stream-rate "$STREAM_RATE" \
      --duration "$DURATION" \
      ${extra_args[@]+"${extra_args[@]}"} \
      > "$raw" 2>&1 || true
  else
    xcrun devicectl device process launch \
      --device "$DEVICE" \
      --console \
      --terminate-existing \
      "$BUNDLE_ID" \
      --scenario stream \
      --hot-rasterize "$hot_rasterize" \
      --stream-rate "$STREAM_RATE" \
      --duration "$DURATION" \
      ${extra_args[@]+"${extra_args[@]}"} \
      > "$raw" 2>&1 || true
  fi

  extract_report_json "$raw" "$out"
}

# ─── Run matrix ──────────────────────────────────────────────────────────────

IFS=',' read -ra RUNTIME_ARR <<< "$RUNTIMES"
IFS=',' read -ra MODE_ARR <<< "$MODES"
IFS=',' read -ra PROFILE_ARR <<< "$PROFILES"
IFS=',' read -ra SCENARIO_ARR <<< "$SCENARIOS"

# `stream` (VelocityUI-xxf7) doesn't belong in the runtime×mode×profile matrix below — it has its
# own dedicated axis (--stream-hot-rasterize) and ignores runtime/mode/profile/items entirely.
# Split it out here so it's not combined nonsensically with those, then run it separately.
RUN_STREAM=0
MATRIX_SCENARIO_ARR=()
for scenario in "${SCENARIO_ARR[@]}"; do
  if [[ "$scenario" == "stream" ]]; then
    RUN_STREAM=1
  else
    MATRIX_SCENARIO_ARR+=("$scenario")
  fi
done

IFS=',' read -ra STREAM_HOT_RASTERIZE_ARR <<< "$STREAM_HOT_RASTERIZE"

MATRIX_TOTAL=$(( ${#RUNTIME_ARR[@]} * ${#MODE_ARR[@]} * ${#PROFILE_ARR[@]} * ${#MATRIX_SCENARIO_ARR[@]} * RUNS ))
STREAM_TOTAL=$(( RUN_STREAM == 1 ? ${#STREAM_HOT_RASTERIZE_ARR[@]} * RUNS : 0 ))
TOTAL=$(( MATRIX_TOTAL + STREAM_TOTAL ))
log "matrix: ${#RUNTIME_ARR[@]} runtimes × ${#MODE_ARR[@]} modes × ${#PROFILE_ARR[@]} profiles × ${#MATRIX_SCENARIO_ARR[@]} scenarios × $RUNS runs"\
" + stream: $STREAM_TOTAL launches = $TOTAL total"

build_app
resolve_app_path
install_app

FAIL_COUNT=0
DONE=0
START_TS=$(date +%s)

# macOS's system /bin/bash (3.2) throws "unbound variable" under `set -u` when expanding
# "${ARR[@]}" on a genuinely empty array — guard explicitly rather than relying on the modern-
# bash-only empty-array idiom, since MATRIX_SCENARIO_ARR is empty whenever --scenarios is
# "stream" alone.
if [[ ${#MATRIX_SCENARIO_ARR[@]} -gt 0 ]]; then
  for runtime in "${RUNTIME_ARR[@]}"; do
    for mode in "${MODE_ARR[@]}"; do
      for profile in "${PROFILE_ARR[@]}"; do
        for scenario in "${MATRIX_SCENARIO_ARR[@]}"; do
          for ((run=1; run<=RUNS; run++)); do
            DONE=$((DONE + 1))
            out="$OUTPUT/${runtime}__${mode}__${profile}__${scenario}__${run}.json"
            log "[$DONE/$TOTAL] $runtime $mode $profile $scenario run=$run"
            if ! launch_one "$runtime" "$mode" "$profile" "$scenario" "$out"; then
              FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
          done
        done
      done
    done
  done
fi

if [[ $RUN_STREAM -eq 1 ]]; then
  for hot_rasterize in "${STREAM_HOT_RASTERIZE_ARR[@]}"; do
    for ((run=1; run<=RUNS; run++)); do
      DONE=$((DONE + 1))
      out="$OUTPUT/stream__hot-${hot_rasterize}__${run}.json"
      log "[$DONE/$TOTAL] stream hot-rasterize=$hot_rasterize run=$run"
      if ! launch_stream_one "$hot_rasterize" "$out"; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
    done
  done
fi

ELAPSED=$(( $(date +%s) - START_TS ))
log "matrix done in ${ELAPSED}s — $FAIL_COUNT failures"

# ─── Report ──────────────────────────────────────────────────────────────────

# BenchmarkReporter's filename parser expects the runtime__mode__profile__scenario__run shape
# launch_one writes (see Loader.swift) — stream__hot-<on|off>__<run>.json doesn't match it and is
# skipped with a stderr warning, not a crash. Only skip invoking the reporter outright when there
# are ZERO matrix files for it to find at all (a --scenarios stream-only run) — Loader.load()
# throws noReports in that case, which would otherwise fail the whole script via `set -e` even
# though the stream launches above already succeeded.
if [[ $SKIP_REPORT -eq 0 && $MATRIX_TOTAL -gt 0 ]]; then
  log "generating report…"
  REPORTER_DIR="$SCRIPTS_DIR/BenchmarkReporter"
  swift run -c release --package-path "$REPORTER_DIR" BenchmarkReporter "$OUTPUT"
  log "report at $OUTPUT/report.csv + $OUTPUT/report.md"
fi

if [[ $RUN_STREAM -eq 1 ]]; then
  # Surface the frame stats the stream capture ALREADY recorded (BenchmarkReport.frameStats).
  # BenchmarkReporter skips stream__* files, so without this the numbers sit unread inside the
  # JSON — which is exactly why VelocityUI-zgdg/0tbi closed with "no measured numbers anywhere."
  # This is the VelocityUI-zgdg / B1 (VelocityUI-80uh) gate: does the incremental hot-block
  # rasterize fit the frame budget? Headless stream has NO scroll gesture, so this is the
  # drag-FREE compute proxy — per-token rasterize COST is the same with or without a drag; a drag
  # only adds frame-budget contention on top. The end-to-end during-drag hitch still needs the
  # gesture-deferral A/B pass on a hand-dragged device.
  log "stream frame stats (VelocityUI-zgdg / B1 gate — does incremental rasterize fit the frame budget?):"
  printf '  %-30s %8s %8s %8s %9s %10s\n' "file" "p50 ms" "p99 ms" "max ms" "hitch/1k" "late/early"
  for f in "$OUTPUT"/stream__hot-*.json; do
    [[ -e "$f" ]] || continue
    python3 - "$f" <<'PY' || true
import json, os, sys
d = json.load(open(sys.argv[1]))
fs = d["frameStats"]
ratio = d.get("memoryStats", {}).get("lateOverEarlyAllocRatio")
ratio = "n/a" if ratio is None else f"{ratio:.2f}"
print("  %-30s %8.2f %8.2f %8.2f %9.2f %10s" % (
    os.path.basename(sys.argv[1]),
    fs["p50FrameTimeMs"], fs["p99FrameTimeMs"], fs["maxFrameTimeMs"],
    fs["hitchesPerThousand"], ratio))
PY
  done
  log "read: hot-ON p99 well under budget (8.3 ms @120Hz / 16.7 ms @60Hz) => incremental rasterize fits;"\
" compare hot-ON vs hot-OFF p99 to quantify the rasterizer's benefit. Memory side: ON's late/early"\
" alloc ratio should read ~1.0, OFF well above 1.0 (mirrors spike 6qd). Raw JSON at"\
" $OUTPUT/stream__hot-*.json."
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "warning: $FAIL_COUNT runs failed — see $OUTPUT for partial data" >&2
  exit 1
fi
