import AppKit
import Foundation

/// Serialised access to the system pasteboard.
///
/// `NSPasteboard` has no change notification (Apple's documented answer is to
/// poll `changeCount`) and it is *not* thread safe, so every read and write
/// goes through one dedicated queue. Reads only happen when the change count
/// moved, and the string is fetched off the main thread because that can be a
/// synchronous round trip to the pasteboard server.
final class PasteboardBridge: @unchecked Sendable {
    struct Snapshot: Sendable {
        var changeCount: Int
        var text: String?
        /// Password managers and friends flag entries that must not be
        /// recorded or forwarded; `org.nspasteboard.{Concealed,Transient}Type`.
        var isPrivate: Bool
    }

    private let pasteboard = NSPasteboard.general
    private let queue = DispatchQueue(label: "dev.shadowift.pasteboard")

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let types = self.pasteboard.types?.map(\.rawValue) ?? []
                let isPrivate = types.contains("org.nspasteboard.ConcealedType")
                    || types.contains("org.nspasteboard.TransientType")
                continuation.resume(returning: Snapshot(
                    changeCount: self.pasteboard.changeCount,
                    text: self.pasteboard.string(forType: .string),
                    isPrivate: isPrivate
                ))
            }
        }
    }

    /// Replaces the clipboard and returns the new change count, so the caller
    /// can ignore its own write.
    @discardableResult
    func write(_ text: String) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                continuation.resume(returning: self.pasteboard.changeCount)
            }
        }
    }
}
