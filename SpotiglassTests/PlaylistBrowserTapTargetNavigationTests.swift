import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserTapTargetNavigationTests: XCTestCase {
    func testOpenArtistWithIDSkipsSearch() async {
        var selected: (String, BrowserNavigationOrigin, String?)?
        await PlaylistBrowserTapTargetNavigation.openArtist(
            ArtistTapTarget(id: "artist-1", name: "Artist"),
            origin: .extend,
            selectArtist: { id, origin, name in selected = (id, origin, name) },
            resolveArtistID: { _ in
                XCTFail("search should not run")
                return nil
            },
            showFailure: { XCTFail("unexpected failure \($0.string)") }
        )
        XCTAssertEqual(selected?.0, "artist-1")
        XCTAssertEqual(selected?.2, "Artist")
    }

    func testOpenArtistResolvesName() async {
        var selectedID: String?
        await PlaylistBrowserTapTargetNavigation.openArtist(
            ArtistTapTarget(id: nil, name: "Taylor"),
            origin: .reset,
            selectArtist: { id, _, _ in selectedID = id },
            resolveArtistID: { name in
                XCTAssertEqual(name, "Taylor")
                return "resolved"
            },
            showFailure: { XCTFail("unexpected failure \($0.string)") }
        )
        XCTAssertEqual(selectedID, "resolved")
    }

    func testOpenAlbumWithIDSkipsSearch() async {
        var selected: (String, String, String, URL?, BrowserNavigationOrigin)?
        let art = URL(string: "https://example.com/a.png")
        await PlaylistBrowserTapTargetNavigation.openAlbum(
            AlbumTapTarget(id: "alb-1", name: "Album"),
            artistSubtitle: "Artist",
            artworkURL: art,
            origin: .extend,
            selectAlbum: { id, title, subtitle, artwork, origin in
                selected = (id, title, subtitle, artwork, origin)
            },
            resolveAlbumID: { _, _ in
                XCTFail("search should not run")
                return nil
            },
            showFailure: { XCTFail("unexpected failure \($0.string)") }
        )
        XCTAssertEqual(selected?.0, "alb-1")
        XCTAssertEqual(selected?.3, art)
    }

    func testOpenAlbumResolvesName() async {
        var selectedID: String?
        await PlaylistBrowserTapTargetNavigation.openAlbum(
            AlbumTapTarget(id: nil, name: "Midnights"),
            artistSubtitle: "Taylor Swift",
            artworkURL: nil,
            origin: .reset,
            selectAlbum: { id, _, _, _, _ in selectedID = id },
            resolveAlbumID: { name, hint in
                XCTAssertEqual(name, "Midnights")
                XCTAssertEqual(hint, "Taylor Swift")
                return "alb-resolved"
            },
            showFailure: { XCTFail("unexpected failure \($0.string)") }
        )
        XCTAssertEqual(selectedID, "alb-resolved")
    }

    /// A lookup that failed used to leave the tap doing nothing at all (#595).
    func testOpenArtistSaysSoWhenTheLookupFails() async {
        var shown: String?
        var selected = false
        await PlaylistBrowserTapTargetNavigation.openArtist(
            ArtistTapTarget(id: nil, name: "Taylor"),
            origin: .reset,
            selectArtist: { _, _, _ in selected = true },
            resolveArtistID: { _ in throw URLError(.notConnectedToInternet) },
            showFailure: { shown = $0.string }
        )
        XCTAssertFalse(selected)
        XCTAssertEqual(shown, SpotiglassL10n.format("browser.tapTarget.openFailed", "Taylor"))
    }

    func testOpenAlbumSaysSoWhenTheLookupFails() async {
        var shown: String?
        await PlaylistBrowserTapTargetNavigation.openAlbum(
            AlbumTapTarget(id: nil, name: "Midnights"),
            artistSubtitle: "Taylor Swift",
            artworkURL: nil,
            origin: .reset,
            selectAlbum: { _, _, _, _, _ in XCTFail("nothing to open") },
            resolveAlbumID: { _, _ in throw URLError(.timedOut) },
            showFailure: { shown = $0.string }
        )
        XCTAssertEqual(shown, SpotiglassL10n.format("browser.tapTarget.openFailed", "Midnights"))
    }

    func testACancelledLookupStaysQuiet() async {
        await PlaylistBrowserTapTargetNavigation.openArtist(
            ArtistTapTarget(id: nil, name: "Taylor"),
            origin: .reset,
            selectArtist: { _, _, _ in XCTFail("nothing to open") },
            resolveArtistID: { _ in throw CancellationError() },
            showFailure: { XCTFail("a cancelled lookup said \($0.string)") }
        )
    }
}
