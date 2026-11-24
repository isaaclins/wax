"""
Tests for screenshot mode's `--long-playlist N` (#473).

#473 asks for the resize timing on a big playlist page in Spotify mode, but the sample library's
biggest playlist has 13 songs, so a Release build could only be timed on small pages. With
`scripts/screenshots.sh start --release --long-playlist 1000` the stand-in serves a playlist
"Long Mix" of 1000 songs. These tests start the stand-in on a two-song library (from a filled
cache, so nothing goes to the network) and read the playlist the way the app does: from the
playlist list, then page by page through each page's `next` link (while `next` was always empty,
the app loaded only the first 50 songs).

Run from the repository root:  python3 -m unittest discover -s scripts/tests
"""
import json
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MOCK = ROOT / "scripts" / "screenshot-mode" / "mock_spotify.py"

LIBRARY = {
    "user": "Sample",
    "nowPlaying": "One",
    "tracks": [["Artist A", "One"], ["Artist B", "Two"]],
    "playlists": [{"name": "Short", "tracks": ["One", "Two"]}],
}
CACHE = {
    "Artist A - One": {"requested": "One", "artist": "Artist A", "title": "One", "album": "First",
                       "ms": 200000, "year": "2020", "artwork": "https://example.invalid/a.jpg"},
    "Artist B - Two": {"requested": "Two", "artist": "Artist B", "title": "Two", "album": "Second",
                       "ms": 210000, "year": "2021", "artwork": "https://example.invalid/b.jpg"},
}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class MockServer:
    def __init__(self, *extra):
        self.dir = tempfile.TemporaryDirectory()
        library = Path(self.dir.name) / "library.json"
        cache = Path(self.dir.name) / "cache.json"
        library.write_text(json.dumps(LIBRARY))
        cache.write_text(json.dumps(CACHE))
        self.base = f"http://127.0.0.1:{free_port()}"
        self.process = subprocess.Popen(
            [sys.executable, "-I", str(MOCK), "--port", self.base.rsplit(":", 1)[1],
             "--library", str(library), "--cache", str(cache), *extra],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 20
        while True:
            try:
                self.get("/health")
                break
            except OSError:
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.close()
                    raise RuntimeError("the stand-in did not start: " + self.process.stderr.read().decode())
                time.sleep(0.1)

    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=5) as response:
            return json.load(response) if response.headers.get_content_type() == "application/json" else None

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stderr.close()
        self.dir.cleanup()


class LongPlaylistTests(unittest.TestCase):
    def playlists(self, server):
        return {p["name"]: p for p in server.get("/v1/me/playlists?limit=50")["items"]}

    def test_long_playlist_serves_that_many_different_songs(self):
        server = MockServer("--long-playlist", "1000")
        self.addCleanup(server.close)
        playlist = self.playlists(server)["Long Mix"]
        self.assertEqual(playlist["tracks"]["total"], 1000)
        self.assertEqual(playlist["items"]["total"], 1000)

        # The app asks for the first page and then follows `next` until there is none
        # (SpotifyAPIClient.collectPaged); it never counts offsets itself.
        ids, pages = [], 0
        page = server.get(f"/v1/playlists/{playlist['id']}/items?limit=50")
        while True:
            pages += 1
            self.assertEqual(page["total"], 1000)
            ids += [item["track"]["id"] for item in page["items"]]
            if page["next"] is None:
                break
            self.assertTrue(page["next"].startswith(server.base + "/"), page["next"])
            page = server.get(page["next"][len(server.base):])
        self.assertEqual(pages, 20)
        self.assertEqual(len(ids), 1000, "the app would load only the songs on pages that `next` reaches")
        self.assertEqual(len(set(ids)), 1000, "each song in the long playlist needs its own id, like a real playlist")
        self.assertEqual(playlist["images"][0]["url"], "https://example.invalid/a.jpg")

    def test_without_the_option_the_library_is_unchanged(self):
        server = MockServer()
        self.addCleanup(server.close)
        self.assertEqual(sorted(self.playlists(server)), ["Short"])


if __name__ == "__main__":
    unittest.main()
