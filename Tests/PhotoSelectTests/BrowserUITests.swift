import AppKit
import XCTest
@testable import PhotoSelect

final class BrowserUITests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor
    private func waitUntil(_ description: String, condition: @escaping () -> Bool) {
        let done = expectation(description: description)
        let deadline = Date().addingTimeInterval(5)
        func poll() {
            if condition() { done.fulfill() }
            else if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { poll() } }
        }
        poll(); wait(for: [done], timeout: 6)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor
    private func jpegData() -> Data {
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .jpeg, properties: [:])!
    }
    @MainActor
    func testBrowserStartsWithTreeGridAndPreviewColumns() throws {
        _ = NSApplication.shared
        let root = try folder()
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: nil)
        defer { browser.close() }
        let views = descendants(browser.window!.contentView!)
        let split = try XCTUnwrap(views.compactMap { $0 as? NSSplitView }.first)
        XCTAssertEqual(split.arrangedSubviews.count, 3)
        XCTAssertTrue(split.arrangedSubviews.allSatisfy { $0.bounds.width >= 180 })
        XCTAssertTrue(descendants(split.arrangedSubviews[0]).contains { $0 is NSOutlineView })
        XCTAssertTrue(descendants(split.arrangedSubviews[1]).contains { $0 is PhotoCollectionView })
        XCTAssertTrue(split.arrangedSubviews[2] is PreviewPane)
    }
    @MainActor
    func testPreviewFilenameIsBelowImage() {
        _ = NSApplication.shared
        let pane = PreviewPane(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        pane.select(Photo(url: URL(fileURLWithPath: "/photos/DSC0001.ARW")))
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.filename.stringValue, "DSC0001.ARW")
        XCTAssertLessThan(pane.filename.frame.maxY, pane.imageView.superview!.frame.minY)
    }
    @MainActor
    func testSelectingThumbnailChangesRightPreview() throws {
        _ = NSApplication.shared
        let root = try folder()
        let data = jpegData()
        for name in ["1.jpg", "2.jpg"] { try data.write(to: root.appendingPathComponent(name)) }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: root)
        defer { browser.close() }
        let views = descendants(browser.window!.contentView!)
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("first preview decoded") { preview.filename.stringValue == "1.jpg" && preview.imageView.image != nil }
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 2)
        grid.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        browser.collectionView(grid, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        waitUntil("second preview decoded") { preview.filename.stringValue == "2.jpg" && preview.imageView.image != nil }
    }
    @MainActor
    func testTrashDuringNavigationPreservesSelectionAndUpdatesTagBadge() throws {
        _ = NSApplication.shared
        let root = try folder(), trash = try folder()
        let data = jpegData()
        for name in ["1.jpg", "2.jpg"] { try data.write(to: root.appendingPathComponent(name)) }
        let service = PhotoTrash { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")),
                                        trashService: service, initialFolder: root)
        defer { browser.close() }
        let views = descendants(browser.window!.contentView!)
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("first photo ready") { preview.filename.stringValue == "1.jpg" && preview.imageView.image != nil }
        grid.trashCurrent?()
        grid.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        browser.collectionView(grid, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        waitUntil("delete preserves newer selection") {
            grid.numberOfItems(inSection: 0) == 1 && preview.filename.stringValue == "2.jpg" && preview.imageView.image != nil
        }
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("1.jpg")), data)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("2.jpg")), data)
        grid.toggleTag?()
        waitUntil("red tag badge") { !preview.tagMarker.isHidden }
        grid.trashCurrent?()
        waitUntil("last photo removed") {
            grid.numberOfItems(inSection: 0) == 0 && preview.filename.stringValue == "선택한 사진 없음" && preview.imageView.image == nil
        }
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("2.jpg")), data)
    }
    @MainActor
    func testViewerStartsAsNormalWindowInsideVisibleScreen() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let viewer = ViewerController(); defer { viewer.close() }
        viewer.present(on: screen)
        let window = try XCTUnwrap(viewer.window)
        XCTAssertTrue(window.styleMask.contains(.titled)); XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertGreaterThanOrEqual(window.frame.minY, screen.visibleFrame.minY - 1)
        XCTAssertLessThanOrEqual(window.frame.maxY, screen.visibleFrame.maxY + 1)
    }
}
