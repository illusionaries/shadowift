import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ShadowDeskKit

@Suite("History store")
struct HistoryStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowift-tests-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
    }

    @Test("touch moves an entry to the front and deduplicates")
    func touch() {
        let store = HistoryStore(url: temporaryURL())
        store.touch(server: URL(string: "https://a.example/shadowdesk")!, username: "alice")
        store.touch(server: URL(string: "https://b.example/shadowdesk")!, username: "bob")
        store.touch(server: URL(string: "https://a.example/shadowdesk")!, username: "alice")

        #expect(store.entries.count == 2)
        #expect(store.entries.first?.username == "alice")
        #expect(store.lastEntry?.username == "alice")
    }

    @Test("entries are persisted without passwords")
    func persistence() throws {
        let url = temporaryURL()
        let store = HistoryStore(url: url)
        store.touch(server: URL(string: "https://a.example/shadowdesk")!, username: "alice")

        // Same file, new instance.
        let reloaded = HistoryStore(url: url)
        #expect(reloaded.entries.map(\.username) == ["alice"])
        reloaded.touch(server: URL(string: "https://c.example/shadowdesk")!, username: "carol")
        let second = HistoryStore(url: url)
        #expect(second.entries.count == 2)
        #expect(second.entries.first?.username == "carol")

        // Never store credentials in the profile, only the opt-in flag.
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("\"password\""))
    }

    @Test("removal drops the entry")
    func removal() {
        let store = HistoryStore(url: temporaryURL())
        store.touch(server: URL(string: "https://a.example/shadowdesk")!, username: "alice")
        let entry = store.entries[0]
        store.remove(entry)
        #expect(store.entries.isEmpty)
    }
}

@Suite("Cursor image decoding")
struct CursorImageDecoderTests {
    /// Builds a 2x2 PNG with ImageIO so the test does not ship binary data.
    private func makePNG() -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = context.makeImage()!

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    @Test("PNG payloads decode")
    func png() throws {
        let image = try #require(CursorImageDecoder.image(from: makePNG()))
        #expect(image.width == 2)
        #expect(image.height == 2)
    }

    @Test("empty and garbage payloads are rejected")
    func robustness() {
        #expect(CursorImageDecoder.image(from: Data()) == nil)
        #expect(CursorImageDecoder.image(from: Data([0x00, 0x00, 0x02, 0x00, 0xFF])) == nil)
        #expect(CursorImageDecoder.image(from: Data("hello".utf8)) == nil)
    }

    @Test("a CUR container with a BITMAPINFOHEADER entry decodes")
    func cursorBitmap() throws {
        func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
        func le32(_ value: Int) -> Data { Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
        let width = 2
        let height = 2
        let dib = 40 + width * height * 4

        var data = Data()
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00, 0x01, 0x00]) // CUR, 1 entry
        data.append(contentsOf: [UInt8(width), UInt8(height), 0, 0]) // 2x2
        data.append(contentsOf: [0x02, 0x00, 0x02, 0x00]) // hotspot 2,2
        data.append(le32(dib))
        data.append(le32(22)) // offset = header + one entry
        data.append(le32(40)) // BITMAPINFOHEADER
        data.append(le32(width))
        data.append(le32(height * 2)) // XOR + AND mask
        data.append(le16(1))
        data.append(le16(32))
        data.append(le32(0))
        data.append(le32(width * height * 4))
        data.append(le32(0))
        data.append(le32(0))
        data.append(le32(0))
        data.append(le32(0))
        data.append(contentsOf: [0, 255, 0, 255, 0, 255, 0, 255]) // bottom row (green BGRA)
        data.append(contentsOf: [255, 0, 0, 255, 255, 0, 0, 255]) // top row (blue BGRA)

        let image = try #require(CursorImageDecoder.image(from: data))
        #expect(image.width == 2)
        #expect(image.height == 2)
    }

    @Test("a CUR container with a PNG frame decodes")
    func cursorContainer() throws {
        // Minimal CUR: header + one directory entry + the PNG payload.
        let png = makePNG()
        let imageOffset = 6 + 16
        func littleEndian32(_ value: Int) -> Data {
            Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
        }
        var data = Data()
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00, 0x01, 0x00]) // CUR, 1 entry
        data.append(contentsOf: [0x02, 0x02, 0x00, 0x00]) // 2x2, colors 0
        data.append(contentsOf: [0x04, 0x00, 0x04, 0x00]) // hotspot 4,4 (planes/bpp slot)
        data.append(littleEndian32(png.count))
        data.append(littleEndian32(imageOffset))
        data.append(png)

        let image = try #require(CursorImageDecoder.image(from: data))
        #expect(image.width == 2)
        #expect(image.height == 2)
    }
}
