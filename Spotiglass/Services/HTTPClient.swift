import Foundation

protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum HTTPClientError: Error {
    case invalidResponse
}

extension URLSession: HTTPClient {
    /// Every request goes into the log with its status, time and, when it fails, the whole
    /// error (#734).
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await CallLog.http(request, session: self)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}
