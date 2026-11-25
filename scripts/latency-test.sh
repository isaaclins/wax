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
# each one is checked against its own time on that runner instead, and fails when it got more than
# twice as slow or stopped showing.
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

python3 - "$REPORT" scripts/latency-baseline.json "$mode" <<'PY'
import json, math, sys
report = json.load(open(sys.argv[1]))
baseline = json.load(open(sys.argv[2]))
mode = sys.argv[3]
# known: over 50 ms on a Mac today, each with the issue that fixes it and its time when listed.
# ci: every interaction's median on GitHub's runner (null: it never shows there). docs/latency.md.
known, ci = baseline["known"], baseline["ci"]
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
    # Same rules as InteractionLatency.Measurement: the worst try is dropped (a try that never
    # showed counts as the worst) and the next one is checked; the median is of the tries that showed.
    tries = times + [math.inf] * m["timedOut"]
    checked = tries[-2] if len(tries) >= 3 else (tries[-1] if tries else None)
    mid = len(times) // 2
    median = None if not times else (times[mid] if len(times) % 2 else (times[mid - 1] + times[mid]) / 2)
    ok = checked is not None and checked <= budget
    entry = known.get(m["id"], {})
    issue = entry.get("issue")
    if mode == "ci":
        if m["id"] not in ci:
            bad, why = True, "not in the ci list yet: add its median from this run"
        elif ci[m["id"]] is None:
            bad, why = False, "never showed here before"
        else:
            ref = ci[m["id"]]
            bad = median is None or median > 2 * ref
            why = f"was {ref:.0f} ms here"
        verdict = "SLOW" if bad else "ok  "
        if bad:
            failed.append(f"{m['id']} ({why})")
    else:
        # A known slow one may not get much slower while it waits for its fix: twice its time
        # when it was listed is a regression, not noise.
        was = entry.get("measuredMs")
        bad = not ok and (issue is None or (was is not None and checked is not None and checked > 2 * was))
        why = f"#{issue}" if issue else ""
        verdict = "ok  " if ok else ("SLOW" if bad else f"#{issue}")
        if bad:
            failed.append(m["id"] + (f" (listed at {was:.0f} ms for #{issue})" if issue else ""))
        if ok and issue:
            fixed.append(f"{m['id']} (#{issue})")
    problems = sorted(set(m.get("problems", [])))
    note = f"  ({m['timedOut']} never showed: {'; '.join(problems)})" if m["timedOut"] else ""
    extra = f"  [{why}]" if mode == "ci" else ""
    print(f"{verdict:<5} {m['id']:<22} median {fmt(median)} ms  checked {fmt(checked)} ms  {m['title']}{extra}{note}")
if fixed:
    print(f"\nnow within {budget:.0f} ms, remove from scripts/latency-baseline.json: {', '.join(fixed)}")
if failed:
    what = "got slower than before on this runner" if mode == "ci" else f"over {budget:.0f} ms"
    print(f"\n{len(failed)} interaction(s) {what}: {', '.join(failed)}")
    sys.exit(1)
if mode == "ci":
    print("\nnothing got slower on this runner; the 50 ms check is scripts/latency-test.sh on a Mac")
else:
    print(f"\nevery interaction within {budget:.0f} ms, apart from the known ones in scripts/latency-baseline.json")
PY
