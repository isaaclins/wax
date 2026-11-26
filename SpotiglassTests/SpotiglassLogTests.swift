import XCTest
@testable import Spotiglass

final class SpotiglassLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory) // The folder may never have been created.
    }

    func testInfoAndErrorOnAllCategories() {
        SpotiglassLog.debug(SpotiglassLog.browsing, "browsing debug")
        SpotiglassLog.info(SpotiglassLog.auth, "auth info")
        SpotiglassLog.error(SpotiglassLog.auth, "auth error")
        SpotiglassLog.info(SpotiglassLog.api, "api info")
        SpotiglassLog.error(SpotiglassLog.api, "api error")
        SpotiglassLog.info(SpotiglassLog.playback, "playback info")
        SpotiglassLog.error(SpotiglassLog.playback, "playback error")
        SpotiglassLog.info(SpotiglassLog.browsing, "browsing info")
        SpotiglassLog.error(SpotiglassLog.browsing, "browsing error")
        SpotiglassLog.info(SpotiglassLog.pinning, "pinning info")
        SpotiglassLog.error(SpotiglassLog.pinning, "pinning error")
        SpotiglassLog.info(SpotiglassLog.settings, "settings info")
        SpotiglassLog.error(SpotiglassLog.settings, "settings error")
        SpotiglassLog.info(SpotiglassLog.persistence, "persistence info")
        SpotiglassLog.error(SpotiglassLog.persistence, "persistence error")
    }

    /// `make test` used to rotate the user's real log away and fill it with test noise (#602).
    func testTheTestHostLogsOutsideTheRealLogsFolder() throws {
        let realLogs = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("\(AppMetadata.storageDirectoryName)/Logs", isDirectory: true)
        XCTAssertTrue(AppMetadata.isRunningUnitTests)
        let url = try XCTUnwrap(SpotiglassLog.logFileURL, "The test host must still have a log file to write to.")
        XCTAssertFalse(
            url.standardizedFileURL.path.hasPrefix(realLogs.standardizedFileURL.path),
            "\(url.path) is in the real Logs folder"
        )
    }

    func testFoldersOfFinishedTestRunsAreRemovedAndRunningOnesKept() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["SpotiglassTestLogs-111", "SpotiglassTestLogs-222", "SomethingElse-111"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }

        SpotiglassLog.removeFinishedTestLogFolders(in: directory, isRunning: { $0 == 222 })

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["SomethingElse-111", "SpotiglassTestLogs-222"])
    }

    func testAFullFileMovesToTheEarlierFileAndTheNewestLinesStay() throws {
        let sink = FileLogSink(directory: { self.directory }, maxBytes: 400)
        sink.boot()
        for index in 0..<40 {
            sink.write(level: "INFO", category: "api", message: "line \(index)")
        }
        sink.flush()

        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        let earlier = try String(contentsOf: directory.appendingPathComponent(FileLogSink.earlierFileName), encoding: .utf8)
        XCTAssertTrue(current.contains("line 39"), "The newest line must be in the current file.")
        XCTAssertTrue(current.contains("earlier lines in \(FileLogSink.earlierFileName)"))
        for file in [FileLogSink.currentFileName, FileLogSink.earlierFileName] {
            let size = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)[.size] as? UInt64
            )
            XCTAssertLessThanOrEqual(size, 400, "\(file) grew past the cap")
        }
        XCTAssertFalse(earlier.isEmpty)
    }

    /// A long session's earlier part used to be deleted at the next launch, so the lines before
    /// its last file were gone from the report.
    func testARelaunchKeepsTheFirstPartOfALongPreviousSession() throws {
        let first = FileLogSink(directory: { self.directory }, maxBytes: 400)
        first.boot()
        first.write(level: "ERROR", category: "auth", message: "start of a long session", synchronously: true)
        for index in 0..<40 {
            first.write(level: "INFO", category: "api", message: "line \(index)")
        }
        first.flush()

        let second = FileLogSink(directory: { self.directory }, maxBytes: 400)
        second.boot()
        second.flush()

        let previous = try String(contentsOf: directory.appendingPathComponent(FileLogSink.previousFileName), encoding: .utf8)
        let previousEarlier = try String(
            contentsOf: directory.appendingPathComponent(FileLogSink.previousEarlierFileName), encoding: .utf8
        )
        XCTAssertTrue(previous.contains("line 39"))
        XCTAssertFalse(previousEarlier.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(FileLogSink.earlierFileName).path),
            "The new session starts without an earlier part"
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertLessThanOrEqual(names.count, 4)
    }

    func testANewLaunchKeepsThePreviousSessionsLines() throws {
        let first = FileLogSink(directory: { self.directory })
        first.boot()
        first.write(level: "ERROR", category: "auth", message: "first session line", synchronously: true)

        let second = FileLogSink(directory: { self.directory })
        second.boot()
        second.flush()

        let previous = try String(contentsOf: directory.appendingPathComponent(FileLogSink.previousFileName), encoding: .utf8)
        XCTAssertTrue(previous.contains("first session line"))
        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        XCTAssertFalse(current.contains("first session line"))
    }

    /// A failed rotation used to fall through to `createFile`, which emptied the very file it
    /// meant to keep (#602).
    func testAFailedRotationKeepsThePreviousSessionsLines() throws {
        let first = FileLogSink(directory: { self.directory })
        first.boot()
        first.write(level: "ERROR", category: "auth", message: "evidence from the crashed session", synchronously: true)

        struct MoveRefused: Error {}
        let second = FileLogSink(directory: { self.directory }, moveItem: { _, _ in throw MoveRefused() })
        second.boot()
        second.write(level: "INFO", category: "api", message: "new session line")
        second.flush()

        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        XCTAssertTrue(current.contains("evidence from the crashed session"))
        XCTAssertTrue(current.contains("Could not move the previous session's log aside"))
        XCTAssertTrue(current.contains("new session line"))
    }

    /// When the session appends to the previous session's file and that file later fills up
    /// and can't be moved either, starting it over would empty the previous session's lines.
    func testAFullFileHoldingThePreviousSessionIsNeverEmptied() throws {
        let first = FileLogSink(directory: { self.directory })
        first.boot()
        first.write(level: "ERROR", category: "auth", message: "evidence from the crashed session", synchronously: true)

        struct MoveRefused: Error {}
        let second = FileLogSink(directory: { self.directory }, maxBytes: 600, moveItem: { _, _ in throw MoveRefused() })
        second.boot()
        for index in 0..<40 {
            second.write(level: "INFO", category: "api", message: "line \(index)")
        }
        second.flush()

        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        XCTAssertTrue(current.contains("evidence from the crashed session"))
        XCTAssertTrue(current.contains("the rest of this session is in Console only"))
        XCTAssertFalse(current.contains("line 39"), "The file must stop growing once it is full")
    }

    func testAnUnusableFolderLeavesNoFileAndDoesNotCrash() {
        struct NoFolder: Error {}
        let sink = FileLogSink(directory: { throw NoFolder() })
        sink.boot()
        sink.write(level: "ERROR", category: "auth", message: "dropped", synchronously: true)
        sink.flush()
        XCTAssertNil(sink.fileURL)
    }

    /// An error line is in the file the moment `error` returns, so a crash right after can't lose it.
    func testAnErrorLineIsInTheFileWhenTheCallReturns() throws {
        let sink = FileLogSink(directory: { self.directory })
        sink.boot()
        sink.write(level: "ERROR", category: "playback", message: "last words", synchronously: true)
        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        XCTAssertTrue(current.contains("last words"))
    }

    // MARK: - The copy for a bug report (#603)

    /// Lines as a real session writes them: a palette search, a play from a playlist on Apple
    /// Music, a Spotify Connect transfer, a failed request whose URL carries the search and the
    /// user, a click on a song row, a key typed into the search field and an error from outside
    /// with a line break in it.
    func testTheBugReportCopyLeavesOutWhatIsPersonalAndKeepsWhatExplainsAFailure() throws {
        let sink = FileLogSink(directory: { self.directory })
        sink.boot()
        let deviceID = "8e1b2a6f0c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f"
        let lines: [(String, String, String)] = [
            ("INFO", "api", "palette search \(SpotiglassLog.personal("tame impala let it happen")) provider 412ms"),
            ("INFO", "playback", "playFromPlaylist entry clickedURI=applemusic:song:4651336237147474264 playlistID=-1718416633700638354 playableCount=440 currentURI=<nil> hasTransferred=false"),
            ("INFO", "playback", "send setQueue entries=440 startingAt=entry 69022FF1-C55C-4807-9D44-AB5C2C770DCD"),
            ("INFO", "playback", "player current entry -> b7aXaLAhy::5GlvfRUeI \(AppleMusicPlayerStateObserver.songName(title: "Eventually", artist: "Tame Impala")) (position 9 of 440): after play (0.28 s after the last command)"),
            ("INFO", "playback", "performTransfer deviceID=\(deviceID) play=true origin=palette"),
            ("INFO", "playback", "play(uri:) entry uri=spotify:track:6rqhFgbbKwnb9MLmUQDhG6 deviceID=\(deviceID)"),
            ("ERROR", "api", "Spotify API failure: GET https://api.spotify.com/v1/search?q=tame%20impala&type=track HTTP 401, headers and body: \(SpotiglassLog.personal("Response body:\n{\"error\":{\"status\":401,\"message\":\"The access token expired\"}}"))"),
            ("ERROR", "api", "Spotify GET /v1/users/isaac.lins/playlists failed: NSURLErrorDomain -1009: The Internet connection appears to be offline."),
            ("INFO", "interaction", "#12 click in window “Wax” row 3 of 40 on cell “Let It Happen” in row; first frame after 6.1 ms"),
            ("INFO", "interaction", "#13 key T in window “Wax” on focus NSTextView; first frame after 4.0 ms"),
            ("INFO", "interaction", "#15 key ⇧Q in window “Wax” on focus NSTextView; first frame after 3.9 ms"),
            ("INFO", "interaction", "#16 key SS in window “Wax” on focus NSTextView; first frame after 3.7 ms"),
            ("INFO", "interaction", "#17 key ↓ in window “Wax” on focus NSTableView; first frame after 2.1 ms"),
            ("INFO", "interaction", "#18 key Return in window “Wax” on focus NSTableView; first frame after 2.4 ms"),
            ("INFO", "interaction", "#19 key in a password field in window “Wax”; first frame after 2.2 ms"),
            ("INFO", "interaction", "#20 key ⇧Tab in window “Wax” on focus NSTableView; first frame after 2.0 ms"),
            ("INFO", "interaction", "#21 key ⇧↓ in window “Wax” on focus NSTableView; first frame after 2.3 ms"),
            ("INFO", "interaction", "#22 key key 53 in window “Wax”; first frame after 2.5 ms"),
            ("INFO", "interaction", "#14 shortcut ⌘K in window “Wax” on button “Next”; first frame after 3.2 ms"),
            ("INFO", "persistence", "Cache folder /Users/isaac/Library/Caches/Spotiglass unreadable"),
            ("INFO", "calls", "→ #6 HTTP GET https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/da/8b/77/da8b77aa/20UMGIM03371.rgb.jpg/640x640bb.jpg"),
            ("INFO", "calls", "← #6 HTTP GET https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/da/8b/77/da8b77aa/20UMGIM03371.rgb.jpg/640x640bb.jpg done after 78.3 ms: status 200, 114795 bytes"),
            ("ERROR", "auth", "Sign-in failed: access_denied\n2026-11-25T16:00:00.000Z [INFO] [auth] Signed in"),
            ("INFO", "calls", "→ #7 MusicKit album search for a pin (\(SpotiglassLog.personal("Currents")) / \(SpotiglassLog.personal("Tame Impala")))"),
            ("INFO", "calls", "→ #8 MusicKit autoplay artist search (\(SpotiglassLog.personal("Pond")))"),
            ("INFO", "calls", "← #9 MusicKit catalog artist 909253 top songs done after 120.4 ms"),
        ]
        for (level, category, message) in lines {
            sink.write(level: level, category: category, message: message, synchronously: true)
        }
        let full = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        // The log on the Mac keeps everything (#734).
        XCTAssertTrue(full.contains("tame impala let it happen"))
        XCTAssertTrue(full.contains("4651336237147474264"))
        // An outside text with a newline stays on its own line and can't fake one.
        XCTAssertFalse(full.contains("\n2026-11-25T16:00:00.000Z [INFO] [auth] Signed in"))
        XCTAssertTrue(full.contains("access_denied\\n2026-11-25T16:00:00.000Z"))
        // Nor with a line separator or a character that turns the text around.
        XCTAssertEqual(FileLogSink.oneLine("a\u{2028}b\u{202E}c"), "a\\u{2028}b\\u{202e}c")

        let destination = directory.appendingPathComponent("report.txt")
        try BugReportLogCopy.write(from: directory, to: destination, keeping: ["Wax", "Next"])
        let copy = try String(contentsOf: destination, encoding: .utf8)

        for personal in [
            "tame impala", "tame%20impala", "Let It Happen", "isaac.lins", "/Users/isaac/",
            "4651336237147474264", "1718416633700638354", "69022FF1-C55C-4807-9D44-AB5C2C770DCD",
            "b7aXaLAhy::5GlvfRUeI", deviceID, "6rqhFgbbKwnb9MLmUQDhG6", "The access token expired", "key T", "key ⇧Q", "key SS",
            "20UMGIM03371", "Currents", "Tame Impala", "Pond", "909253", "Eventually",
        ] {
            XCTAssertFalse(copy.contains(personal), "\(personal) is in the copy:\n\(copy)")
        }
        for kept in [
            "[ERROR] [api]", "HTTP 401", "NSURLErrorDomain -1009", "provider 412ms", "playableCount=440",
            "position 9 of 440", "first frame after 6.1 ms", "row 3 of 40", "button “Next”", "window “Wax”",
            "shortcut ⌘K", "/v1/search?<query>", "applemusic:song:#", "spotify:track:#", "currentURI=<nil>",
            "/Users/<user>/Library/Caches", "access_denied", "https://is1-ssl.mzstatic.com/#", "status 200, 114795 bytes",
            "album search for a pin (“#", "key ⇧·", "key ↓", "key Return", "key in a password field", "key ⇧Tab", "key ⇧↓", "key key 53", "catalog artist #", "top songs done after 120.4 ms", "” by “#",
        ] {
            XCTAssertTrue(copy.contains(kept), "\(kept) is missing from the copy:\n\(copy)")
        }
        // The same device is the same stand-in in both lines, so the story still reads.
        let standIns = copy.split(separator: "\n").filter { $0.contains("deviceID=") }.compactMap { line in
            line.range(of: #"deviceID=#[0-9a-f]{8}"#, options: .regularExpression).map { String(line[$0]) }
        }
        XCTAssertEqual(standIns.count, 2)
        XCTAssertEqual(Set(standIns).count, 1)
        let covers = copy.split(separator: "\n").filter { $0.contains("mzstatic") }.compactMap { line in
            line.range(of: #"mzstatic\.com/#[0-9a-f]{8}"#, options: .regularExpression).map { String(line[$0]) }
        }
        XCTAssertEqual(covers.count, 2)
        XCTAssertEqual(Set(covers).count, 1)
    }

    /// The first copy after an update holds the previous session, written by a build that put
    /// these names in the log without its quotes.
    func testTheCopyReplacesNamesThatOlderBuildsWroteWithoutQuotes() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = [
            "2026-11-25T15:17:01.000Z [INFO] [api] palette search 'bad bunny' provider 412ms",
            "2026-11-25T15:17:02.000Z [DEBUG] [api] palette search 'bad bunny' answered in part",
            "2026-11-25T15:17:03.000Z [INFO] [playback] player current entry -> b7aXaLAhy::5GlvfRUeI \"Let It Happen\" by Tame Impala (position 9 of 440): after play",
            "2026-11-25T15:17:04.000Z [INFO] [calls] → #7 MusicKit album search for a pin (Currents / Tame Impala) (after interaction #3 click on button “Pin”)",
            "2026-11-25T15:17:05.000Z [INFO] [calls] ← #8 MusicKit autoplay artist search (Pond) done after 120.4 ms",
            "2026-11-25T15:17:06.000Z [INFO] [calls] → #9 MusicKit autoplay artist search (Khruangbin)",
            "2026-11-25T15:17:06.100Z [INFO] [calls] → #10 MusicKit album search for a pin (Lonerism / Tame Impala)",
            "2026-11-25T15:17:08.000Z [ERROR] [performance] MAIN THREAD BLOCKED for 2000.0 ms; calls running: MusicKit album search for a pin (Innerspeaker / Tame Impala) (#10, 1.9 s); MusicKit autoplay artist search (Melody's Echo Chamber) (#9, 2.0 s)",
            "2026-11-25T15:17:09.000Z [INFO] [playback] player status paused -> playing at 0:00.0",
            "2026-11-25T15:17:10.000Z [ERROR] [browsing] Looking up \"Mystery Playlist\" to open it failed: NSURLErrorDomain -1009",
        ]
        try Data((older.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent(FileLogSink.previousFileName))
        let destination = directory.appendingPathComponent("report.txt")
        try BugReportLogCopy.write(from: directory, to: destination, keeping: ["Pin"])
        let copy = try String(contentsOf: destination, encoding: .utf8)
        for personal in [
            "bad bunny", "Let It Happen", "Tame Impala", "Currents", "Pond", "Khruangbin", "Lonerism", "Innerspeaker", "Melody's Echo Chamber", "Mystery Playlist",
        ] {
            XCTAssertFalse(copy.contains(personal), "\(personal) is in the copy:\n\(copy)")
        }
        for kept in [
            "provider 412ms", "answered in part", "(position 9 of 440): after play", "button “Pin”", "done after 120.4 ms",
            "(#10, 1.9 s); MusicKit autoplay artist search (“#", "(#9, 2.0 s)", "player status paused -> playing", "to open it failed: NSURLErrorDomain -1009",
        ] {
            XCTAssertTrue(copy.contains(kept), "\(kept) is missing from the copy:\n\(copy)")
        }
    }

    func testTheCopyTakesThePreviousSessionFirst() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in [
            (FileLogSink.currentFileName, "this session\n"),
            (FileLogSink.previousFileName, "previous session\n"),
            (FileLogSink.previousEarlierFileName, "previous session, first part\n"),
        ] {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        let destination = directory.appendingPathComponent("report.txt")
        try BugReportLogCopy.write(from: directory, to: destination, keeping: [])
        let copy = try String(contentsOf: destination, encoding: .utf8)
        let order = ["previous session, first part", "previous session\n", "this session"].map { copy.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains(nil), copy)
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted())
    }

    /// Controls keep their names in the copy because they are Wax's own words.
    func testTheAppsOwnWordsAreKept() {
        let words = BugReportLogCopy.appWords(bundle: Bundle(for: FileLogSink.self))
        XCTAssertTrue(words.contains("Reveal in Finder"), "\(words.count) words")
    }
}

/// Reads the app's log file for tests that check a failure reached it.
enum SpotiglassLogReader {
    static func lines(containing marker: String) throws -> [String] {
        SpotiglassLog.flush()
        let url = try XCTUnwrap(SpotiglassLog.logFileURL)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(marker) }
    }
}
