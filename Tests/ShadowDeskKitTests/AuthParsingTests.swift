import Foundation
import Testing

@testable import ShadowDeskKit

@Suite("Login response parsing")
struct AuthParsingTests {
    private let server = URL(string: "https://rdv.example.com/shadowdesk")!

    @Test("302 redirect yields the client id and cookie")
    func successfulRedirect() throws {
        let session = try AuthClient.parseLoginResponse(
            statusCode: 302,
            location: "/shadowdesk/desktop/remote-desktop?clientId=NjY5ZmU2",
            responseURL: URL(string: "https://rdv.example.com/shadowdesk/api/login"),
            setCookie: "session-NjY5ZmU2=ZWU2ZTk; Path=/; Max-Age=86400; HttpOnly",
            body: Data(),
            server: server,
            user: "tester"
        )
        #expect(session.clientID == "NjY5ZmU2")
        #expect(session.cookie == "session-NjY5ZmU2=ZWU2ZTk")
        #expect(session.webSocketURL.absoluteString == "wss://rdv.example.com/shadowdesk/api/ws")
    }

    @Test("relative redirects resolve against the request URL")
    func relativeRedirect() throws {
        let session = try AuthClient.parseLoginResponse(
            statusCode: 302,
            location: "/desktop/remote-desktop?clientId=ABC",
            responseURL: URL(string: "https://example.com/shadowdesk/api/login"),
            setCookie: "session-ABC=xyz; Path=/",
            body: Data(),
            server: server,
            user: "u"
        )
        #expect(session.clientID == "ABC")
        #expect(session.cookie == "session-ABC=xyz")
    }

    @Test("invalid credentials carry the remaining attempt count")
    func invalidCredentials() {
        let body = Data(#"{"details":["{\"type\":\"Invalid credentials\",\"remainingAttempts\":3}"]}"#.utf8)
        #expect(throws: AuthError.invalidCredentials(remainingAttempts: 3)) {
            try AuthClient.parseLoginResponse(
                statusCode: 200,
                location: nil,
                responseURL: nil,
                setCookie: nil,
                body: body,
                server: server,
                user: "u"
            )
        }
    }

    @Test("IP bans carry the remaining minutes")
    func ipBan() {
        let body = Data(#"{"details":["{\"type\":\"IP temporarily banned\",\"remainingMinutes\":5}"]}"#.utf8)
        #expect(throws: AuthError.ipBanned(remainingMinutes: 5)) {
            try AuthClient.parseLoginResponse(
                statusCode: 200,
                location: nil,
                responseURL: nil,
                setCookie: nil,
                body: body,
                server: server,
                user: "u"
            )
        }
    }

    @Test("server address normalisation")
    func addressNormalisation() {
        #expect(ServerAddress.normalize("rdv.example.com/shadowdesk")?.absoluteString
            == "https://rdv.example.com/shadowdesk")
        #expect(ServerAddress.normalize("https://rdv.example.com/shadowdesk/")?.absoluteString
            == "https://rdv.example.com/shadowdesk")
        #expect(ServerAddress.normalize("   ") == nil)
    }
}
