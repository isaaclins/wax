import AppKit
import Combine
import CryptoKit
import Foundation

/// Loads Spotify CDN artwork with memory + disk layers and a URLSession `URLCache` for HTTP caching.
actor ArtworkImageStore {
    static let shared = ArtworkImageStore()

    private let memoryKeys: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 280
        return c
    }()

    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var cacheGeneration: UInt64 = 0
    private let diskDirectory: URL
    private var urlSession: URLSession
    private let makeURLSession: () -> URLSession
    private let responseURLCache: URLCache
    private let maxDiskBytes: Int64 = 50 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let disk = Self.defaultDiskDirectory
        let urlCacheDir = base.appendingPathComponent(AppMetadata.storageDirectoryName, isDirectory: true)
            .appendingPathComponent("ArtworkURLCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: urlCacheDir, withIntermediateDirectories: true)
        let urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 96 * 1024 * 1024,
            diskPath: urlCacheDir.path
        )
        let makeURLSession: () -> URLSession = {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = urlCache
            return URLSession(configuration: configuration)
        }
        self.init(
            diskDirectory: disk,
            urlSession: makeURLSession(),
            responseURLCache: urlCache,
            urlSessionFactory: makeURLSession
        )
    }

    init(
        diskDirectory: URL,
        urlSession: URLSession,
        responseURLCache: URLCache,
        urlSessionFactory: @escaping () -> URLSession
    ) {
        self.diskDirectory = diskDirectory
        self.urlSession = urlSession
        self.makeURLSession = urlSessionFactory
        self.responseURLCache = responseURLCache
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Every cover request goes into the log (#734): where it came from (memory, disk, network),
    /// its size, how long it took, and why it failed.
    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let cached = memoryKeys.object(forKey: key as NSString) {
            SpotiglassLog.debug(.artwork, "cover \(key) from memory \(Self.pixels(cached))")
            return cached
        }
        if let existing = inFlight[key] {
            SpotiglassLog.debug(.artwork, "cover \(key) already loading, waiting for it")
            return await existing.value
        }
        let generation = cacheGeneration
        let task = Task<NSImage?, Never> {
            await self.loadThroughDiskAndNetwork(url: url, key: key, generation: generation)
        }
        inFlight[key] = task
        let result = await task.value
        if cacheGeneration == generation {
            inFlight[key] = nil
        }
        return result
    }

    /// The one place the on-disk cache location is defined. Both the shared
    /// store and the synchronous read below resolve it from here, so a test can
    /// point the read at its own directory instead of the user's real cache.
    nonisolated static var defaultDiskDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(AppMetadata.storageDirectoryName, isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    nonisolated static func cacheFileURL(for url: URL, diskDirectory: URL) -> URL {
        let name = Self.sha256Hex(url.absoluteString) + ".img"
        return diskDirectory.appendingPathComponent(name)
    }

    /// Best-effort synchronous read for views that must render immediately (for
    /// example drag previews). Returns `nil` when artwork has not been cached yet.
    nonisolated static func cachedImageIfAvailable(
        for url: URL,
        diskDirectory: URL = defaultDiskDirectory
    ) -> NSImage? {
        let fileURL = cacheFileURL(for: url, diskDirectory: diskDirectory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }

    private func loadThroughDiskAndNetwork(url: URL, key: String, generation: UInt64) async -> NSImage? {
        guard generation == cacheGeneration else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        let took = { CallLog.milliseconds(ProcessInfo.processInfo.systemUptime - start) }
        let fileURL = Self.cacheFileURL(for: url, diskDirectory: diskDirectory)
        if let data = try? Data(contentsOf: fileURL),
           generation == cacheGeneration,
           let image = NSImage(data: data) {
            memoryKeys.setObject(image, forKey: key as NSString)
            SpotiglassLog.info(.artwork, "cover \(key) from disk cache in \(took()), \(Self.pixels(image)), \(data.count) bytes")
            return image
        }

        do {
            let (data, response) = try await CallLog.http(url, session: urlSession)
            guard generation == cacheGeneration else { return nil }
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse).map { "status \($0.statusCode)" } ?? "no HTTP response"
                SpotiglassLog.error(.artwork, "cover \(key) failed after \(took()): \(status)")
                return nil
            }
            guard let image = NSImage(data: data) else {
                SpotiglassLog.error(.artwork, "cover \(key) failed after \(took()): \(data.count) bytes that are not an image")
                return nil
            }
            memoryKeys.setObject(image, forKey: key as NSString)
            // URLCache answers a repeat without going out; the log can't tell the two apart.
            SpotiglassLog.info(.artwork, "cover \(key) loaded (not cached on disk) in \(took()), \(Self.pixels(image)), \(data.count) bytes")
            DiskCacheTrim.write { try? data.write(to: fileURL, options: [.atomic]) }
            await trimDiskCacheIfNeeded()
            return image
        } catch {
            if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                SpotiglassLog.error(.artwork, "cover \(key) failed after \(took()): \(SpotiglassLog.describe(error))")
            }
            return nil
        }
    }

    private nonisolated static func pixels(_ image: NSImage) -> String {
        let rep = image.representations.first
        let width = rep?.pixelsWide ?? Int(image.size.width)
        let height = rep?.pixelsHigh ?? Int(image.size.height)
        return "\(width)x\(height) px"
    }

    private func trimDiskCacheIfNeeded() async {
        DiskCacheTrim.trim(directory: diskDirectory, maxBytes: maxDiskBytes)
    }

    private nonisolated static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Clears memory and on-disk artwork (call on disconnect).
    func clearAllCachedImages() {
        cacheGeneration &+= 1
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        memoryKeys.removeAllObjects()
        responseURLCache.removeAllCachedResponses()
        urlSession.invalidateAndCancel()
        urlSession = makeURLSession()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }
}

/// Owns the state for one artwork surface and fences asynchronous results to the
/// URL and generation that requested them.
@MainActor
final class ArtworkImageLoader: ObservableObject {
    typealias ImageProvider = @Sendable (URL) async -> NSImage?
    typealias ImageTransformer = (NSImage) -> NSImage

    @Published private(set) var image: NSImage?
    @Published private(set) var didFail = false

    private let imageProvider: ImageProvider
    private let imageTransformer: ImageTransformer
    private var requestedURL: URL?
    /// The cover `requestedURL` shows, whatever size it asks for. A new size of the same cover
    /// (the window moved to a Retina screen) keeps the current image until the new one is in.
    private var requestedArtwork: URL?
    /// The URL `image` came from. It lags `requestedURL` while a new size loads or after it
    /// failed, so asking for that size again retries instead of keeping the smaller cover.
    private var shownURL: URL?
    private var generation: UInt64 = 0

    init(
        imageProvider: @escaping ImageProvider = { url in
            await ArtworkImageStore.shared.image(for: url)
        },
        initialImage: NSImage? = nil,
        initialURL: URL? = nil,
        imageTransformer: @escaping ImageTransformer = { $0 }
    ) {
        self.imageProvider = imageProvider
        self.imageTransformer = imageTransformer
        self.image = initialImage.map(imageTransformer)
        self.requestedURL = initialURL
        self.requestedArtwork = initialURL
        self.shownURL = initialImage == nil ? nil : initialURL
    }

    /// Loads `url`. `artwork` names the cover it is a size of (default: `url` itself); while a
    /// new size of the shown cover loads, and if it fails, the current image stays (#426).
    func load(for url: URL?, artwork: URL? = nil) async {
        if shownURL == url, image != nil {
            return
        }

        let artwork = artwork ?? url
        let resizesShownCover = image != nil && artwork != nil && artwork == requestedArtwork
        generation &+= 1
        let requestGeneration = generation
        requestedURL = url
        requestedArtwork = artwork
        if !resizesShownCover {
            image = nil
            shownURL = nil
        }
        didFail = false

        guard let url else { return }
        let loaded = await imageProvider(url)
        guard !Task.isCancelled,
            generation == requestGeneration,
            requestedURL == url
        else {
            return
        }
        if let loaded {
            image = imageTransformer(loaded)
            shownURL = url
        } else if !resizesShownCover {
            image = nil
            shownURL = nil
        }
        didFail = image == nil
    }
}
