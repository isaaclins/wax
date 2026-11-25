#!/usr/bin/env python3
"""
Decides whether a latency report passes (#656). scripts/latency-test.sh runs it on the report the
app wrote; the rules are in docs/latency.md.

    python3 scripts/latency_gate.py <report.json> <latency-baseline.json> mac|ci

mac: anything over 50 ms that isn't listed under `known` fails, and so does a listed one that got
     more than twice as slow as when it was listed, or stopped showing.
ci:  GitHub's runner is 2-4 times slower than a Mac, so each interaction is held to its own median
     there (`ci`): it fails when its median doubles, when its checked time is over four times that
     median, or when more than one try never showed.
"""
import json
import math
import sys

BUDGET = 50.0
# A listed one is only "fixed" with some room under the budget, so one slow try can't fail the next
# run (#678).
FIXED_BELOW = 40.0


def median(times):
    """Same as InteractionLatency.Measurement.median: of the tries that showed."""
    times = sorted(times)
    mid = len(times) // 2
    if not times:
        return None
    return times[mid] if len(times) % 2 else (times[mid - 1] + times[mid]) / 2


def checked(times, timed_out):
    """Same as InteractionLatency.Measurement.gated: the worst try is dropped (one that never showed
    counts as the worst) and the next one is checked."""
    tries = sorted(times) + [math.inf] * timed_out
    if not tries:
        return None
    return tries[-2] if len(tries) >= 3 else tries[-1]


def judge(report, baseline, mode):
    """Returns (lines to print, what failed, listed ones now within the budget)."""
    known, ci = baseline["known"], baseline["ci"]
    lines = [
        f"Wax {report['appVersion']} ({report['configuration']}), "
        f"one frame = {report['frameMilliseconds']:.1f} ms, included"
    ]
    if report.get("setupFailure"):
        return lines + ["setup failed: " + report["setupFailure"]], ["setup"], []
    if not report["measurements"]:
        return lines + ["nothing was measured"], ["nothing measured"], []

    fmt = lambda v: "     -" if v is None else ("never " if math.isinf(v) else f"{v:6.1f}")
    failed, fixed = [], []
    for m in report["measurements"]:
        mid = median(m["milliseconds"])
        chk = checked(m["milliseconds"], m["timedOut"])
        ok = chk is not None and chk <= BUDGET
        entry = known.get(m["id"], {})
        issue = entry.get("issue")
        if mode == "ci":
            ref = ci.get(m["id"], "missing")
            if ref == "missing":
                why = "not in the ci list yet: add its median from this run"
            elif ref is None:
                why = None
            elif m["timedOut"] > 1:
                why = f"{m['timedOut']} of {m['timedOut'] + len(m['milliseconds'])} tries never showed"
            elif mid > 2 * ref:
                why = f"median over twice its {ref:.0f} ms here"
            elif chk > 4 * ref:
                why = f"checked time over four times its {ref:.0f} ms median here"
            else:
                why = None
            note = "never showed here before" if ref is None else (why or f"was {ref:.0f} ms here")
            verdict = "SLOW" if why else "ok  "
            if why:
                failed.append(f"{m['id']} ({why})")
        else:
            was = entry.get("measuredMs")
            regressed = issue is not None and was is not None and chk is not None and chk > 2 * was
            bad = not ok and (issue is None or regressed)
            verdict = "ok  " if ok else ("SLOW" if bad else f"#{issue}")
            note = None
            if bad:
                failed.append(m["id"] + (f" (listed at {was:.0f} ms for #{issue})" if issue else ""))
            if issue and chk is not None and chk <= FIXED_BELOW:
                fixed.append(f"{m['id']} (#{issue})")
        problems = sorted(set(m.get("problems", [])))
        never = f"  ({m['timedOut']} never showed: {'; '.join(problems)})" if m["timedOut"] else ""
        lines.append(
            f"{verdict:<5} {m['id']:<22} median {fmt(mid)} ms  checked {fmt(chk)} ms  {m['title']}"
            + (f"  [{note}]" if note else "")
            + never
        )

    if fixed:
        lines += ["", f"now under {FIXED_BELOW:.0f} ms, remove from scripts/latency-baseline.json: {', '.join(fixed)}"]
    if failed:
        what = "got slower than before on this runner" if mode == "ci" else f"over {BUDGET:.0f} ms"
        lines += ["", f"{len(failed)} interaction(s) {what}: {', '.join(failed)}"]
    elif mode == "ci":
        lines += ["", "nothing got slower on this runner; the 50 ms check is scripts/latency-test.sh on a Mac"]
    else:
        lines += ["", f"every interaction within {BUDGET:.0f} ms, apart from the known ones in scripts/latency-baseline.json"]
    return lines, failed, fixed


def main(argv):
    report_path, baseline_path, mode = argv[1:4]
    with open(report_path) as f:
        report = json.load(f)
    with open(baseline_path) as f:
        baseline = json.load(f)
    lines, failed, _ = judge(report, baseline, mode)
    print("\n".join(lines))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
