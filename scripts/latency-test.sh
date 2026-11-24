#!/usr/bin/env bash
# Times every interaction in a Release build and fails when one takes more than 50 ms (#656).
#
#   scripts/latency-test.sh [--only id,id] [--light]   build Release, time on the sample library, report
#
# Runs the real app in screenshot mode (no account, no audio) with WAX_LATENCY_PROBE set: the app
# presses each shortcut and clicks each control itself, times it from the input to the first frame
# that shows it, writes build/latency/report.json and quits. The list of interactions and what each
# time means are in docs/latency.md.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="$PWD/build/latency"
REPORT="$OUT/report.json"
mkdir -p "$OUT"
rm -f "$REPORT"

if [ "${1:-}" = "--only" ]; then export WAX_LATENCY_ONLY="$2"; shift 2; fi

cleanup() { scripts/screenshots.sh stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

# A playlist long enough that scrolling it is real work (#655).
WAX_LATENCY_PROBE="$REPORT" scripts/screenshots.sh start --release --long-playlist 1000 "$@"

pid="$(pgrep -f "$PWD/build/screenshot-mode/Wax.app/Contents/MacOS/Wax" | head -1 || true)"
echo "==> measuring (the app quits by itself when it's done)"
for _ in $(seq 1 600); do
    [ -f "$REPORT" ] && break
    [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && break
    sleep 1
done
[ -f "$REPORT" ] || { echo "latency: the app wrote no report" >&2; exit 1; }

python3 - "$REPORT" scripts/latency-baseline.json <<'PY'
import json, math, sys
report = json.load(open(sys.argv[1]))
# Interactions that are over 50 ms today, each with the issue that fixes it. They are reported but
# don't fail the run; an entry is removed once its fix lands. Anything not listed must be within
# 50 ms. See docs/latency.md.
known = json.load(open(sys.argv[2]))["known"]
budget = 50.0
print(f"Wax {report['appVersion']} ({report['configuration']}), one frame = {report['frameMilliseconds']:.1f} ms, included")
if report.get("setupFailure"):
    print("setup failed:", report["setupFailure"])
    sys.exit(1)
if not report["measurements"]:
    print("nothing was measured")
    sys.exit(1)
fmt = lambda v: "     -" if v is None else ("never " if math.isinf(v) else f"{v:6.1f}")
failed, fixed = [], []
for m in report["measurements"]:
    times = sorted(m["milliseconds"])
    # Same rule as InteractionLatency.Measurement.gated: the worst try is dropped (a try that never
    # showed counts as the worst), the next one is checked.
    tries = times + [math.inf] * m["timedOut"]
    checked = tries[-2] if len(tries) >= 3 else (tries[-1] if tries else None)
    ok = checked is not None and checked <= budget
    median = times[len(times) // 2] if times else None
    issue = known.get(m["id"], {}).get("issue")
    verdict = "ok  " if ok else (f"#{issue}" if issue else "SLOW")
    problems = sorted(set(m.get("problems", [])))
    note = f"  ({m['timedOut']} never showed: {'; '.join(problems)})" if m["timedOut"] else ""
    print(f"{verdict:<5} {m['id']:<22} median {fmt(median)} ms  checked {fmt(checked)} ms  {m['title']}{note}")
    if not ok and not issue:
        failed.append(m["id"])
    if ok and issue:
        fixed.append(f"{m['id']} (#{issue})")
if fixed:
    print(f"\nnow within {budget:.0f} ms, remove from scripts/latency-baseline.json: {', '.join(fixed)}")
if failed:
    print(f"\n{len(failed)} interaction(s) over {budget:.0f} ms: {', '.join(failed)}")
    sys.exit(1)
print(f"\nevery interaction within {budget:.0f} ms, apart from the known ones in scripts/latency-baseline.json")
PY
