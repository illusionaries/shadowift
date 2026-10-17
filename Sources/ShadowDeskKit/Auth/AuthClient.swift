import Foundation

/// A logged in ShadowDesk web session.
///
/// The manager authenticates both the signalling WebSocket and the REST
/// endpoints with the `session-<clientId>` cookie handed out by
/// `POST /api/login`; keep the whole session together.
public struct AuthSession: Sendable, Equatable {
    /// Canonical server root, without a trailing slash, e.g.
    /// `https://example.com/shadowdesk`.
    public let server: URL
    public let user: String
    /// Opaque client id from the login redirect; it is also the cookie suffix
    /// and is echoed verbatim in the signalling `hello` message.
    public let clientID: String
    /// Pre-formatted `Cookie:` header value.
    public let cookie: String

    public init(server: URL, user: String, clientID: String, cookie: String) {
        self.server = server
        self.user = user
        self.clientID = clientID
        self.cookie = cookie
    }

    /// `wss://host/<base>/api/ws`.
    public var webSocketURL: URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty
            ? "/api/ws"
            : components.path + "/api/ws"
        return components.url!
    }
}

/// Failures reported by the login endpoint.
public enum AuthError: Error, LocalizedError, Equatable {
    case invalidCredentials(remainingAttempts: Int?)
    case ipBanned(remainingMinutes: Int?)
    case rejected(reason: String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidCredentials(attempts):
            if let attempts { return "Invalid credentials (\(attempts) attempts left)" }
            return "Invalid credentials"
        case let .ipBanned(minutes):
            if let minutes { return "IP temporarily banned for \(minutes) minutes" }
            return "IP temporarily banned"
        case let .rejected(reason):
            return "Login rejected: \(reason)"
        case let .malformedResponse(detail):
            return "Unexpected login response: \(detail)"
        }
    }
}

/// Small REST client for the ShadowDesk session endpoints.
public struct AuthClient: Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    public init() {}

    /// `POST /api/login`, handling the 302 that carries the client id.
    public func login(to server: URL, user: String, password: String) async throws -> AuthSession {
        let server = ServerAddress.normalize(server.absoluteString) ?? server
        var request = URLRequest(url: server.appendingPathComponent("api/login"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("id=\(Self.formEncode(user))&password=\(Self.formEncode(password))".utf8)

        let (data, response) = try await Self.session.data(for: request, delegate: RedirectBlocker())
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.malformedResponse("not an HTTP response")
        }
        return try Self.parseLoginResponse(
            statusCode: http.statusCode,
            location: http.value(forHTTPHeaderField: "Location"),
            responseURL: http.url,
            setCookie: http.value(forHTTPHeaderField: "Set-Cookie"),
            body: data,
            server: server,
            user: user
        )
    }

    /// `POST /api/logout`; also releases the remote worker for this session.
    public func logout(_ session: AuthSession) async {
        var components = URLComponents(url: session.server.appendingPathComponent("api/logout"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "clientId", value: session.clientID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(session.cookie, forHTTPHeaderField: "Cookie")
        _ = try? await Self.session.data(for: request)
    }

    /// `POST /api/resetPipeline`, restarting the remote capture/encode chain.
    public func resetPipeline(_ session: AuthSession) async throws -> Bool {
        var components = URLComponents(
            url: session.server.appendingPathComponent("api/resetPipeline"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "clientId", value: session.clientID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(session.cookie, forHTTPHeaderField: "Cookie")
        let (data, _) = try await Self.session.data(for: request)

        struct Payload: Decodable {
            struct Data: Decodable { let isSuccess: Bool }
            let data: Data
        }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.data.isSuccess ?? false
    }

    // MARK: - Parsing (internal so it can be unit tested without a server)

    static func parseLoginResponse(
        statusCode: Int,
        location: String?,
        responseURL: URL?,
        setCookie: String?,
        body: Data,
        server: URL,
        user: String
    ) throws -> AuthSession {
        switch statusCode {
        case 300..<400:
            guard let location else {
                throw AuthError.malformedResponse("login redirected without a Location header")
            }
            let resolved = URL(string: location, relativeTo: responseURL)?.absoluteURL
                ?? URL(string: location)
            guard let resolved,
                  let clientID = URLComponents(url: resolved, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "clientId" })?.value
            else {
                throw AuthError.malformedResponse("login redirect \(location) has no clientId")
            }
            guard let cookie = sessionCookie(from: setCookie) else {
                throw AuthError.malformedResponse("login succeeded but no session cookie was set")
            }
            return AuthSession(server: server, user: user, clientID: clientID, cookie: cookie)

        case 200:
            struct Payload: Decodable { let details: [String] }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: body),
                  let detail = payload.details.first
            else {
                throw AuthError.malformedResponse(Self.truncate(body))
            }
            return try parseDetail(detail)

        default:
            throw AuthError.malformedResponse("HTTP \(statusCode): \(Self.truncate(body))")
        }
    }

    /// The failure detail is itself a JSON blob, e.g.
    /// `{"type":"Invalid credentials","remainingAttempts":3}`.
    static func parseDetail(_ detail: String) throws -> AuthSession {
        struct Detail: Decodable {
            let type: String
            let remainingAttempts: Int?
            let remainingMinutes: Int?
        }
        guard let data = detail.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Detail.self, from: data)
        else {
            throw AuthError.rejected(reason: detail)
        }
        switch parsed.type {
        case "Invalid credentials":
            throw AuthError.invalidCredentials(remainingAttempts: parsed.remainingAttempts)
        case "IP temporarily banned":
            throw AuthError.ipBanned(remainingMinutes: parsed.remainingMinutes)
        default:
            throw AuthError.rejected(reason: parsed.type)
        }
    }

    /// Extracts `session-…=…` out of a possibly multi cookie header.
    static func sessionCookie(from header: String?) -> String? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") {
            let cookie = part.trimmingCharacters(in: .whitespaces)
            guard cookie.hasPrefix("session-") else { continue }
            return cookie.components(separatedBy: ";").first
        }
        return nil
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func truncate(_ data: Data, limit: Int = 200) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

/// Suppresses automatic redirect following so the 302 can be inspected.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Normalisation for user supplied server addresses.
public enum ServerAddress {
    /// Adds `https://` when no scheme is present and drops trailing slashes.
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }
}
