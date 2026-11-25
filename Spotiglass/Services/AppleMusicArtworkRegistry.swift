import Foundation
import MusicKit

/// Library artwork from MusicKit comes as `musicKit://artwork/...` URLs, which no URL loader
/// can fetch; only MusicKit's `ArtworkImage` view can draw them. The neutral models carry URLs,
/// so the Apple Music mapping registers each such artwork here under its URL, and the artwork
/// views draw it with `ArtworkImage` instead of downloading it. Catalog artwork stays plain
/// https and goes through the normal image cache, but is registered too: its URL is fixed to the
/// size it was mapped with, and ``sizedURL(for:itemKey:pixelSize:)`` asks Apple for the size a
/// view actually draws (#426).
final class AppleMusicArtworkRegistry: @unchecked Sendable {
    static let shared = AppleMusicArtworkRegistry()

    /// Enough for a large library. Past it the least recently used artworks go first, so the
    /// covers on screen and on pins (which are read on every draw) keep drawing; an evicted
    /// item registers again the next time it is mapped (#400).
    static let maxEntries = 20_000

    private let lock = NSLock()
    private var artworkByURL: LRUDictionary<String, Artwork>
    /// The same artwork under the item's pin ID (`playlist:<id>`, ...). Library artwork URLs
    /// change between launches, so a pin saved with last session's URL finds its cover here
    /// once the item has been mapped again in this session.
    private var artworkByItemKey: LRUDictionary<String, Artwork>
    /// For library covers that a downloadable cover replaces once it's known: asks for it (#737).
    private var laterCoverByURL: LRUDictionary<String, @Sendable () -> Artwork?>

    init(capacity: Int = AppleMusicArtworkRegistry.maxEntries) {
        artworkByURL = LRUDictionary(capacity: capacity)
        artworkByItemKey = LRUDictionary(capacity: capacity)
        laterCoverByURL = LRUDictionary(capacity: capacity)
    }

    /// URLs a URL loader can't fetch and only this registry can resolve.
    static func needsMusicKit(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme != "https" && scheme != "http"
    }

    func register(_ artwork: Artwork, for url: URL, itemKey: String? = nil) {
        lock.withLock {
            artworkByURL.setValue(artwork, forKey: url.absoluteString)
            guard let itemKey else { return }
            artworkByItemKey.setValue(artwork, forKey: itemKey)
        }
    }

    /// Library artwork at `url` that a downloadable cover replaces once `cover` finds it. A saved
    /// song's catalog cover is only known after its release lookup, which a list waits for at
    /// most a moment; a row mapped before it answered asks here each time it's drawn, so it
    /// shows the catalog cover rather than MusicKit's library artwork (#737).
    func registerLaterCover(for url: URL, _ cover: @escaping @Sendable () -> Artwork?) {
        guard Self.needsMusicKit(url) else { return }
        lock.withLock { laterCoverByURL.setValue(cover, forKey: url.absoluteString) }
    }

    /// The downloadable cover that replaces the library artwork at `url`, once it's known.
    private func laterCover(for url: URL) -> Artwork? {
        // Asked outside the lock: the answer comes from another lock (the ratings').
        guard let cover = lock.withLock({ laterCoverByURL.value(forKey: url.absoluteString) }) else { return nil }
        return cover()
    }

    /// Pixel sizes artwork is requested in. Views round their drawn size up to one of these, so
    /// a 44 pt and a 56 pt thumbnail share one download and one cache entry.
    static let requestPixelSizes = [120, 300, 600, 1200]

    static func requestPixelSize(forDrawnPixels pixels: CGFloat) -> Int {
        let needed = Int(pixels.rounded(.up))
        return requestPixelSizes.first { $0 >= needed } ?? requestPixelSizes[requestPixelSizes.count - 1]
    }

    /// `url` (as mapped, at a fixed size) at `pixelSize`, so a cover is never stretched past what
    /// Apple sent. Library artwork and URLs this session never mapped come back unchanged: MusicKit
    /// draws library covers at the view's size itself, and an unknown URL can't be resized.
    /// Library artwork a downloadable cover has replaced since it was mapped comes back as that
    /// cover (``registerLaterCover(for:_:)``).
    func sizedURL(for url: URL, itemKey: String? = nil, pixelSize: Int) -> URL {
        let artwork: Artwork
        if Self.needsMusicKit(url) {
            guard let later = laterCover(for: url) else { return url }
            artwork = later
        } else {
            guard let known = self.artwork(for: url, itemKey: itemKey) else { return url }
            artwork = known
        }
        // Asking past the original only returns the original under another cache key.
        let side = min(pixelSize, max(artwork.maximumWidth, artwork.maximumHeight, 1))
        // The item key can hold library artwork now (a pin saved with a catalog URL), and the
        // caller downloads what comes back, so a `musicKit://` URL would only fail to load.
        guard let sized = artwork.url(width: side, height: side), !Self.needsMusicKit(sized) else { return url }
        return sized
    }

    /// A URL for the artwork registered under `itemKey` (a pin's ID), at `size` pixels, for a pin
    /// saved without a cover (#477).
    func url(forItemKey itemKey: String, size: Int) -> URL? {
        let artwork = lock.withLock { artworkByItemKey.value(forKey: itemKey) }
        return artwork?.url(width: size, height: size)
    }

    /// The artwork for `url`, or else the artwork last registered for `itemKey`. A hit counts
    /// as a use, which keeps drawn covers from being evicted.
    func artwork(for url: URL, itemKey: String? = nil) -> Artwork? {
        lock.withLock {
            artworkByURL.value(forKey: url.absoluteString)
                ?? itemKey.flatMap { artworkByItemKey.value(forKey: $0) }
        }
    }
}
