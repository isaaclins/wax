import XCTest
@testable import Spotiglass

/// The playback log's line on how long Apple Music's player took to start or stop (#679). Each
/// test replays what MusicKit's `ApplicationMusicPlayer` reported on a Mac mini M4 (macOS 27,
/// 2026-11-25), read every 5 ms after the command, on an injected clock.
@MainActor
final class AppleMusicSoundWatchTests: XCTestCase {
    /// What the player reports `t` ms after the command.
    private typealias Timeline = (Int) -> AppleMusicSoundWatch.Reading

    private func reading(_ position: TimeInterval, _ entry: String, playing: Bool = true) -> AppleMusicSoundWatch.Reading {
        AppleMusicSoundWatch.Reading(positionSeconds: position, entryID: entry, isPlaying: playing)
    }

    /// Sends `command` at 0 ms and steps the clock 5 ms at a time until the watch reports or
    /// `steps` run out. Returns the lines it logged.
    private func run(
        _ command: String,
        _ wait: AppleMusicSoundWatch.Wait,
        pressedBefore press: Duration? = nil,
        steps: Int = 200,
        _ timeline: @escaping Timeline
    ) async -> [String] {
        let clock = ManualPlaybackClock()
        let start = clock.now
        var lines: [String] = []
        let watch = AppleMusicSoundWatch(
            clock: clock,
            read: { timeline(Int(start.duration(to: clock.now) / .milliseconds(1))) },
            report: { lines.append($0) }
        )
        watch.watch(command, for: wait, sentAt: start, requestedAt: press.map { start.advanced(by: .zero - $0) })
        for _ in 0..<steps where lines.isEmpty {
            guard await clock.waitForSleepers(1) else { break }
            clock.advance(by: AppleMusicSoundWatch.interval)
            await Task.yield()
        }
        return lines
    }

    /// Next: MusicKit keeps the old song, still, for about 85 ms, then switches to the next one at
    /// 0:00 and its position moves 5 ms later (measured: 87-98 ms to a moving position).
    func testNextIsTimedUntilTheNextSongMoves() async {
        let lines = await run("skipToNext", .movesOnAnotherSong, pressedBefore: .milliseconds(3)) { t in
            if t < 85 { return self.reading(41.200, "song-1") }
            if t < 90 { return self.reading(0, "song-2") }
            return self.reading(Double(t - 90) / 1000, "song-2")
        }
        XCTAssertEqual(lines, ["skipToNext: playing 95.0 ms after the command, 98.0 ms after the press"])
    }

    /// A song switch alone doesn't count: the new song has to play (MusicKit shows it paused at
    /// 0:00 before it starts).
    func testANewSongThatHasNotStartedIsNotPlaying() async {
        let lines = await run("skipToPrevious", .movesOnAnotherSong) { t in
            if t < 10 { return self.reading(12.0, "song-2") }
            if t < 40 { return self.reading(0, "song-1", playing: false) }
            return self.reading(Double(t - 40) / 1000, "song-1")
        }
        XCTAssertEqual(lines, ["skipToPrevious: playing 45.0 ms after the command"])
    }

    /// Previous on the queue's first song starts that song over: the entry stays, its position
    /// goes back to 0:00 and moves from there. That is a start too, not one that never comes.
    func testPreviousThatStartsTheSameSongOverIsTimed() async {
        let lines = await run("skipToPrevious", .movesOnAnotherSong) { t in
            if t < 60 { return self.reading(8.0, "song-1") }
            if t < 70 { return self.reading(0, "song-1", playing: false) }
            return self.reading(Double(t - 70) / 1000, "song-1")
        }
        XCTAssertEqual(lines, ["skipToPrevious: playing 75.0 ms after the command"])
    }

    /// Resume: the position holds where it was paused for about 25 ms, then moves.
    func testResumeIsTimedUntilThePositionMoves() async {
        let lines = await run("resume", .moves) { t in
            t < 25 ? self.reading(63.412, "song-3", playing: t >= 5) : self.reading(63.412 + Double(t - 25) / 1000, "song-3")
        }
        XCTAssertEqual(lines, ["resume: playing 30.0 ms after the command"])
    }

    /// Pause: the position keeps moving for about 40 ms, then holds. The stop is when it last
    /// moved, not when the watch was sure it had stopped.
    func testPauseIsTimedUntilThePositionLastMoved() async {
        let lines = await run("pause", .holdsStill) { t in
            self.reading(20.0 + Double(min(t, 40)) / 1000, "song-3", playing: t < 40)
        }
        XCTAssertEqual(lines, ["pause: stopped 40.0 ms after the command"])
    }

    /// A skip at the end of a queue with nothing after it never plays another song: the log says
    /// so once the watch gives up, instead of a time.
    func testAStartThatNeverComesIsLoggedAsMissing() async {
        let steps = Int(AppleMusicSoundWatch.limit / AppleMusicSoundWatch.interval) + 5
        let lines = await run("skipToNext", .movesOnAnotherSong, steps: steps) { _ in
            self.reading(180.0, "last-song", playing: false)
        }
        XCTAssertEqual(lines, ["skipToNext: not playing 10.00 s after the command"])
    }

    /// Next pressed twice quickly: only the second is timed, from its own command.
    func testANewerCommandReplacesTheWatch() async {
        let clock = ManualPlaybackClock()
        let start = clock.now
        let second = start.advanced(by: .milliseconds(5))
        var lines: [String] = []
        let watch = AppleMusicSoundWatch(
            clock: clock,
            read: {
                // The second press moves to song-2, which plays from 45 ms after it.
                let sinceSecond = Int(second.duration(to: clock.now) / .milliseconds(1))
                guard sinceSecond >= 0 else {
                    return AppleMusicSoundWatch.Reading(positionSeconds: 10, entryID: "song-1", isPlaying: true)
                }
                return AppleMusicSoundWatch.Reading(
                    positionSeconds: Double(max(0, sinceSecond - 45)) / 1000, entryID: "song-2", isPlaying: true
                )
            },
            report: { lines.append($0) }
        )
        watch.watch("skipToNext", for: .movesOnAnotherSong, sentAt: start)
        _ = await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(5))
        // MusicKit hadn't moved on from the first press yet when the second went out.
        watch.watch("skipToNext", for: .movesOnAnotherSong, sentAt: second, before: AppleMusicSoundWatch.Reading(
            positionSeconds: 10, entryID: "song-1", isPlaying: true
        ))
        for _ in 0..<40 where lines.isEmpty {
            guard await clock.waitForSleepers(1) else { break }
            clock.advance(by: AppleMusicSoundWatch.interval)
            await Task.yield()
        }
        XCTAssertEqual(lines, ["skipToNext: playing 50.0 ms after the command"])
    }
}
