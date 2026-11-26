"""
Tests that screenshot mode's stand-in remembers Shuffle and Repeat (#677).

It answered every player request with shuffle off and repeat off, so a few seconds after ⌥⌘S or
⌥⌘R the player bar turned them back, and the latency test counted that undo as the next press
showing. Spotify answers with what was set last; the stand-in does too now.

Run from the repository root:  python3 -m unittest discover -s scripts/tests
"""
import unittest
import urllib.request

from test_mock_long_playlist import MockServer


class PlayerTransportTests(unittest.TestCase):
    def put(self, server, path):
        request = urllib.request.Request(server.base + path, data=b"", method="PUT")
        with urllib.request.urlopen(request, timeout=5) as response:
            self.assertEqual(response.status, 204)

    def test_shuffle_and_repeat_stay_as_set(self):
        server = MockServer()
        self.addCleanup(server.close)
        player = server.get("/v1/me/player")
        self.assertFalse(player["shuffle_state"])
        self.assertEqual(player["repeat_state"], "off")

        # The app's own requests (SpotifyPlaybackAPI.setShuffle / setRepeat).
        self.put(server, "/v1/me/player/shuffle?state=true&device_id=spotiglass-screenshot")
        self.put(server, "/v1/me/player/repeat?state=context&device_id=spotiglass-screenshot")
        player = server.get("/v1/me/player")
        self.assertTrue(player["shuffle_state"])
        self.assertEqual(player["repeat_state"], "context")

        self.put(server, "/v1/me/player/shuffle?state=false&device_id=spotiglass-screenshot")
        self.put(server, "/v1/me/player/repeat?state=track&device_id=spotiglass-screenshot")
        player = server.get("/v1/me/player")
        self.assertFalse(player["shuffle_state"])
        self.assertEqual(player["repeat_state"], "track")


if __name__ == "__main__":
    unittest.main()
