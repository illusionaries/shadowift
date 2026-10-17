@testable import ShadowDeskKit
import Foundation
@preconcurrency import WebRTC
import XCTest

/// Feeds real H.264 Annex B fixtures through the FFmpeg decoder. The 4:4:4
/// clip must come out at full chroma resolution — that is the whole point of
/// the lossless color mode.
final class H264DecoderTests: XCTestCase {
    func testDecodesY444AtFullChromaResolution() throws {
        let frames = try decodeFixture("test444")
        XCTAssertEqual(frames.count, 10)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 240)
        XCTAssertEqual(frame.chromaWidth, 320)
        XCTAssertEqual(frame.chromaHeight, 240)
    }

    func testDecodesI420AtHalfChromaResolution() throws {
        let frames = try decodeFixture("test420")
        XCTAssertEqual(frames.count, 10)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.chromaWidth, 160)
        XCTAssertEqual(frame.chromaHeight, 120)
    }

    func testI420FallbackDownsamplesChroma() throws {
        let frames = try decodeFixture("test444")
        let frame = try XCTUnwrap(frames.first)
        let i420 = frame.toI420()
        XCTAssertEqual(i420.chromaWidth, 160)
        XCTAssertEqual(i420.chromaHeight, 120)
    }

    // MARK: Helpers

    private func decodeFixture(_ name: String) throws -> [PlanarYUVBuffer] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "h264", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)

        let decoder = FFmpegH264Decoder()
        var buffers: [PlanarYUVBuffer] = []
        decoder.setCallback { frame in
            if let buffer = frame.buffer as? PlanarYUVBuffer {
                buffers.append(buffer)
            }
        }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 4), 0)

        for (index, unit) in Self.accessUnits(in: data).enumerated() {
            let image = RTCEncodedImage()
            image.buffer = unit
            image.timeStamp = UInt32(index * 90000 / 5)
            XCTAssertEqual(
                decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0),
                0
            )
        }
        XCTAssertEqual(decoder.release(), 0)
        return buffers
    }

    /// Splits an Annex B stream into access units. The fixtures are all-intra
    /// (`-g 1`, repeated headers), so every AU starts with an SPS NAL.
    static func accessUnits(in data: Data) -> [Data] {
        var nals: [Data] = []
        var units: [Data] = []
        var cursor = data.startIndex

        func flushNAL(upTo end: Int, nalStart: Int) {
            guard nalStart < end else { return }
            nals.append(data[nalStart..<end])
        }

        var nalStart: Int? = nil
        while cursor + 3 < data.endIndex {
            let isStartCode = data[cursor] == 0 && data[cursor + 1] == 0
                && (data[cursor + 2] == 1 || (data[cursor + 2] == 0 && cursor + 3 < data.endIndex && data[cursor + 3] == 1))
            if isStartCode {
                let headerLength = data[cursor + 2] == 1 ? 3 : 4
                if let start = nalStart {
                    flushNAL(upTo: cursor, nalStart: start)
                }
                nalStart = cursor + headerLength
                cursor += headerLength
            } else {
                cursor += 1
            }
        }
        if let start = nalStart {
            flushNAL(upTo: data.endIndex, nalStart: start)
        }

        var current = Data()
        for nal in nals {
            guard let first = nal.first else { continue }
            let type = first & 0x1F
            if type == 7, !current.isEmpty { // SPS starts the next AU
                units.append(current)
                current = Data()
            }
            current.append(contentsOf: [0, 0, 0, 1])
            current.append(nal)
        }
        if !current.isEmpty { units.append(current) }
        return units
    }
}
