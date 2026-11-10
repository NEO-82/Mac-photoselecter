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
    private func jpegData(width: Int = 20, height: Int = 10) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
        let expected = WindowLayout.columns(for: split.bounds.width, divider: split.dividerThickness)
        XCTAssertEqual(split.arrangedSubviews[0].bounds.width, expected.folders, accuracy: 2)
        XCTAssertEqual(split.arrangedSubviews[2].bounds.width, expected.preview, accuracy: 2)
        XCTAssertGreaterThan(split.arrangedSubviews[1].bounds.width, split.arrangedSubviews[2].bounds.width)
        XCTAssertTrue(descendants(split.arrangedSubviews[0]).contains { $0 is NSOutlineView })
        XCTAssertTrue(descendants(split.arrangedSubviews[1]).contains { $0 is PhotoCollectionView })
        XCTAssertTrue(split.arrangedSubviews[2] is PreviewPane)
    }
    @MainActor
    func testCompactToolbarKeepsAllPanesVisibleWhenShownAndResized() throws {
        _ = NSApplication.shared
        let root = try folder()
        let photos = root.appendingPathComponent(String(repeating: "데스크탑사진", count: 12), isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try jpegData(width: 3200, height: 2200).write(to: photos.appendingPathComponent("sample.jpg"))
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: photos)
        defer { browser.close() }
        browser.showWindow(nil)
        let window = try XCTUnwrap(browser.window)
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let toolbar = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PhotoBrowserToolbar" } as? NSStackView)
        let split = try XCTUnwrap(views.compactMap { $0 as? NSSplitView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("preview ready for layout check") { preview.imageView.image != nil }
        for size in [NSSize(width: 1000, height: 600), NSSize(width: 1280, height: 800), NSSize(width: 1100, height: 650)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            XCTAssertLessThanOrEqual(toolbar.frame.height, 44)
            XCTAssertGreaterThanOrEqual(toolbar.frame.height, 24)
            let buttons = toolbar.arrangedSubviews.compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, 3)
            for button in buttons {
                let rect = button.convert(button.bounds, to: toolbar)
                XCTAssertGreaterThan(rect.width, 40)
                XCTAssertGreaterThan(rect.height, 16)
                XCTAssertGreaterThanOrEqual(rect.minY, -1)
                XCTAssertLessThanOrEqual(rect.maxY, toolbar.bounds.height + 1)
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            }
            XCTAssertGreaterThanOrEqual(split.frame.height, content.bounds.height - 80)
            XCTAssertGreaterThanOrEqual(split.frame.height, 400)
            for pane in split.arrangedSubviews {
                XCTAssertGreaterThanOrEqual(pane.bounds.height, split.bounds.height - 2)
            }
            XCTAssertGreaterThan(preview.imageView.bounds.height, 300)
            XCTAssertLessThanOrEqual(split.frame.maxY, toolbar.frame.minY)
        }
        if let path = ProcessInfo.processInfo.environment["PHOTOSELECT_UI_SNAPSHOT_PATH"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            // A view snapshot omits the NSWindow backdrop; supply that same backdrop
            // so transparent gaps/labels remain readable in the exported evidence.
            let flattened = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: flattened)).cgContext
            let rect = CGRect(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh))
            context.setFillColor(NSColor.windowBackgroundColor.cgColor); context.fill(rect)
            context.draw(try XCTUnwrap(bitmap.cgImage), in: rect)
            try XCTUnwrap(flattened.representation(using: .png, properties: [:])).write(to: output)
        }
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
    func testInitialBrowserFrameFitsActualAvailableScreen() throws {
        _ = NSApplication.shared
        let root = try folder()
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: nil)
        defer { browser.close() }
        browser.showWindow(nil)
        let window = try XCTUnwrap(browser.window)
        let screen = try XCTUnwrap(window.screen)
        XCTAssertTrue(screen.visibleFrame.contains(window.frame))
        XCTAssertLessThanOrEqual(window.minSize.width, screen.visibleFrame.width)
        XCTAssertLessThanOrEqual(window.minSize.height, screen.visibleFrame.height)
    }
    @MainActor
    func testLoadingLargeLandscapeAndPortraitKeepsPreviewBounded() throws {
        _ = NSApplication.shared
        let root = try folder()
        try jpegData(width: 3200, height: 2200).write(to: root.appendingPathComponent("1-landscape.jpg"))
        try jpegData(width: 1000, height: 5000).write(to: root.appendingPathComponent("2-portrait.jpg"))
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let window = try XCTUnwrap(browser.window)
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let split = try XCTUnwrap(views.compactMap { $0 as? NSSplitView }.first)
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        let originalWindowFrame = window.frame
        waitUntil("large first image") { preview.filename.stringValue == "1-landscape.jpg" && preview.imageView.image != nil }
        content.layoutSubtreeIfNeeded()
        var expected = WindowLayout.columns(for: split.bounds.width, divider: split.dividerThickness)
        XCTAssertEqual(preview.frame.width, expected.preview, accuracy: 2)
        XCTAssertLessThanOrEqual(preview.frame.width, 322)
        XCTAssertEqual(window.frame, originalWindowFrame)
        grid.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        browser.collectionView(grid, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        waitUntil("large portrait") { preview.filename.stringValue == "2-portrait.jpg" && preview.imageView.image != nil }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(preview.frame.width, expected.preview, accuracy: 2)
        XCTAssertEqual(window.frame, originalWindowFrame)
        window.setContentSize(NSSize(width: 1000, height: 600))
        content.layoutSubtreeIfNeeded()
        expected = WindowLayout.columns(for: split.bounds.width, divider: split.dividerThickness)
        XCTAssertEqual(preview.frame.width, expected.preview, accuracy: 2)
        XCTAssertGreaterThan(split.arrangedSubviews[1].bounds.width, preview.frame.width)
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
    func testTagBadgeReturnsAfterClosingAndRecreatingBrowser() throws {
        _ = NSApplication.shared
        let root = try folder(), file = root.appendingPathComponent("metadata/tags.json")
        try jpegData().write(to: root.appendingPathComponent("1.jpg"))
        let first = BrowserController(tagStore: TagStore(fileURL: file), initialFolder: root)
        defer { first.close() }
        let views = descendants(first.window!.contentView!)
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("first session ready") { preview.imageView.image != nil }
        grid.toggleTag?()
        let finished = expectation(description: "normal exit saves pending tag")
        first.finishPendingTagWrites { finished.fulfill() }
        grid.toggleTag?() // Input received after exit starts must not enqueue a late write.
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(preview.tagMarker.isHidden)
        first.close()
        let second = BrowserController(tagStore: TagStore(fileURL: file), initialFolder: root)
        defer { second.close() }
        let secondViews = descendants(second.window!.contentView!)
        let secondPreview = try XCTUnwrap(secondViews.compactMap { $0 as? PreviewPane }.first)
        waitUntil("new browser restores red badge") {
            secondPreview.imageView.image != nil && !secondPreview.tagMarker.isHidden
        }
    }
    @MainActor
    func testStandardMenusDisablePhotoActionsUntilFolderHasPhotos() throws {
        _ = NSApplication.shared
        let root = try folder()
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: nil)
        defer { browser.close() }
        let menu = AppMenus.make(for: browser)
        XCTAssertEqual(menu.items.map(\.title), [AppBranding.displayName, "파일", "보기", "사진", "윈도우"])
        let file = try XCTUnwrap(menu.item(withTitle: "파일")?.submenu)
        let open = try XCTUnwrap(file.item(withTitle: "폴더 열기…"))
        XCTAssertEqual(open.keyEquivalent, "o"); XCTAssertEqual(open.keyEquivalentModifierMask, .command)
        file.update(); XCTAssertTrue(open.isEnabled)
        let view = try XCTUnwrap(menu.item(withTitle: "보기")?.submenu)
        let photo = try XCTUnwrap(menu.item(withTitle: "사진")?.submenu)
        view.update(); photo.update()
        XCTAssertFalse(try XCTUnwrap(view.item(withTitle: "선택 사진 크게 보기")).isEnabled)
        for item in photo.items where !item.isSeparatorItem { XCTAssertFalse(item.isEnabled) }
    }
    @MainActor
    func testNativeMenuCommandsNavigateAndTagCurrentPhoto() throws {
        _ = NSApplication.shared
        let root = try folder()
        for name in ["1.jpg", "2.jpg"] { try jpegData().write(to: root.appendingPathComponent(name)) }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: root)
        defer { browser.close() }
        let preview = try XCTUnwrap(descendants(browser.window!.contentView!).compactMap { $0 as? PreviewPane }.first)
        waitUntil("menu folder ready") { preview.imageView.image != nil }
        let menu = try XCTUnwrap(AppMenus.make(for: browser).item(withTitle: "사진")?.submenu)
        menu.update()
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "이전 사진")).isEnabled)
        let next = try XCTUnwrap(menu.item(withTitle: "다음 사진"))
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(next.action), to: next.target, from: next))
        waitUntil("next menu displays second photo") { preview.filename.stringValue == "2.jpg" && preview.imageView.image != nil }
        menu.update(); XCTAssertFalse(next.isEnabled)
        let tag = try XCTUnwrap(menu.item(withTitle: "태그 지정/해제"))
        XCTAssertTrue(tag.isEnabled); XCTAssertEqual(tag.keyEquivalent, "\\")
        XCTAssertEqual(tag.keyEquivalentModifierMask, [])
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(tag.action), to: tag.target, from: tag))
        waitUntil("tag menu updates red badge") { !preview.tagMarker.isHidden }
        let previous = try XCTUnwrap(menu.item(withTitle: "이전 사진"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(previous.action), to: previous.target, from: previous))
        waitUntil("previous menu restores first photo") { preview.filename.stringValue == "1.jpg" && preview.imageView.image != nil }
        XCTAssertTrue(preview.tagMarker.isHidden)
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
    @MainActor
    func testPresentingVisibleViewerKeepsManualWindowSize() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let viewer = ViewerController(); defer { viewer.close() }
        viewer.present(on: screen)
        let window = try XCTUnwrap(viewer.window)
        let manual = WindowLayout.fittedFrame(window.frame.insetBy(dx: 50, dy: 40), in: screen.visibleFrame, kind: .viewer)
        window.setFrame(manual, display: true)
        let actual = window.frame
        viewer.present(on: screen)
        XCTAssertEqual(window.frame, actual)
    }
}
