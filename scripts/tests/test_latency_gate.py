"""
Tests for the verdicts of scripts/latency_gate.py, which scripts/latency-test.sh and the CI job
"Interaction latency (Release)" run on the app's latency report (#656).

The times are real: the CI runner's run of the job on PR #684, my Mac mini's run of the same probe,
and the play/pause times my work Mac logged before #645 was fixed.

Run from the repository root:  python3 -m unittest discover -s scripts/tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import latency_gate  # noqa: E402


def m(id, times, timed_out=0):
    return {"id": id, "title": id, "milliseconds": times, "timedOut": timed_out}


def report(*measurements):
    return {"appVersion": "0.8.67", "configuration": "Release", "frameMilliseconds": 16.7,
            "setupFailure": None, "measurements": list(measurements)}


BASELINE = {
    "known": {
        "palette.open": {"issue": 671, "measuredMs": 88},
        "playback.toggle.key": {"issue": 678, "measuredMs": 40},
        "playback.next": {"issue": 687, "measuredMs": None},
    },
    "ci": {"playback.toggle.key": 83, "palette.open": 291, "queue.toggle": 279, "playback.next": None},
}

# The CI runner's times on PR #684.
CI_TOGGLE = m("playback.toggle.key", [104, 72, 90, 60, 64, 75, 72, 75])
CI_PALETTE = m("palette.open", [376, 240, 203, 220, 183, 179, 196, 178])
CI_QUEUE = m("queue.toggle", [513, 166, 358, 269, 289, 213, 321, 172])


def verdict(mode, *measurements):
    _, failed, fixed = latency_gate.judge(report(*measurements), BASELINE, mode)
    return failed, fixed


class CIGateTests(unittest.TestCase):
    def test_the_ci_runners_own_times_pass(self):
        self.assertEqual(verdict("ci", CI_TOGGLE, CI_PALETTE, CI_QUEUE), ([], []))

    def test_play_pause_as_slow_as_before_645_fails(self):
        # 50-610 ms per press on a Mac; on the runner, 2-4 times that.
        failed, _ = verdict("ci", m("playback.toggle.key", [180, 1830, 420, 290, 210, 260, 690]))
        self.assertEqual(len(failed), 1)
        self.assertIn("median over twice", failed[0])

    def test_one_press_that_never_shows_is_forgiven_but_not_two(self):
        self.assertEqual(verdict("ci", m("playback.toggle.key", [72, 90, 60, 64, 75, 72, 75], 1))[0], [])
        failed, _ = verdict("ci", m("playback.toggle.key", [72, 90, 60, 64, 75, 72], 2))
        self.assertIn("2 of 8 tries never showed", failed[0])

    def test_showing_once_in_eight_fails(self):
        failed, _ = verdict("ci", m("playback.toggle.key", [70], 7))
        self.assertIn("7 of 8 tries never showed", failed[0])

    def test_a_few_multi_second_tries_fail_even_with_a_fast_median(self):
        failed, _ = verdict("ci", m("palette.open", [190, 200, 210, 220, 230, 2500, 2600, 2700]))
        self.assertIn("checked time over four times", failed[0])

    def test_an_interaction_without_a_ci_time_fails_until_it_has_one(self):
        failed, _ = verdict("ci", m("settings.open", [300] * 8))
        self.assertIn("not in the ci list yet", failed[0])

    def test_one_that_never_showed_on_the_runner_is_only_reported(self):
        self.assertEqual(verdict("ci", m("playback.next", [], 8)), ([], []))


class MacGateTests(unittest.TestCase):
    def test_an_unlisted_interaction_over_50_ms_fails(self):
        failed, _ = verdict("mac", m("queue.toggle", [87, 90, 100, 85, 88, 86, 87, 89]))
        self.assertEqual(failed, ["queue.toggle"])

    def test_a_listed_one_passes_until_it_doubles_or_stops_showing(self):
        self.assertEqual(verdict("mac", m("palette.open", [96, 99, 95, 97, 94, 96, 98, 99]))[0], [])
        self.assertEqual(len(verdict("mac", m("palette.open", [190, 200, 180, 185, 190, 195, 200, 210]))[0]), 1)
        self.assertEqual(len(verdict("mac", m("palette.open", [], 8))[0]), 1)

    def test_listed_play_pause_at_41_ms_is_not_called_fixed_yet(self):
        # My Mac mini's run: within 50 ms, but one click took 58 ms (#678).
        failed, fixed = verdict("mac", m("playback.toggle.key", [43, 38, 42, 40, 50, 40, 43, 41]))
        self.assertEqual((failed, fixed), ([], []))
        _, fixed = verdict("mac", m("playback.toggle.key", [20, 22, 21, 23, 20, 22, 21, 24]))
        self.assertEqual(fixed, ["playback.toggle.key (#678)"])

    def test_the_median_matches_the_apps_report_for_an_even_count(self):
        self.assertEqual(latency_gate.median([10, 40, 20, 30]), 25)

    def test_a_broken_setup_fails(self):
        r = report()
        r["setupFailure"] = "the library never loaded"
        lines, failed, _ = latency_gate.judge(r, BASELINE, "mac")
        self.assertTrue(failed)
        self.assertIn("setup failed: the library never loaded", lines)


if __name__ == "__main__":
    unittest.main()
