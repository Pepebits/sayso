import Foundation

/// Transporte HTTP inyectable (los tests usan uno falso).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Transporte real sobre `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Sesión propia para una conexión larga (el bot): sin esperar a que vuelva la red dentro de la
    /// misma petición, con plazo total acotado y sin compartir conexiones con el resto de la app.
    public static func dedicated(resourceTimeout: TimeInterval = 120) -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = resourceTimeout
        config.httpMaximumConnectionsPerHost = 4
        return URLSessionTransport(session: URLSession(configuration: config))
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

extension URLRequest {
    /// Petición POST con cuerpo JSON.
    static func postJSON(_ url: URL, body: JSONValue, headers: [String: String] = [:],
                         timeout: TimeInterval = 120) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try body.encoded()
        return request
    }
}
