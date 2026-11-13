import AppKit
import ImageIO
import XCTest
@testable import PhotoSelect

final class PhotoSortingTests: XCTestCase {
    func testNaturalNameDirectionsAndSwitchResetsAscending() {
        let entries = ["10.JPG", "2.ARW", "2.JPG", "1.JPG"].map { BrowserEntry(url: URL(fileURLWithPath: "/photos/" + $0), isDirectory: false) }
        var order = PhotoSortOrder()
        XCTAssertEqual(order.photos(entries).map { $0.url.lastPathComponent }, ["1.JPG", "2.ARW", "2.JPG", "10.JPG"])
        order.choose(.name)
        XCTAssertEqual(order.photos(entries).map { $0.url.lastPathComponent }, ["10.JPG", "2.JPG", "2.ARW", "1.JPG"])
        order.choose(.size); XCTAssertTrue(order.ascending)
        order.choose(.size); XCTAssertFalse(order.ascending)
    }
    func testThreeThousandPhotoDateSizeTiesUnknownDatesAndNonPhotos() {
        let entries = (0..<3000).map { index in
            BrowserEntry(url: URL(fileURLWithPath: "/photos/\(index)." + (index.isMultiple(of: 2) ? "ARW" : "JPG")), isDirectory: false,
                         fileBytes: Int64(index % 23), capturedAt: index.isMultiple(of: 9) ? nil : Date(timeIntervalSince1970: Double(index % 17)))
        }
        for criterion in [PhotoSortCriterion.captured, .size] {
            for ascending in [true, false] {
                let order = PhotoSortOrder(criterion: criterion, ascending: ascending)
                let sorted = order.photos(entries)
                XCTAssertEqual(Set(sorted.map(\.url)), Set(entries.map(\.url)))
                for pair in zip(sorted, sorted.dropFirst()) {
                    if criterion == .captured {
                        if pair.0.capturedAt == nil { XCTAssertNil(pair.1.capturedAt) }
                        if let a = pair.0.capturedAt, let b = pair.1.capturedAt, a != b { XCTAssertTrue(ascending ? a < b : a > b) }
                    } else if let a = pair.0.fileBytes, let b = pair.1.fileBytes, a != b { XCTAssertTrue(ascending ? a < b : a > b) }
                    if pair.0.fileBytes == pair.1.fileBytes && criterion == .size || pair.0.capturedAt == pair.1.capturedAt && criterion == .captured {
                        XCTAssertTrue(PhotoSortOrder.nameBefore(pair.0, pair.1))
                    }
                }
            }
        }
        let folder = BrowserEntry(url: URL(fileURLWithPath: "/photos/Folder"), isDirectory: true)
        let document = BrowserEntry(url: URL(fileURLWithPath: "/photos/notes.txt"), isDirectory: false)
        let mixed = [folder, entries[1], document, entries[0]]
        let arranged = PhotoSortOrder(criterion: .size, ascending: true).arrange(mixed)
        XCTAssertEqual(arranged[0].url, folder.url); XCTAssertEqual(arranged[2].url, document.url)
    }
    func testEXIFOriginalDateHasPriorityAndMissingDateHasNoFilesystemFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for (name, properties) in [("dated.jpg", [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05", kCGImagePropertyExifDateTimeDigitized: "2022:01:01 00:00:00"]] as [CFString: Any]), ("missing.jpg", [:])] {
            let url = root.appendingPathComponent(name)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            if name == "dated.jpg" {
                XCTAssertEqual(PhotoSortMetadata.captureDate(url), ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
            } else { XCTAssertNil(PhotoSortMetadata.captureDate(url)) }
        }
    }
    func testRealSonyARWCaptureMetadata() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOSELECT_ARW_SAMPLE_DIRECTORY"] else { throw XCTSkip("Sony sample directory required") }
        for name in ["Sony-A7M3.arw", "Sony-A7M4.ARW"] {
            XCTAssertNotNil(PhotoSortMetadata.captureDate(URL(fileURLWithPath: path).appendingPathComponent(name)), name)
        }
    }
}
