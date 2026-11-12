import XCTest
@testable import PhotoSelect

final class EmbeddedPreviewTests: XCTestCase {
    // These are marker-structure fixtures, not camera RAW sensor data or JPEG
    // codec tests. Pipeline tests separately decode actual JPEG bytes via ImageIO.
    private func jpeg(width: Int, height: Int, progressive: Bool = false, precision: UInt8 = 8, frameMarker: UInt8? = nil) -> Data {
        func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE2, 0, 18]
        bytes += Array("ICC_PROFILE\0".utf8) + [1, 1, 0x10, 0x20]
        bytes += [0xFF, frameMarker ?? (progressive ? 0xC2 : 0xC0), 0, 17, precision] + word(height) + word(width)
        bytes += [3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]
        let scan: [UInt8] = [0xFF, 0xDA, 0, 12, 3, 1, 0, 2, 0, 3, 0, 0, 63, 0]
        bytes += scan + [0x11, 0xFF, 0, 0xD8, 0x22, 0xFF, 0xD0, 0x33]
        if progressive { bytes += scan + [0x22, 0xFF, 0, 0x44] }
        bytes += [0xFF, 0xD9]
        return Data(bytes)
    }

    private struct TIFF {
        var data = Data(repeating: 0, count: 1024)
        let little: Bool
        init(little: Bool = true) {
            self.little = little
            data[0] = little ? 0x49 : 0x4D; data[1] = data[0]
            put16(42, at: 2); put32(8, at: 4)
        }
        mutating func put16(_ value: Int, at offset: Int) {
            data[offset] = UInt8((value >> (little ? 0 : 8)) & 255)
            data[offset + 1] = UInt8((value >> (little ? 8 : 0)) & 255)
        }
        mutating func put32(_ value: Int, at offset: Int) {
            for index in 0..<4 { data[offset + index] = UInt8((value >> (8 * (little ? index : 3 - index))) & 255) }
        }
        // (tag, TIFF type, count, value or absolute TIFF-relative payload offset)
        mutating func ifd(_ offset: Int, _ entries: [(Int, Int, Int, Int)], next: Int = 0) {
            put16(entries.count, at: offset)
            for (index, entry) in entries.enumerated() {
                let position = offset + 2 + index * 12
                put16(entry.0, at: position); put16(entry.1, at: position + 2)
                put32(entry.2, at: position + 4)
                if entry.1 == 3 && entry.2 == 1 { put16(entry.3, at: position + 8) }
                else { put32(entry.3, at: position + 8) }
            }
            put32(next, at: offset + 2 + entries.count * 12)
        }
        mutating func append(_ bytes: Data) -> Int {
            let offset = data.count; data.append(bytes); return offset
        }
    }
    private func extract(_ bytes: Data) throws -> EmbeddedJPEG {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ARW")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try EmbeddedPreview.extract(from: url)
    }

    func testLargestLinkedPreviewWinsOverThumbnailAndPrimaryPreview() throws {
        for little in [true, false] {
            var tiff = TIFF(little: little)
            let primary = jpeg(width: 1616, height: 1080), full = jpeg(width: 7008, height: 4672)
            let primaryOffset = tiff.append(primary), thumbnailOffset = tiff.append(jpeg(width: 160, height: 120))
            let fullOffset = tiff.append(full)
            tiff.ifd(8, [(0x112, 3, 1, 6), (0x201, 4, 1, primaryOffset), (0x202, 4, 1, primary.count),
                         (0x14A, 4, 1, 256), (0x8769, 4, 1, 128)], next: 384)
            tiff.ifd(128, [(0xA002, 4, 1, 7008), (0xA003, 4, 1, 4672), (0xA001, 3, 1, 1)])
            tiff.ifd(256, [(0x100, 4, 1, 7168), (0x101, 4, 1, 5120)], next: 512)
            tiff.ifd(384, [(0x201, 4, 1, thumbnailOffset), (0x202, 4, 1, jpeg(width: 160, height: 120).count)])
            tiff.ifd(512, [(0x201, 4, 1, fullOffset), (0x202, 4, 1, full.count)])
            let result = try extract(tiff.data)
            XCTAssertEqual(result.data, full) // ICC and entropy bytes are untouched.
            XCTAssertEqual(result.pixelWidth, 7008); XCTAssertEqual(result.pixelHeight, 4672)
            XCTAssertEqual(result.orientation, 6)
            XCTAssertEqual(result.sensorSize, CGSize(width: 7008, height: 4672))
            XCTAssertEqual(result.colorSpaceHint, .sRGB)
        }
    }

    func testSonyMakerNoteHeaderAnd32BytePreviewPrefix() throws {
        for header in ["SONY DSC ", "SONY CAM ", "SONY MOBILE", "\0\0SONY PIC", "VHAB", ""] {
            var tiff = TIFF()
            let primary = jpeg(width: 1616, height: 1080), full = jpeg(width: 6000, height: 4000)
            let primaryOffset = tiff.append(primary)
            let payloadOffset = tiff.append(Data(repeating: 0x35, count: 32) + full)
            let note = 512
            let prefix = header.isEmpty ? Data() : Data(Array(header.utf8) + Array(repeating: 0, count: 12 - header.utf8.count))
            tiff.data.replaceSubrange(note..<(note + prefix.count), with: prefix)
            tiff.ifd(note + prefix.count, [(0x2001, 7, full.count + 32, payloadOffset)])
            tiff.ifd(8, [(0x201, 4, 1, primaryOffset), (0x202, 4, 1, primary.count), (0x8769, 4, 1, 128)])
            tiff.ifd(128, [(0x927C, 7, prefix.count + 18, note)])
            XCTAssertEqual(try extract(tiff.data).data, full)
        }
    }

    func testAdobeRGBHintUsesOuterExifInteropWhenJPEGHasNoExif() throws {
        var tiff = TIFF()
        let image = jpeg(width: 1616, height: 1080), offset = tiff.append(image)
        tiff.ifd(8, [(0x112, 3, 1, 8), (0x201, 4, 1, offset), (0x202, 4, 1, image.count), (0x8769, 4, 1, 128)])
        tiff.ifd(128, [(0xA001, 3, 1, 65535), (0xA005, 4, 1, 256), (0xA002, 4, 1, 6000), (0xA003, 4, 1, 4000)])
        tiff.ifd(256, [(1, 2, 4, 0)])
        tiff.data.replaceSubrange(266..<270, with: Data("R03\0".utf8))
        let result = try extract(tiff.data)
        XCTAssertEqual(result.colorSpaceHint, .adobeRGB)
        XCTAssertEqual(result.orientation, 8)
        XCTAssertEqual(result.sensorSize, CGSize(width: 6000, height: 4000))
    }

    func testUnknownLayoutRecoveryFindsLargestCompleteProgressiveJPEG() throws {
        var tiff = TIFF()
        tiff.ifd(8, [])
        let small = jpeg(width: 160, height: 120), big = jpeg(width: 4000, height: 6000, progressive: true)
        _ = tiff.append(small); _ = tiff.append(Data(repeating: 0x11, count: 117)); _ = tiff.append(big)
        let result = try extract(tiff.data)
        XCTAssertEqual(result.data, big)
        XCTAssertEqual(result.pixelWidth, 4000); XCTAssertEqual(result.pixelHeight, 6000)
    }

    func testTinyOnlyOrTruncatedJPEGIsNeverUsedAsLargePreview() throws {
        var tiff = TIFF()
        tiff.ifd(8, [])
        _ = tiff.append(jpeg(width: 640, height: 480))
        _ = tiff.append(Data(jpeg(width: 6000, height: 4000).dropLast(2)))
        XCTAssertThrowsError(try extract(tiff.data))
    }

    func testCyclicIFDAndOversizedOffsetsAreBounded() throws {
        var tiff = TIFF()
        tiff.ifd(8, [(0x201, 4, 1, 0xFFFFFFF0), (0x202, 4, 1, 4096), (0x14A, 4, 1, 8)], next: 8)
        XCTAssertThrowsError(try extract(tiff.data))
        let image = jpeg(width: 2000, height: 1500), offset = tiff.append(image)
        tiff.ifd(8, [(0x201, 4, 1, offset), (0x202, 4, 1, image.count), (0x14A, 4, 1, 8)], next: 8)
        XCTAssertEqual(try extract(tiff.data).data, image)
        tiff.put32(0xFFFFFFF0, at: 4)
        XCTAssertThrowsError(try extract(tiff.data))
    }

    func testCFASensorStripIsNotScannedOrSelectedOverCameraPreview() throws {
        var tiff = TIFF()
        let preview = jpeg(width: 1616, height: 1080)
        // A plausible 8-bit JPEG marker stream inside a RAW strip still must
        // not be searched as a camera preview just because its area is larger.
        let sensorPattern = jpeg(width: 7008, height: 4672)
        let previewOffset = tiff.append(preview), sensorOffset = tiff.append(sensorPattern)
        tiff.ifd(8, [(0x201, 4, 1, previewOffset), (0x202, 4, 1, preview.count), (0x14A, 4, 1, 256)])
        tiff.ifd(256, [(0x103, 3, 1, 7), (0x106, 3, 1, 32803), (0x102, 3, 1, 14),
                       (0x115, 3, 1, 1), (0x111, 4, 1, sensorOffset), (0x117, 4, 1, sensorPattern.count)])
        XCTAssertEqual(try extract(tiff.data).data, preview)
        // Even the unknown-layout recovery scan must exclude this known RAW
        // strip when no adequate camera preview exists.
        let tiny = jpeg(width: 160, height: 120)
        XCTAssertEqual(tiny.count, preview.count)
        tiff.data.replaceSubrange(previewOffset..<(previewOffset + preview.count), with: tiny)
        tiff.ifd(8, [(0x14A, 4, 1, 256)])
        XCTAssertThrowsError(try extract(tiff.data))
    }

    func testEightBitYCbCrJPEGStripRemainsAProcessedPreview() throws {
        var tiff = TIFF()
        let preview = jpeg(width: 7008, height: 4672), offset = tiff.append(preview)
        tiff.ifd(8, [(0x103, 3, 1, 7), (0x106, 3, 1, 6), (0x102, 3, 1, 8),
                     (0x115, 3, 1, 3), (0x111, 4, 1, offset), (0x117, 4, 1, preview.count)])
        XCTAssertEqual(try extract(tiff.data).data, preview)
    }

    func testLosslessBayerAndNonEightBitFramesCannotBecomePreview() throws {
        for (precision, marker) in [(UInt8(14), UInt8(0xC3)), (8, 0xC3), (14, 0xC0)] {
            var tiff = TIFF()
            let rawFrame = jpeg(width: 6000, height: 4000, precision: precision, frameMarker: marker)
            let offset = tiff.append(rawFrame)
            tiff.ifd(8, [(0x201, 4, 1, offset), (0x202, 4, 1, rawFrame.count)])
            _ = tiff.append(jpeg(width: 160, height: 120))
            XCTAssertThrowsError(try extract(tiff.data))
        }
    }

}
