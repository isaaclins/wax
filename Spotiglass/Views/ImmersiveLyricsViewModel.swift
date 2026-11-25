import Combine
import Foundation

extension LrcLibClient.Failure {
    var userFacingMessage: String {
        switch self {
        case .noLyrics:
            return SpotiglassL10n.string("lyrics.error.noLyrics")
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return String(
                    format: SpotiglassL10n.string("lyrics.error.rateLimitedSeconds"),
                    Int(retryAfter.rounded())
                )
            }
            return SpotiglassL10n.string("lyrics.error.rateLimitedShortly")
        // The status code is a developer fact and `LrcLibClient` logs it; the
        // reader only needs to know lyrics did not arrive (#157).
        case .http:
            return SpotiglassL10n.string("lyrics.error.http")
        case .decoding:
            return SpotiglassL10n.string("lyrics.error.decode")
        case .invalidURL:
            return SpotiglassL10n.string("lyrics.error.invalidRequest")
        }
    }
}

@MainActor
final class ImmersiveLyricsViewModel: ObservableObject {
    private static let noLyricsCooldownDuration: TimeInterval = 10 * 60
    private static let decodingCooldownDuration: TimeInterval = 5 * 60
    private static let permanentCooldownDuration: TimeInterval = 15 * 60
    private static let transientBaseCooldownDuration: TimeInterval = 30
    private static let transientMaxCooldownDuration: TimeInterval = 10 * 60
    private static let rateLimitedFallbackCooldownDuration: TimeInterval = 60
    /// A dropped connection is the most common failure and the quickest to pass: a short wait,
    /// kept in memory only and ended as soon as the network comes back (#599).
    private static let networkBaseCooldownDuration: TimeInterval = 5
    private static let networkMaxCooldownDuration: TimeInterval = 60
    /// Try again fetches at once, but a hammered button fetches at most this often (#599).
    static let manualRetryInterval: TimeInterval = 3

    enum Phase: Equatable {
        case idle
        case loading
        case ready(FetchedLyrics)
        /// Looked up when shown, so an open lyrics view follows a language switch (#548).
        case failed(LocalizedText)
    }

    @Published private(set) var phase: Phase = .idle

    private let fetch: (PlaybackNowPlaying) async throws -> FetchedLyrics
    private let diskCache: LyricsDiskCache?
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var loadGeneration = 0
    /// The song whose lyrics failed for want of a connection, loaded again when it is back.
    private var trackWaitingForNetwork: PlaybackNowPlaying?
    private var lastManualFetch: (trackId: String, at: Date)?
    private var networkRecoveryTask: Task<Void, Never>?

    /// Lyrics kept in memory this session; older ones load from the disk cache again (#381).
    static let maxMemoryEntries = 200

    /// In-memory only; class is `@MainActor` so no lock is required.
    private static var cache = LRUDictionary<String, FetchedLyrics>(capacity: maxMemoryEntries)
    private static var inFlight: [String: Task<FetchedLyrics, Error>] = [:]
    private static var noLyricsCooldownUntil: [String: Date] = [:]
    private static var backoffMetadata: [String: LyricsDiskCache.TrackBackoffMetadata] = [:]

    /// - Parameter networkRecovered: yields when the network comes back (or the Mac wakes);
    ///   connection waits end and lyrics that failed for want of a connection load again.
    init(
        fetchLyrics: @escaping (PlaybackNowPlaying) async throws -> FetchedLyrics,
        diskCache: LyricsDiskCache? = nil,
        networkRecovered: AsyncStream<Void>? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.fetch = fetchLyrics
        self.diskCache = diskCache
        self.now = now
        self.sleep = sleep
        if let networkRecovered {
            networkRecoveryTask = Task { [weak self] in
                for await _ in networkRecovered {
                    guard let self else { return }
                    await self.networkCameBack()
                }
            }
        }
    }

    convenience init(client: LrcLibClient = LrcLibClient()) {
        let disk = try? LyricsDiskCache()
        self.init(
            fetchLyrics: { try await client.fetchLyrics(for: $0) },
            diskCache: disk,
            networkRecovered: AuthRecoverySignals.live()
        )
    }

    deinit {
        networkRecoveryTask?.cancel()
    }

    /// Fetches lyrics in the background without changing `phase` (for prefetch while the overlay is closed).
    func preload(track: PlaybackNowPlaying) async {
        guard let tid = track.lyricsTrackKey else { return }
        guard Self.cache.value(forKey: tid) == nil else { return }
        guard !isWithinBackoffCooldown(trackId: tid) else { return }
        do {
            _ = try await fetchWithDedup(trackId: tid, track: track)
        } catch is CancellationError {
            return
        } catch {
            // Prefetch is best-effort; failures surface when the user opens lyrics and `load` runs.
            // `LrcLibClient` logged what failed; this says it was a prefetch.
            SpotiglassLog.info(.api, "Lyrics prefetch failed; nothing shown, opening lyrics fetches again")
        }
    }

    func load(track: PlaybackNowPlaying) async {
        let generation = beginLoad()
        guard isCurrentLoad(generation) else { return }
        await load(track: track, generation: generation, honoursBackoff: true)
    }

    /// Try again, pressed: fetches right away, past the wait an earlier failure set, at most
    /// once every ``manualRetryInterval`` per song. Only a rate limit still waits, since the
    /// server asked for it (#599). Loading shows at once, also while a quick second press waits.
    func retry(track: PlaybackNowPlaying) async {
        let generation = beginLoad()
        guard isCurrentLoad(generation) else { return }
        guard let tid = track.lyricsTrackKey else {
            await load(track: track, generation: generation, honoursBackoff: true)
            return
        }
        phase = .loading
        if let last = lastManualFetch, last.trackId == tid {
            let wait = last.at.addingTimeInterval(Self.manualRetryInterval).timeIntervalSince(now())
            if wait > 0 {
                // try?: the wait only throws when cancelled, and `isCurrentLoad` ends the load then.
                try? await sleep(wait)
                guard isCurrentLoad(generation) else { return }
            }
        }
        lastManualFetch = (tid, now())
        let rateLimited = Self.backoffMetadata[tid]?.failureClass == .rateLimited
        await load(track: track, generation: generation, honoursBackoff: rateLimited)
    }

    private func load(track: PlaybackNowPlaying, generation: Int, honoursBackoff: Bool) async {
        guard let tid = track.lyricsTrackKey else {
            phase = .failed(LocalizedText(SpotiglassL10n.string("lyrics.error.musicOnly")))
            return
        }

        if let cached = Self.cache.value(forKey: tid) {
            diskCache?.markUsed(trackKey: tid)
            phase = .ready(cached)
            return
        }
        if let disk = diskCache?.load(trackKey: tid) {
            Self.cache.setValue(disk, forKey: tid)
            phase = .ready(disk)
            return
        }
        if honoursBackoff, isWithinBackoffCooldown(trackId: tid) {
            SpotiglassLog.info(.api, "Lyrics not fetched: this song failed before and waits \(remainingCooldownDescription(trackId: tid)); showed that")
            phase = .failed(cooldownMessage(trackId: tid))
            return
        }

        phase = .loading
        do {
            let lyrics = try await fetchWithDedup(trackId: tid, track: track)
            guard isCurrentLoad(generation) else { return }
            phase = .ready(lyrics)
        } catch is CancellationError {
            return
        } catch let failure as LrcLibClient.Failure {
            guard isCurrentLoad(generation) else { return }
            registerFailureBackoff(trackId: tid, failure: failure)
            phase = .failed(LocalizedText(failure.userFacingMessage))
        } catch let urlError as URLError where urlError.code != .cancelled {
            guard isCurrentLoad(generation) else { return }
            // Offline, timed out, DNS, connection lost: the connection, not the song (#599).
            // `LrcLibClient` logged the request; this is what the app does about it.
            let (count, wait) = registerNetworkBackoff(trackId: tid)
            SpotiglassLog.info(
                .api,
                "Lyrics failed (network, URLError \(urlError.code.rawValue)) \(count) time(s) for this song; showed the connection error, no new fetch for \(Int(wait.rounded())) s or until the network is back"
            )
            trackWaitingForNetwork = track
            phase = .failed(LocalizedText(SpotiglassL10n.string("lyrics.error.network")))
        } catch {
            guard isCurrentLoad(generation) else { return }
            // localizedDescription here is a system error dump, which is not a sentence
            // for a reader waiting on lyrics (#157). `LrcLibClient` logged it; the
            // backoff logs what the app does about it.
            registerFailureBackoff(trackId: tid, failure: nil)
            phase = .failed(LocalizedText(SpotiglassL10n.string("lyrics.error.http")))
        }
    }

    /// The network came back: connection waits end, and lyrics on screen that failed for
    /// want of a connection load again without a press (#599). Internal so a test can send it
    /// without waiting for the signal to arrive.
    func networkCameBack() async {
        let hadWaits = Self.backoffMetadata.values.contains { $0.failureClass == .network }
        Self.backoffMetadata = Self.backoffMetadata.filter { $0.value.failureClass != .network }
        guard let track = trackWaitingForNetwork else {
            if hadWaits { SpotiglassLog.info(.api, "Network is back; lyrics connection waits ended") }
            return
        }
        SpotiglassLog.info(.api, "Network is back; loading the lyrics that failed for want of a connection")
        await load(track: track)
    }

    /// Loading, for a song that is on its way: a play just started and the player has no song
    /// yet. Whatever was loading for the previous song no longer shows.
    func waitForTrack() {
        _ = beginLoad()
        phase = .loading
    }

    private func beginLoad() -> Int {
        // Whatever loads next replaces the song that waited for the network (also a new song on its way).
        trackWaitingForNetwork = nil
        loadGeneration += 1
        return loadGeneration
    }

    private func isCurrentLoad(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == loadGeneration
    }

    private func fetchWithDedup(trackId: String, track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        if let cached = Self.cache.value(forKey: trackId) {
            return cached
        }
        if let disk = diskCache?.load(trackKey: trackId) {
            Self.cache.setValue(disk, forKey: trackId)
            return disk
        }
        if let existing = Self.inFlight[trackId] {
            return try await existing.value
        }
        let newTask = Task {
            try await fetch(track)
        }
        Self.inFlight[trackId] = newTask
        do {
            let value = try await newTask.value
            Self.cache.setValue(value, forKey: trackId)
            Self.noLyricsCooldownUntil[trackId] = nil
            Self.backoffMetadata[trackId] = nil
            Self.inFlight[trackId] = nil
            // Separate, so a failed save still clears the song's old wait on disk.
            do {
                try diskCache?.save(trackKey: trackId, lyrics: value)
            } catch {
                SpotiglassLog.error(.persistence, "Saving lyrics to the disk cache failed: \(SpotiglassLog.describe(error)); they are fetched again next launch")
            }
            do {
                try diskCache?.clearTrackBackoffMetadata(trackKey: trackId)
            } catch {
                SpotiglassLog.error(
                    .persistence,
                    "Clearing the lyrics wait in the disk cache failed: \(SpotiglassLog.describe(error)); after a relaunch the song may wait once more"
                )
            }
            return value
        } catch {
            Self.inFlight[trackId] = nil
            throw error
        }
    }

    /// Clears shared in-memory state (`SpotiglassTests` only).
    // periphery:ignore
    internal static func resetSharedStateForTesting() {
        for task in inFlight.values {
            task.cancel()
        }
        cache = LRUDictionary(capacity: maxMemoryEntries)
        inFlight.removeAll()
        noLyricsCooldownUntil.removeAll()
        backoffMetadata.removeAll()
    }

    private func isWithinBackoffCooldown(trackId: String) -> Bool {
        let now = now()
        if let metadata = Self.backoffMetadata[trackId], metadata.nextEligibleFetchAt > now {
            return true
        }
        if let persistedMetadata = diskCache?.loadTrackBackoffMetadata(trackKey: trackId),
           persistedMetadata.nextEligibleFetchAt > now {
            Self.backoffMetadata[trackId] = persistedMetadata
            return true
        }
        if let expiry = Self.noLyricsCooldownUntil[trackId], expiry > now {
            return true
        }
        if let persisted = diskCache?.loadMissCooldownExpiry(trackKey: trackId), persisted > now {
            Self.noLyricsCooldownUntil[trackId] = persisted
            return true
        }
        return false
    }

    private func registerNoLyricsCooldown(trackId: String) {
        let now = now()
        let expiry = now.addingTimeInterval(Self.noLyricsCooldownDuration)
        // Ended cooldowns go, the same way the disk copy drops them.
        Self.noLyricsCooldownUntil = Self.noLyricsCooldownUntil.filter { $0.value > now }
        Self.noLyricsCooldownUntil[trackId] = expiry
        do {
            try diskCache?.saveMissCooldownExpiry(trackKey: trackId, expiresAt: expiry)
        } catch {
            SpotiglassLog.error(.persistence, "Saving a lyrics miss to the disk cache failed: \(SpotiglassLog.describe(error)); it is retried after a relaunch")
        }
    }

    /// The wait is taken now; the sentence around it is looked up when shown.
    private func cooldownMessage(trackId: String) -> LocalizedText {
        if let metadata = Self.backoffMetadata[trackId] {
            switch metadata.failureClass {
            case .noLyrics:
                return LocalizedText(LrcLibClient.Failure.noLyrics.userFacingMessage)
            case .decoding:
                return LocalizedText(LrcLibClient.Failure.decoding.userFacingMessage)
            case .rateLimited:
                let failure = LrcLibClient.Failure.rateLimited(
                    retryAfter: max(0, metadata.nextEligibleFetchAt.timeIntervalSince(now()))
                )
                return LocalizedText(failure.userFacingMessage)
            case .network:
                return LocalizedText(SpotiglassL10n.string("lyrics.error.network"))
            // The server failed, not the song: the same sentence as the failure itself.
            case .transient:
                return LocalizedText(SpotiglassL10n.string("lyrics.error.http"))
            case .permanent:
                return LocalizedText(SpotiglassL10n.string("lyrics.error.unavailable"))
            }
        }
        return LocalizedText(LrcLibClient.Failure.noLyrics.userFacingMessage)
    }

    /// How long the song's lyrics wait before the next fetch, for the log.
    private func remainingCooldownDescription(trackId: String) -> String {
        let until = [Self.backoffMetadata[trackId]?.nextEligibleFetchAt, Self.noLyricsCooldownUntil[trackId]]
            .compactMap { $0 }
            .max()
        guard let until else { return "a while" }
        return "\(Int(max(0, until.timeIntervalSince(now())).rounded())) s more"
    }

    /// Kept in memory only: a dropped connection says nothing about the song, so it must
    /// not outlive a relaunch (#599).
    private func registerNetworkBackoff(trackId: String) -> (count: Int, wait: TimeInterval) {
        let now = now()
        let previous = Self.backoffMetadata[trackId]
        let nextCount = previous?.failureClass == .network ? (previous?.failureCount ?? 0) + 1 : 1
        let wait = min(
            Self.networkMaxCooldownDuration,
            Self.networkBaseCooldownDuration * pow(2, Double(min(nextCount - 1, 4)))
        )
        Self.backoffMetadata[trackId] = LyricsDiskCache.TrackBackoffMetadata(
            failureClass: .network,
            failureCount: nextCount,
            nextEligibleFetchAt: now.addingTimeInterval(wait)
        )
        return (nextCount, wait)
    }

    private func registerFailureBackoff(trackId: String, failure: LrcLibClient.Failure?) {
        let now = now()
        let previous = Self.backoffMetadata[trackId]
        // A connection wait before this one says nothing about how this failure should grow.
        let currentCount = previous?.failureClass == .network ? 0 : (previous?.failureCount ?? 0)
        let nextCount = currentCount + 1
        let metadata: LyricsDiskCache.TrackBackoffMetadata

        switch failure {
        case .noLyrics:
            registerNoLyricsCooldown(trackId: trackId)
            metadata = LyricsDiskCache.TrackBackoffMetadata(
                failureClass: .noLyrics,
                failureCount: nextCount,
                nextEligibleFetchAt: now.addingTimeInterval(Self.noLyricsCooldownDuration)
            )
        case .decoding:
            metadata = LyricsDiskCache.TrackBackoffMetadata(
                failureClass: .decoding,
                failureCount: nextCount,
                nextEligibleFetchAt: now.addingTimeInterval(Self.decodingCooldownDuration)
            )
        case let .rateLimited(retryAfter):
            let cooldown = max(Self.rateLimitedFallbackCooldownDuration, retryAfter ?? 0)
            metadata = LyricsDiskCache.TrackBackoffMetadata(
                failureClass: .rateLimited,
                failureCount: nextCount,
                nextEligibleFetchAt: now.addingTimeInterval(cooldown)
            )
        case let .http(code):
            if code >= 500 {
                let exp = min(Self.transientMaxCooldownDuration, Self.transientBaseCooldownDuration * pow(2, Double(min(nextCount, 5))))
                metadata = LyricsDiskCache.TrackBackoffMetadata(
                    failureClass: .transient,
                    failureCount: nextCount,
                    nextEligibleFetchAt: now.addingTimeInterval(exp)
                )
            } else {
                metadata = LyricsDiskCache.TrackBackoffMetadata(
                    failureClass: .permanent,
                    failureCount: nextCount,
                    nextEligibleFetchAt: now.addingTimeInterval(Self.permanentCooldownDuration)
                )
            }
        case .invalidURL, .none:
            metadata = LyricsDiskCache.TrackBackoffMetadata(
                failureClass: .permanent,
                failureCount: nextCount,
                nextEligibleFetchAt: now.addingTimeInterval(Self.permanentCooldownDuration)
            )
        }

        // Kept a day past its cooldown so repeated failures still back off further, like the disk copy.
        Self.backoffMetadata = Self.backoffMetadata.filter { $0.value.nextEligibleFetchAt > now.addingTimeInterval(-24 * 60 * 60) }
        Self.backoffMetadata[trackId] = metadata
        // `LrcLibClient` logged the failure itself; this is what the app does about it.
        let wait = Int(metadata.nextEligibleFetchAt.timeIntervalSince(now).rounded())
        if case .noLyrics = failure {
            SpotiglassLog.info(.api, "LRCLIB has no lyrics for this song; showed that, no new fetch for \(wait) s")
        } else {
            SpotiglassLog.info(
                .api,
                "Lyrics failed (\(Self.logKind(of: failure))) \(nextCount) time(s) for this song; showed the error, no new fetch for \(wait) s"
            )
        }
        do {
            try diskCache?.saveTrackBackoffMetadata(trackKey: trackId, metadata: metadata)
        } catch {
            SpotiglassLog.error(.persistence, "Saving the lyrics wait to the disk cache failed: \(SpotiglassLog.describe(error)); it ends at relaunch")
        }
    }

    /// The kind of failure for the log: never the song or artist (#599, #603).
    private static func logKind(of failure: LrcLibClient.Failure?) -> String {
        switch failure {
        case .noLyrics: return "no lyrics"
        case .decoding: return "unreadable answer"
        case let .rateLimited(retryAfter): return "rate limited, Retry-After \(retryAfter.map { "\(Int($0.rounded())) s" } ?? "not sent")"
        case let .http(code): return "HTTP \(code)"
        case .invalidURL: return "invalid request"
        case .none: return "unknown error"
        }
    }
}
