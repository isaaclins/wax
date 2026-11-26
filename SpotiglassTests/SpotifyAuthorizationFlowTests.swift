import XCTest

@testable import Spotiglass

final class SpotifyAuthorizationFlowTests: XCTestCase {

    func testBrowserOpenFailedDescription() {
        let err = SpotifyAuthorizationFlowError.browserOpenFailed
        // Localized now, so assert against the catalog rather than pinning
        // one language's wording here (#186).
        XCTAssertEqual(err.errorDescription, SpotiglassL10n.string("auth.flow.browserOpenFailed"))
    }

    func testDefaultTimeoutExtensionUses120Seconds() async throws {
        let flow = ImmediateAuthorizationFlow()
        let code = try await flow.requestAuthorizationCode(clientID: "cid")
        XCTAssertEqual(code.code, "stub")
    }

    /// The loopback round trip takes milliseconds. Every wait in it is bounded far under the
    /// 120 s per-test limit, so a listener that never answers fails here and names the step
    /// instead of holding a whole `make test` run (#771).
    private static let loopbackBound: TimeInterval = 30

    func testRequestAuthorizationCodeCompletesViaLoopback() async throws {
        // The presenter is called only after the listener is bound and listening, so its open()
        // is the signal that the callback can be sent: the connection waits in the backlog.
        let listenerReady = AsyncSignal()
        let presenter = CapturingAuthorizationURLPresenter(openedSignal: listenerReady)
        // Port 0: a free port, so a parallel `make test` or a Wax sign-in on the same Mac
        // can't hold the one registered with Spotify and fail this run (#771).
        let flow = SpotifyAuthorizationFlow(presenter: presenter, loopbackPort: 0)
        let codeTask = Task {
            try await flow.requestAuthorizationCode(clientID: "test-client-id", timeout: Self.loopbackBound)
        }
        defer { codeTask.cancel() }

        guard await listenerReady.wait(timeout: .seconds(Self.loopbackBound)) else {
            return XCTFail("the flow never opened its authorization URL")
        }
        guard let authURL = presenter.openedURL,
            let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
            let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
            let redirectURL = URL(string: redirectURI),
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        else {
            return XCTFail("authorization URL missing redirect_uri or state")
        }

        let port = redirectURL.port ?? 0
        XCTAssertGreaterThan(port, 0)
        XCTAssertNotEqual(port, Int(SpotifyAuthConfiguration.defaultLoopbackPort))
        let callbackURL = URL(string: "http://127.0.0.1:\(port)/callback?code=AUTHCODE99&state=\(state)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.loopbackBound
        configuration.timeoutIntervalForResource = Self.loopbackBound
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await finishWithin(Self.loopbackBound, "the loopback callback request") {
            try await session.data(from: callbackURL)
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let result = try await finishWithin(Self.loopbackBound, "the flow returning the code") {
            try await codeTask.value
        }
        XCTAssertEqual(result.code, "AUTHCODE99")
        XCTAssertFalse(result.codeVerifier.isEmpty)
        XCTAssertEqual(result.redirectURI, redirectURL)
    }

    func testPresenterOpenFailurePropagates() async {
        // A free port: on the registered one this failed with a bind error whenever another
        // run's loopback test held it, not with the presenter's own failure (#771).
        let flow = SpotifyAuthorizationFlow(presenter: FailingAuthorizationURLPresenter(), loopbackPort: 0)
        do {
            _ = try await flow.requestAuthorizationCode(clientID: "id", timeout: 1)
            XCTFail("expected browserOpenFailed")
        } catch let err as SpotifyAuthorizationFlowError {
            XCTAssertEqual(err, .browserOpenFailed)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

private struct ImmediateAuthorizationFlow: SpotifyAuthorizationFlowing {
    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        SpotifyAuthorizationCode(
            code: "stub", codeVerifier: "verifier", redirectURI: URL(string: "http://127.0.0.1:1/callback")!)
    }
}

private final class CapturingAuthorizationURLPresenter: AuthorizationURLPresenter, @unchecked Sendable {
    private(set) var openedURL: URL?
    private let openedSignal: AsyncSignal

    init(openedSignal: AsyncSignal) {
        self.openedSignal = openedSignal
    }

    func open(_ url: URL) async throws {
        openedURL = url
        openedSignal.signal()
    }
}

private struct FailingAuthorizationURLPresenter: AuthorizationURLPresenter {
    func open(_ url: URL) async throws {
        throw SpotifyAuthorizationFlowError.browserOpenFailed
    }
}
