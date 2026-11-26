import AppKit
import Foundation

/// Abstraction for PKCE loopback authorization so sign-in can be tested and cancelled cooperatively.
protocol SpotifyAuthorizationFlowing {
    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode
}

protocol AuthorizationURLPresenter {
    func open(_ url: URL) async throws
}

struct SystemAuthorizationURLPresenter: AuthorizationURLPresenter {
    func open(_ url: URL) async throws {
        let opened = NSWorkspace.shared.open(url)
        guard opened else {
            throw SpotifyAuthorizationFlowError.browserOpenFailed
        }
    }
}

enum SpotifyAuthorizationFlowError: LocalizedError, Equatable {
    case browserOpenFailed

    var errorDescription: String? {
        switch self {
        case .browserOpenFailed:
            SpotiglassL10n.string("auth.flow.browserOpenFailed")
        }
    }
}

struct SpotifyAuthorizationFlow: SpotifyAuthorizationFlowing {
    private let listenerFactory: LoopbackOAuthListenerFactory
    private let presenter: AuthorizationURLPresenter
    private let loopbackPort: UInt16

    /// `loopbackPort` is the port registered with Spotify. Tests pass 0 so the kernel picks a
    /// free one: a fixed port collides with any other test run or Wax sign-in on the Mac (#771).
    init(
        listenerFactory: LoopbackOAuthListenerFactory = LoopbackOAuthListenerFactory(),
        presenter: AuthorizationURLPresenter = SystemAuthorizationURLPresenter(),
        loopbackPort: UInt16 = SpotifyAuthConfiguration.defaultLoopbackPort
    ) {
        self.listenerFactory = listenerFactory
        self.presenter = presenter
        self.loopbackPort = loopbackPort
    }

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval = 120) async throws
        -> SpotifyAuthorizationCode
    {
        let state = try PKCE.makeCodeVerifier(byteCount: 32)
        let codeVerifier = try PKCE.makeCodeVerifier()
        let codeChallenge = PKCE.makeCodeChallenge(for: codeVerifier)
        // Capture the selected app language before the listener's detached
        // socket worker starts; SpotiglassL10n intentionally falls back to
        // English when queried off the main thread.
        let responseCopy = await LoopbackOAuthResponseCopy.localized
        let listener = try listenerFactory.start(
            expectedState: state,
            timeout: timeout,
            port: loopbackPort,
            responseCopy: responseCopy
        )
        let configuration = try SpotifyAuthConfiguration(clientID: clientID, redirectURI: listener.redirectURI)
        let authorizationURL = try configuration.authorizationURL(state: state, codeChallenge: codeChallenge)

        try await presenter.open(authorizationURL)
        let callback = try await withTaskCancellationHandler {
            try await listener.waitForCallback()
        } onCancel: {
            listener.close()
        }

        return SpotifyAuthorizationCode(
            code: callback.code,
            codeVerifier: codeVerifier,
            redirectURI: listener.redirectURI
        )
    }
}

struct SpotifyAuthorizationCode: Equatable {
    let code: String
    let codeVerifier: String
    let redirectURI: URL
}

extension SpotifyAuthorizationFlowing {
    func requestAuthorizationCode(clientID: String) async throws -> SpotifyAuthorizationCode {
        try await requestAuthorizationCode(clientID: clientID, timeout: 120)
    }
}
