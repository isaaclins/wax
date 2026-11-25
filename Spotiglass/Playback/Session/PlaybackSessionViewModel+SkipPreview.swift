import Foundation

/// Next and previous name the new song at once (#687). Spotify's page lists the songs before and
/// after the current one, so the player bar shows the song a skip goes to as soon as it is
/// pressed, and settles on what Spotify reports once it answers. Before, nothing on screen
/// changed for a whole round trip to Spotify.
@MainActor
extension PlaybackSessionViewModel {
    /// The song a skip put on the player bar before Spotify reported it.
    struct SkipPreview {
        let hostGeneration: PlaybackHostGeneration
        /// What the bar shows: the song the skips went to.
        let shownURI: String
        /// Songs the skips moved past. Spotify keeps reporting the one it is on until it has
        /// the skip; those reports are held back instead of putting the old song back.
        let leftURIs: Set<String>
        /// The songs after and before the one shown (`previous` oldest first), for a next skip
        /// pressed before Spotify answered this one.
        let upcoming: [PlaybackNowPlaying]
        let previous: [PlaybackNowPlaying]
        /// The song Spotify was last heard on, for telling its reports of the skip apart.
        var reportedURI: String?
        /// What Spotify showed before the first skip: the bar goes back to it when a skip fails
        /// and nothing came from Spotify since.
        let stateBefore: PlaybackConnectionState
        /// Spotify's latest report held back, shown when the preview ends without an answer.
        var heldReport: MusicPlaybackEventEnvelope?
        /// A previous a few seconds into a song shows that song again from its start, as
        /// Spotify's own app does: its reports still at the old position are held back.
        let restartsSong: Bool
    }

    /// How long the bar shows a skipped-to song Spotify hasn't reported. After that, Spotify's
    /// own latest report is what's shown.
    static let skipPreviewTimeout: Duration = .seconds(5)

    /// How far into a song a previous starts it again rather than going back a song.
    static let previousRestartsAfterMilliseconds = 3_000

    /// Shows the song a skip goes to, from the songs Spotify's page listed around the current
    /// one; a previous more than a few seconds into a song shows it from its start. Only for
    /// Spotify's in-app player, whose reports confirm it. Nothing changes when the song isn't
    /// known (the start of the list, a list Spotify didn't send).
    func showSkipPreview(_ kind: SkipCommandDispatch.Kind) {
        guard !isPlayerStateRead, let shown = currentNowPlaying, let shownURI = shown.uri else { return }
        let preview = skipPreview.flatMap { ownsPlaybackHostGeneration($0.hostGeneration) ? $0 : nil }
        var upcoming = preview?.upcoming ?? sdkNextTracks
        var previous = preview?.previous ?? sdkPreviousTracks
        let target: PlaybackNowPlaying
        var restartsSong = false
        switch kind {
        case .next:
            guard let first = upcoming.first else { return }
            target = first
            upcoming.removeFirst()
            previous.append(shown)
        case .previous:
            let position = progressAnchor?.interpolatedPositionMs(at: Date()) ?? shown.positionMilliseconds
            if position > Self.previousRestartsAfterMilliseconds {
                target = shown
                restartsSong = true
            } else {
                guard let last = previous.last else { return }
                target = last
                previous.removeLast()
                upcoming.insert(shown, at: 0)
            }
        }
        guard let targetURI = target.uri, restartsSong || targetURI != shownURI else { return }
        var leftURIs = preview?.leftURIs ?? []
        if !restartsSong {
            leftURIs.insert(shownURI)
        }
        leftURIs.remove(targetURI)
        skipPreview = SkipPreview(
            hostGeneration: playbackHostGeneration,
            shownURI: targetURI,
            leftURIs: leftURIs,
            upcoming: upcoming,
            previous: previous,
            reportedURI: preview?.reportedURI ?? shownURI,
            stateBefore: preview?.stateBefore ?? connectionState,
            heldReport: preview?.heldReport,
            restartsSong: restartsSong
        )
        let song = target.with(positionMilliseconds: 0)
        if case .paused = connectionState {
            setConnectionState(.paused(song))
        } else {
            setConnectionState(.playing(song))
        }
        scheduleSkipPreviewTimeout()
    }

    /// The song a skip is sent away from, as Spotify knows it: while the bar shows a song
    /// Spotify hasn't reported, the one Spotify was last on.
    var skipLeavesURI: String? {
        guard let skipPreview, ownsPlaybackHostGeneration(skipPreview.hostGeneration) else {
            return currentNowPlayingURI
        }
        return skipPreview.reportedURI
    }

    /// Whether a report from Spotify's page is held back for the song on the bar: it still names
    /// a song the skips left, or (after a previous that starts the song again) the song still at
    /// its old position. A report of the song shown, of any other song, or without a song ends
    /// the preview and goes through.
    func holdsReportForSkipPreview(_ nowPlaying: PlaybackNowPlaying?, event: MusicPlaybackEvent) -> Bool {
        guard var preview = skipPreview else { return false }
        guard ownsPlaybackHostGeneration(preview.hostGeneration),
              let nowPlaying,
              let uri = nowPlaying.uri,
              uri == preview.shownURI
                ? preview.restartsSong && nowPlaying.positionMilliseconds >= Self.previousRestartsAfterMilliseconds
                : preview.leftURIs.contains(uri) else {
            endSkipPreview()
            return false
        }
        preview.reportedURI = uri
        preview.heldReport = MusicPlaybackEventEnvelope(event: event, hostGeneration: playbackHostGeneration)
        skipPreview = preview
        SpotiglassLog.info(.playback, "Holding SDK state_changed uri=\(uri) while a skip to \(preview.shownURI) is on its way")
        return true
    }

    /// The skip didn't go out or failed: the bar goes back to what Spotify last reported.
    func revertSkipPreview() {
        guard let preview = skipPreview else { return }
        endSkipPreview()
        // A player whose state is only read (another device took over) decides the bar itself.
        guard ownsPlaybackHostGeneration(preview.hostGeneration), !isPlayerStateRead else { return }
        if let held = preview.heldReport {
            handle(held)
        } else {
            setConnectionState(preview.stateBefore)
        }
    }

    func endSkipPreview() {
        skipPreviewTimeoutTask?.cancel()
        skipPreviewTimeoutTask = nil
        skipPreview = nil
    }

    private func scheduleSkipPreviewTimeout() {
        skipPreviewTimeoutTask?.cancel()
        let deadline = clock.now.advanced(by: Self.skipPreviewTimeout)
        skipPreviewTimeoutTask = Task { @MainActor [weak self, clock] in
            // try?: a cancelled wait is a newer skip or the end of the preview; the guard below sees it.
            try? await clock.sleep(until: deadline, tolerance: nil)
            guard !Task.isCancelled, let self else { return }
            SpotiglassLog.info(.playback, "Spotify didn't report the skipped-to song; showing its latest report")
            // An error since then (sign in again, Premium) says what to do: it stays.
            if case .error = self.connectionState {
                self.endSkipPreview()
                return
            }
            self.revertSkipPreview()
        }
    }
}
