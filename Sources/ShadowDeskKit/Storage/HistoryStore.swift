import Foundation

/// One remembered server/account pair. The JSON layout is kept stable so
/// existing profiles keep working.
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var server: String
    public var username: String
    public var lastUsed: Date

    public var id: String { "\(server)\u{0}\(username)" }

    public init(server: String, username: String, lastUsed: Date = .now) {
        self.server = server
        self.username = username
        self.lastUsed = lastUsed
    }
}

/// Small on-disk profile: which servers/accounts were used and whether the
/// user wants passwords in the keychain. Passwords are never written here.
public final class HistoryStore: @unchecked Sendable {
    private struct Payload: Codable {
        var entries: [HistoryEntry] = []
        var last: String?
        var savePasswords: Bool = true
    }

    private let lock = NSLock()
    private var payload: Payload
    private let url: URL

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("shadowdesk/history.json")
    }

    public init(url: URL = HistoryStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let payload = try? Self.decoder.decode(Payload.self, from: data) {
            self.payload = payload
        } else {
            payload = Payload()
        }
    }

    public var entries: [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return payload.entries.sorted { $0.lastUsed > $1.lastUsed }
    }

    public var savePasswords: Bool {
        get { lock.lock(); defer { lock.unlock() }; return payload.savePasswords }
        set { lock.lock(); payload.savePasswords = newValue; lock.unlock(); save() }
    }

    public var lastEntry: HistoryEntry? {
        entries.first
    }

    /// Records a successful sign-in and moves the entry to the front.
    public func touch(server: URL, username: String) {
        let entry = HistoryEntry(server: server.absoluteString, username: username)
        lock.lock()
        payload.entries.removeAll { $0.id == entry.id }
        payload.entries.insert(entry, at: 0)
        payload.entries = Array(payload.entries.prefix(20))
        payload.last = entry.id
        lock.unlock()
        save()
    }

    public func remove(_ entry: HistoryEntry) {
        lock.lock()
        payload.entries.removeAll { $0.id == entry.id }
        lock.unlock()
        save()
    }

    private func save() {
        lock.lock()
        let payload = payload
        lock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try Self.encoder.encode(payload)
            // No NSFileProtection class here: on macOS 27 data-protected
            // files get a provenance xattr that ad-hoc signed builds cannot
            // read back, even from the process that wrote them. POSIX 0600
            // already keeps the profile private.
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // A broken profile must never stop the app from signing in.
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
