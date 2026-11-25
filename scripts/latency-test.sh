#!/usr/bin/env bash
# Times every interaction in a Release build and fails when one takes more than 50 ms (#656).
#
#   scripts/latency-test.sh [--only id,id] [--light]   build Release, time on the sample library, report
#   scripts/latency-test.sh --ci                         what CI runs: fail when one got slower (below)
#
# Runs the real app in screenshot mode (no account, no audio) with WAX_LATENCY_PROBE set: the app
# presses each shortcut and clicks each control itself, times it from the input to the first frame
# that shows it, writes build/latency/report.json and quits. The list of interactions and what each
# time means are in docs/latency.md.
#
# On a Mac, anything over 50 ms that isn't listed in scripts/latency-baseline.json fails. GitHub's
# macOS runners are 2-4 times slower than a Mac, so no interaction gets near 50 ms there; with --ci
# each one is checked against its own time on that runner instead. The rules are in
# scripts/latency_gate.py.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="$PWD/build/latency"
REPORT="$OUT/report.json"
mkdir -p "$OUT"
rm -f "$REPORT"

start_args=()
mode=mac
while [ $# -gt 0 ]; do
    case "$1" in
        --ci) mode=ci; shift ;;
        --only) export WAX_LATENCY_ONLY="${2:?--only needs a comma-separated list of ids}"; shift 2 ;;
        *) start_args+=("$1"); shift ;;
    esac
done

cleanup() { scripts/screenshots.sh stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

# A playlist long enough that scrolling it is real work (#655).
WAX_LATENCY_PROBE="$REPORT" scripts/screenshots.sh start --release --long-playlist 1000 ${start_args[@]+"${start_args[@]}"}

pid="$(pgrep -f "$PWD/build/screenshot-mode/Wax.app/Contents/MacOS/Wax" | head -1 || true)"
echo "==> measuring (the app quits by itself when it's done)"
for _ in $(seq 1 600); do
    [ -f "$REPORT" ] && break
    [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && break
    sleep 1
done
[ -f "$REPORT" ] || { echo "latency: the app wrote no report" >&2; exit 1; }

python3 scripts/latency_gate.py "$REPORT" scripts/latency-baseline.json "$mode"
