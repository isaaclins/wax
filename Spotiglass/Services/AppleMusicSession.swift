import Foundation
import MusicKit

/// The two system answers Apple Music browsing depends on: the user's permission for this app,
/// and whether the account has a subscription that can play catalog music.
protocol AppleMusicAuthorizing: Sendable {
    func currentStatus() -> MusicAuthorization.Status
    func requestAuthorization() async -> MusicAuthorization.Status
    /// `true` when the account can play catalog content, `nil` when that is unknown.
    func canPlayCatalogContent() async -> Bool?
    /// Whether an Apple Account is signed in to Music on this Mac: `false` only when MusicKit
    /// says so, `nil` when it can't tell (offline, say), which counts as signed in.
    func isSignedInToMusic() async -> Bool?
    /// Fires whenever the account's Apple Music status changes, e.g. on a sign-in or sign-out in
    /// the Music app (#654).
    func accountChanges() -> AsyncStream<Void>
}

extension AppleMusicAuthorizing {
    func isSignedInToMusic() async -> Bool? { nil }
    func accountChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Apple Music sign-in state for the browser. There is no account to sign in to in Spotiglass:
/// the system permission prompt is the flow, and the Apple Account is the one signed in to Music.
@MainActor
final class AppleMusicSession: ObservableObject {
    enum State: Equatable {
        case checking
        /// The user has not been asked yet.
        case needsPermission
        /// The user said no (or a device policy does); only System Settings can change it.
        case denied
        /// Access is allowed, but Music on this Mac has no Apple Account signed in, so there is
        /// no library to read (#654). Signing in happens in the Music app.
        case signedOut
        case authorized
    }

    @Published private(set) var state: State = .checking
    /// Known once authorized; browsing works without a subscription, playback will not.
    @Published private(set) var canPlayCatalogContent: Bool?

    private let authorization: any AppleMusicAuthorizing
    /// The sign-in check's grace period waits on this clock (a test steps it).
    private let clock: any PlaybackClock

    init(
        authorization: any AppleMusicAuthorizing = SystemAppleMusicAuthorization(),
        clock: any PlaybackClock = ContinuousClock()
    ) {
        self.authorization = authorization
        self.clock = clock
    }

    /// How long the window waits on the sign-in check before it shows the library anyway. The
    /// check asks Apple's servers, so on a slow network it can take as long as the request's
    /// timeout; the library then shows meanwhile and the sign-in screen follows if the answer
    /// is "signed out".
    static let signInCheckGrace: Duration = .seconds(1)

    /// Reads the current permission and sign-in without prompting.
    func refresh() async {
        await apply(authorization.currentStatus())
    }

    /// Shows the system prompt when the user has not answered it yet.
    func requestAccess() async {
        let current = authorization.currentStatus()
        guard current == .notDetermined else {
            await apply(current)
            return
        }
        await apply(await authorization.requestAuthorization())
    }

    /// Refreshes on every account change until the calling task is cancelled, so signing in or
    /// out of Music while Spotiglass is open shows without a relaunch (#654).
    func followAccountChanges() async {
        for await _ in authorization.accountChanges() {
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func apply(_ status: MusicAuthorization.Status) async {
        switch status {
        case .authorized:
            let check = Task { [authorization] () -> (canPlay: Bool?, signedIn: Bool?) in
                let canPlay = await authorization.canPlayCatalogContent()
                // A subscription that plays means an account is signed in; only otherwise ask.
                let signedIn = canPlay == true ? true : await authorization.isSignedInToMusic()
                return (canPlay, signedIn)
            }
            // Nothing on screen yet: hold the spinner for the answer, but not for longer than
            // the grace period.
            let grace = Self.showsLibraryOrSignIn(state) ? nil : showLibraryAfterGrace()
            let (canPlay, signedIn) = await check.value
            grace?.cancel()
            canPlayCatalogContent = canPlay
            state = signedIn == false ? .signedOut : .authorized
        case .notDetermined:
            state = .needsPermission
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    /// Privacy & Security > Media & Apple Music.
    private static func showsLibraryOrSignIn(_ state: State) -> Bool {
        state == .authorized || state == .signedOut
    }

    private func showLibraryAfterGrace() -> Task<Void, Never> {
        let clock = clock
        return Task { [weak self] in
            // try?: the wait only fails when cancelled (the check answered), checked below.
            try? await clock.sleep(until: clock.now.advanced(by: Self.signInCheckGrace), tolerance: nil)
            guard let self, !Task.isCancelled, !Self.showsLibraryOrSignIn(self.state) else { return }
            self.state = .authorized
        }
    }

    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media"
    )!

    /// The Music app, where the Apple Account is signed in (Account › Sign In).
    static let musicAppBundleID = "com.apple.Music"
}
