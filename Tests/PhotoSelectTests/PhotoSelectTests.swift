import XCTest
@testable import PhotoSelect

final class PhotoSelectTests: XCTestCase {
    func testClickZoomAllPercentagesAcrossDisplayScales() {
        let image = CGSize(width: 6000, height: 4000)
        let view = CGSize(width: 1200, height: 800)
        let cursor = CGPoint(x: 480, y: 320)
        for backing: CGFloat in [1, 1.5, 2] {
            for percent in ClickZoomPreference.choices {
                let factor = CGFloat(percent) / 100
                let rect = ZoomGeometry.rect(image: image, view: view, cursor: cursor,
                                             backingScale: backing, magnification: factor)
                XCTAssertEqual(rect.width * backing, image.width * factor, accuracy: 0.001)
                XCTAssertEqual(rect.height * backing, image.height * factor, accuracy: 0.001)
                // The image point under the cursor in Fit remains under it at every zoom.
                XCTAssertEqual((cursor.x - rect.minX) / rect.width, 0.4, accuracy: 0.0001)
                XCTAssertEqual((cursor.y - rect.minY) / rect.height, 0.4, accuracy: 0.0001)
            }
        }
    }
    func testClickZoomPreferencePersistsAndRejectsInvalidValues() {
        let suite = "PhotoSelectTests.zoom." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ClickZoomPreference.percent(in: defaults), 100)
        for percent in ClickZoomPreference.choices {
            ClickZoomPreference.save(percent, in: defaults)
            XCTAssertEqual(ClickZoomPreference.percent(in: UserDefaults(suiteName: suite)!), percent)
        }
        ClickZoomPreference.save(205, in: defaults)
        XCTAssertEqual(ClickZoomPreference.percent(in: defaults), 200)
        defaults.set(999, forKey: ClickZoomPreference.key)
        XCTAssertEqual(ClickZoomPreference.percent(in: defaults), 100)
    }
    func testExtensionsAndRawJpegPair() {
        XCTAssertTrue(Photo.accepts(URL(fileURLWithPath: "/a/DSC001.ARW")))
        XCTAssertTrue(Photo.accepts(URL(fileURLWithPath: "/a/DSC001.JPG")))
        XCTAssertTrue(Photo.accepts(URL(fileURLWithPath: "/a/image.JpEg")))
        XCTAssertFalse(Photo.accepts(URL(fileURLWithPath: "/a/image.png")))
        XCTAssertNotEqual(Photo(url: URL(fileURLWithPath: "/a/DSC001.ARW")), Photo(url: URL(fileURLWithPath: "/a/DSC001.JPG")))
    }
    func testRetinaOneSourcePixelPerPhysicalPixel() {
        let rect = ZoomGeometry.rect(image: CGSize(width: 6000, height: 4000), view: CGSize(width: 1200, height: 800),
                                     cursor: CGPoint(x: 600, y: 400), backingScale: 2)
        XCTAssertEqual(rect.width, 3000)
        XCTAssertEqual(rect.height, 2000)
        XCTAssertEqual(rect.midX, 600)
        XCTAssertEqual(rect.midY, 400)
    }
    func testZoomEdgesNeverRevealEmptySpaceForLargeImage() {
        let size = CGSize(width: 1200, height: 800)
        for point in [CGPoint.zero, CGPoint(x: 1200, y: 800), CGPoint(x: 800, y: 100)] {
            let rect = ZoomGeometry.rect(image: CGSize(width: 6000, height: 4000), view: size, cursor: point, backingScale: 2)
            XCTAssertLessThanOrEqual(rect.minX, 0); XCTAssertLessThanOrEqual(rect.minY, 0)
            XCTAssertGreaterThanOrEqual(rect.maxX, size.width); XCTAssertGreaterThanOrEqual(rect.maxY, size.height)
        }
    }
    func testFolderEnumerationIsNonRecursiveAndKeepsPairs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["DSC1.ARW", "DSC1.JPG", "DSC2.jpeg", "ignore.png", ".hidden.jpg"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appendingPathComponent("nested.jpg"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.jpg"), withDestinationURL: sub.appendingPathComponent("nested.jpg"))
        XCTAssertEqual(try FolderReader.entries(root, directories: false).map(\.lastPathComponent), ["DSC1.ARW", "DSC1.JPG", "DSC2.jpeg"])
        XCTAssertEqual(try FolderReader.entries(root, directories: true).map(\.lastPathComponent), ["sub"])
        XCTAssertThrowsError(try FolderReader.entries(root.appendingPathComponent("missing"), directories: false))
    }
    func testCorruptImageReturnsFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("bad.jpg")
        try Data("broken image".utf8).write(to: url)
        let done = expectation(description: "decode failure")
        let pipeline = ImagePipeline()
        pipeline.load(Photo(url: url), lease: FolderLease(folder), quality: .preview) { result, _ in
            if case .success = result { XCTFail("Corrupt file must not decode") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}
