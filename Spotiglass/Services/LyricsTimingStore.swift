import Foundation

/// How far each song's lyrics are shifted, saved per song (#640). A positive shift shows the
/// lyrics sooner (the line for a later moment is highlighted now), a negative one later.
///
/// The shift is set by holding the lyrics with a right click and dragging the line being sung
/// into the highlight (``LyricsTimingHold``). A song without a saved shift plays with the
/// lyrics' own timing.
@MainActor
final class LyricsTimingStore: ObservableObject {
    static let shared = LyricsTimingStore()

    static let defaultsKey = "lyrics.timingShifts"
    /// Songs kept; the least recently fixed are dropped beyond this, so the list can't grow
    /// without end.
    nonisolated static let defaultMaxSongs = 2_000

    struct Entry: Codable, Equatable {
        var offsetMs: Int
        var savedAt: Date
    }

    @Published private(set) var entries: [String: Entry]

    private let defaults: UserDefaults
    private let maxSongs: Int
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        maxSongs: Int = LyricsTimingStore.defaultMaxSongs,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.maxSongs = maxSongs
        self.now = now
        if let data = defaults.data(forKey: Self.defaultsKey),
            // try?: saved shifts that don't decode start over empty; they are only a convenience.
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// The song's saved shift in milliseconds, 0 when it has none.
    func offsetMs(for songID: String?) -> Int {
        guard let songID else { return 0 }
        return entries[songID]?.offsetMs ?? 0
    }

    func hasShift(for songID: String?) -> Bool {
        offsetMs(for: songID) != 0
    }

    /// Saves the song's shift; 0 forgets it.
    func setOffset(_ offsetMs: Int, for songID: String) {
        var next = entries
        if offsetMs == 0 {
            next[songID] = nil
        } else {
            next[songID] = Entry(offsetMs: offsetMs, savedAt: now())
        }
        if next.count > maxSongs {
            let oldestFirst = next.sorted { $0.value.savedAt < $1.value.savedAt }
            for (key, _) in oldestFirst.prefix(next.count - maxSongs) {
                next[key] = nil
            }
        }
        guard next != entries else { return }
        entries = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func reset(for songID: String) {
        setOffset(0, for: songID)
    }
}
