import Darwin
import Foundation

struct OAuthCallback: Equatable {
    let code: String
}

/// User-facing copy for the browser response. It is resolved before the socket
/// worker starts because ``SpotiglassL10n`` intentionally falls back to English
/// when queried off the main thread.
struct LoopbackOAuthResponseCopy: Equatable, Sendable {
    let invalidRequest: String
    let success: String
    let failure: String

    @MainActor
    static var localized: Self {
        Self(
            invalidRequest: SpotiglassL10n.string("auth.callback.response.invalidRequest"),
            success: SpotiglassL10n.string("auth.callback.response.success"),
            failure: SpotiglassL10n.string("auth.callback.response.failure")
        )
    }
}

enum LoopbackOAuthCallbackError: Error, Equatable, LocalizedError {
    case invalidRequest
    case oauthError(String, String?)
    case missingState
    case stateMismatch
    case missingCode
    case socketSetupFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        // These reach the connect screen, so they come from the catalog. The
        // OAuth code and the failing socket step are developer facts and live
        // in diagnosticDetails instead (#186, #187).
        case .invalidRequest:
            SpotiglassL10n.string("auth.callback.invalidRequest")
        case let .oauthError(code, description):
            description ?? SpotiglassL10n.format("auth.callback.oauthError", code)
        case .missingState:
            SpotiglassL10n.string("auth.callback.missingState")
        case .stateMismatch:
            SpotiglassL10n.string("auth.callback.stateMismatch")
        case .missingCode:
            SpotiglassL10n.string("auth.callback.missingCode")
        case .socketSetupFailed:
            SpotiglassL10n.string("auth.callback.socketSetupFailed")
        case .timedOut:
            SpotiglassL10n.string("auth.callback.timedOut")
        }
    }

    /// The OAuth error code and the socket step that failed. Both are for a bug
    /// report, so they stay off the connect screen but are not thrown away.
    var diagnosticDetails: String? {
        switch self {
        case let .oauthError(code, description):
            return description.map { "oauth error: \(code) (\($0))" } ?? "oauth error: \(code)"
        case let .socketSetupFailed(step):
            return "loopback listener failed at step: \(step)"
        case .invalidRequest, .missingState, .stateMismatch, .missingCode, .timedOut:
            return nil
        }
    }
}

enum LoopbackOAuthCallbackValidator {
    static func validate(url: URL, expectedState: String) throws -> OAuthCallback {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value
            throw LoopbackOAuthCallbackError.oauthError(error, description)
        }

        guard let state = items.first(where: { $0.name == "state" })?.value else {
            throw LoopbackOAuthCallbackError.missingState
        }
        guard state == expectedState else {
            throw LoopbackOAuthCallbackError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw LoopbackOAuthCallbackError.missingCode
        }

        return OAuthCallback(code: code)
    }
}

final class ActiveLoopbackOAuthListener {
    let redirectURI: URL

    private let socketDescriptor: Int32
    private let expectedState: String
    private let timeout: TimeInterval
    /// How long one accepted connection may stay silent before it is dropped. A browser sends
    /// its request together with the connection, so this only ever ends a connection that
    /// would never send one.
    private let clientIdleTimeout: TimeInterval
    private let responseCopy: LoopbackOAuthResponseCopy
    private var didClose = false
    private var didTimeOut = false
    private var activeClient: Int32 = -1
    private let closeLock = NSLock()

    init(
        socketDescriptor: Int32,
        port: UInt16,
        expectedState: String,
        timeout: TimeInterval,
        clientIdleTimeout: TimeInterval,
        responseCopy: LoopbackOAuthResponseCopy
    ) {
        self.clientIdleTimeout = clientIdleTimeout
        self.socketDescriptor = socketDescriptor
        self.redirectURI = SpotifyAuthConfiguration.loopbackRedirectURI(port: port)
        self.expectedState = expectedState
        self.timeout = timeout
        self.responseCopy = responseCopy
    }

    deinit {
        close()
    }

    func waitForCallback() async throws -> OAuthCallback {
        try await withThrowingTaskGroup(of: OAuthCallback.self) { group in
            group.addTask {
                try await self.acceptSingleCallback()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                self.close(timedOut: true)
                throw LoopbackOAuthCallbackError.timedOut
            }

            guard let result = try await group.next() else {
                throw LoopbackOAuthCallbackError.invalidRequest
            }
            group.cancelAll()
            close()
            return result
        }
    }

    private func acceptSingleCallback() async throws -> OAuthCallback {
        let responseCopy = self.responseCopy
        return try await Task.detached(priority: .userInitiated) {
            while true {
                // After close() a dropped read lands back here: the listening descriptor is
                // closed and its number may already belong to another socket, so never accept
                // on it again.
                guard !self.isClosed else {
                    throw self.endedError
                }
                var address = sockaddr()
                var length = socklen_t(MemoryLayout<sockaddr>.size)
                let client = Darwin.accept(self.socketDescriptor, &address, &length)
                guard client >= 0 else {
                    throw self.endedError
                }
                guard self.track(client: client) else {
                    // close() ran while accept() returned: the listener is done.
                    Darwin.close(client)
                    throw self.endedError
                }
                defer { self.finish(client: client) }
                Self.boundReads(on: client, idleTimeout: self.clientIdleTimeout)

                var buffer = [UInt8](repeating: 0, count: 4096)
                let bufferCount = buffer.count
                let count = buffer.withUnsafeMutableBytes { pointer in
                    Darwin.read(client, pointer.baseAddress, bufferCount)
                }
                guard count > 0 else {
                    // A connection that sends nothing (a browser's speculative connection, or a
                    // client that gave up) must not hold the listener: drop it and take the next.
                    // close() also lands here, and the next accept() then fails (#771).
                    continue
                }
                guard let request = String(bytes: buffer.prefix(count), encoding: .utf8),
                      let requestLine = request.components(separatedBy: "\r\n").first else {
                    self.writeResponse(to: client, status: "400 Bad Request", body: responseCopy.invalidRequest)
                    throw LoopbackOAuthCallbackError.invalidRequest
                }

                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2,
                      parts[0] == "GET",
                      let callbackURL = URL(string: "http://127.0.0.1\(parts[1])") else {
                    self.writeResponse(to: client, status: "400 Bad Request", body: responseCopy.invalidRequest)
                    throw LoopbackOAuthCallbackError.invalidRequest
                }

                do {
                    let callback = try LoopbackOAuthCallbackValidator.validate(url: callbackURL, expectedState: self.expectedState)
                    self.writeResponse(to: client, status: "200 OK", body: responseCopy.success)
                    return callback
                } catch {
                    self.writeResponse(to: client, status: "400 Bad Request", body: responseCopy.failure)
                    throw error
                }
            }
        }.value
    }

    private static func boundReads(on client: Int32, idleTimeout: TimeInterval) {
        let wholeSeconds = idleTimeout.rounded(.down)
        var limit = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((idleTimeout - wholeSeconds) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, size)
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, size)
    }

    /// Why the listening socket stopped. The timeout closes it, which also wakes accept(), and
    /// either child can reach the task group first: both must then say the wait timed out, or
    /// sign-in reports a timeout as an invalid request depending on scheduling (#771).
    private var endedError: LoopbackOAuthCallbackError {
        closeLock.lock()
        defer { closeLock.unlock() }
        return didTimeOut ? .timedOut : .invalidRequest
    }

    private var isClosed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return didClose
    }

    /// Remembers the accepted connection so close() can end a read that is in flight.
    /// Returns false when the listener is already closed.
    private func track(client: Int32) -> Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !didClose else { return false }
        activeClient = client
        return true
    }

    /// Closes the accepted connection under the lock, so close() never shuts down a
    /// descriptor number the system has already handed to someone else.
    private func finish(client: Int32) {
        closeLock.lock()
        defer { closeLock.unlock() }
        if activeClient == client { activeClient = -1 }
        Darwin.close(client)
    }

    private func writeResponse(to client: Int32, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        _ = response.withCString { pointer in
            Darwin.write(client, pointer, strlen(pointer))
        }
    }

    func close() {
        close(timedOut: false)
    }

    private func close(timedOut: Bool) {
        closeLock.lock()
        defer { closeLock.unlock() }

        guard !didClose else { return }
        didClose = true
        didTimeOut = timedOut
        // Ends a read on an accepted connection too, so the listener's timeout bounds the
        // whole exchange and not only the wait for a connection (#771).
        if activeClient >= 0 {
            Darwin.shutdown(activeClient, SHUT_RDWR)
        }
        Darwin.shutdown(socketDescriptor, SHUT_RDWR)
        Darwin.close(socketDescriptor)
    }
}

struct LoopbackOAuthListenerFactory {
    func start(
        expectedState: String,
        timeout: TimeInterval = 120,
        port: UInt16 = SpotifyAuthConfiguration.defaultLoopbackPort,
        clientIdleTimeout: TimeInterval = 5,
        responseCopy: LoopbackOAuthResponseCopy
    ) throws -> ActiveLoopbackOAuthListener {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw LoopbackOAuthCallbackError.socketSetupFailed("socket")
        }

        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(descriptor)
            throw LoopbackOAuthCallbackError.socketSetupFailed("setsockopt")
        }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(port).bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw LoopbackOAuthCallbackError.socketSetupFailed("bind")
        }

        // Room for the real callback behind a connection that never sends anything (#771).
        guard Darwin.listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw LoopbackOAuthCallbackError.socketSetupFailed("listen")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw LoopbackOAuthCallbackError.socketSetupFailed("getsockname")
        }

        return ActiveLoopbackOAuthListener(
            socketDescriptor: descriptor,
            port: UInt16(bigEndian: boundAddress.sin_port),
            expectedState: expectedState,
            timeout: timeout,
            clientIdleTimeout: clientIdleTimeout,
            responseCopy: responseCopy
        )
    }
}
