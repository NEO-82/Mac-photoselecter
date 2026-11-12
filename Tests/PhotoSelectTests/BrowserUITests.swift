import AppKit
import ImageIO
import XCTest
@testable import PhotoSelect

final class BrowserUITests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor
    private func waitUntil(_ description: String, timeout: TimeInterval = 5, condition: @escaping () -> Bool) {
        let done = expectation(description: description)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { done.fulfill() }
            else if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { poll() } }
        }
        poll(); wait(for: [done], timeout: timeout + 1)
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
    func testAboutMenuShowsSeoaCreditsInRoseOnNativePanel() throws {
        let app = NSApplication.shared
        let originalDelegate = app.delegate
        let originalAppearance = app.appearance
        let delegate = AppDelegate()
        app.delegate = delegate
        app.appearance = NSAppearance(named: .darkAqua)
        defer { app.delegate = originalDelegate; app.appearance = originalAppearance }
        let root = try folder()
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: nil)
        defer { app.delegate = originalDelegate; browser.close() }
        let menu = AppMenus.make(for: browser)
        let applicationMenu = try XCTUnwrap(menu.item(withTitle: AppBranding.displayName)?.submenu)
        let about = try XCTUnwrap(applicationMenu.item(withTitle: AppBranding.displayName + " 정보"))
        XCTAssertTrue(app.sendAction(try XCTUnwrap(about.action), to: about.target, from: about))
        let phrase = "Made with Seoa ♡"
        // Inspect the actual text storage that AppKit put in the displayed panel,
        // rather than reusing the source attributed-string construction.
        func credits(in window: NSWindow) -> (view: NSView, text: NSAttributedString, range: NSRange)? {
            guard window.isVisible, let content = window.contentView else { return nil }
            for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor {
                let text: NSAttributedString
                if let storage = (view as? NSTextView)?.textStorage { text = NSAttributedString(attributedString: storage) }
                else if let field = view as? NSTextField { text = field.attributedStringValue }
                else { continue }
                let range = (text.string as NSString).range(of: phrase)
                if range.location != NSNotFound { return (view, text, range) }
            }
            return nil
        }
        waitUntil("native About panel displays updated credits") {
            app.windows.contains { credits(in: $0) != nil }
        }
        let panel = try XCTUnwrap(app.windows.first { credits(in: $0) != nil },
            "Visible windows: " + app.windows.filter(\.isVisible).map(\.title).joined(separator: ", "))
        defer { app.delegate = originalDelegate; panel.close() }
        panel.appearance = NSAppearance(named: .darkAqua)
        let credit = try XCTUnwrap(credits(in: panel))
        XCTAssertFalse(credit.text.string.contains("Made with love ♡"))
        XCTAssertGreaterThan(credit.view.visibleRect.height, 0)
        let font = try XCTUnwrap(credit.text.attribute(.font, at: credit.range.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 11, accuracy: 0.1)
        let color = try XCTUnwrap(credit.text.attribute(.foregroundColor, at: credit.range.location, effectiveRange: nil) as? NSColor)
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var actual: NSColor?, expected: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                actual = color.usingColorSpace(.sRGB)
                expected = ProTheme.accent.usingColorSpace(.sRGB)
            }
            let actualColor = try XCTUnwrap(actual), expectedColor = try XCTUnwrap(expected)
            XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.01)
            XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.01)
            XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.01)
            XCTAssertEqual(actualColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.01)
        }
        if let path = ProcessInfo.processInfo.environment["PHOTOSELECT_UI_SNAPSHOT_PATH"] {
            let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("about-panel.png")
            let content = try XCTUnwrap(panel.contentView)
            content.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            panel.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
        }
        withExtendedLifetime(delegate) {}
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
    func testViewerDoubleClickReturnsToSamePhotoAndFolder() throws {
        _ = NSApplication.shared
        let root = try folder()
        for name in ["1.jpg", "2.jpg"] { try jpegData().write(to: root.appendingPathComponent(name)) }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let outline = try XCTUnwrap(views.compactMap { $0 as? NSOutlineView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("photos ready before opening viewer") { preview.imageView.image != nil }
        let selected = IndexPath(item: 1, section: 0)
        grid.selectionIndexPaths = [selected]
        browser.collectionView(grid, didSelectItemsAt: [selected])
        waitUntil("second photo ready before opening viewer") { preview.filename.stringValue == "2.jpg" && preview.imageView.image != nil }
        browser.openSelectedPhoto()
        let viewerWindow = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        defer { viewerWindow.close() }
        let canvas = try XCTUnwrap(viewerWindow.contentView as? PhotoCanvas)
        waitUntil("viewer decoded selected photo") { canvas.decoded != nil }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: viewerWindow.windowNumber, context: nil, eventNumber: 0,
            clickCount: 2, pressure: 1))
        canvas.mouseDown(with: event)
        waitUntil("double click returns to selected photo") {
            !viewerWindow.isVisible && preview.filename.stringValue == "2.jpg" && preview.imageView.image != nil
        }
        XCTAssertEqual(grid.selectionIndexPaths, [selected])
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 2)
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FolderNode)?.url, root)
        XCTAssertTrue(browser.window?.firstResponder === grid)
    }

    @MainActor
    func testViewerRoundTripReusesPreviewAndThumbnailWithoutMovingScroll() throws {
        _ = NSApplication.shared
        let root = try folder(), data = jpegData()
        for number in 1...60 { try data.write(to: root.appendingPathComponent(String(format: "%03d.jpg", number))) }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("metadata/tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("initial photo ready before viewer round trip") { preview.imageView.image != nil }
        let selected = IndexPath(item: 30, section: 0)
        grid.selectionIndexPaths = [selected]
        browser.collectionView(grid, didSelectItemsAt: [selected])
        waitUntil("selected scrolled thumbnail and preview ready") {
            preview.filename.stringValue == "031.jpg" && preview.imageView.image != nil && grid.item(at: selected) != nil
        }
        let originalPreview = try XCTUnwrap(preview.imageView.image)
        let originalItem = try XCTUnwrap(grid.item(at: selected))
        let scroll = try XCTUnwrap(grid.enclosingScrollView)
        let originalOrigin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(originalOrigin.y, 0)
        var originalViewerImage: CGImage?
        for pass in 0..<2 {
            browser.openSelectedPhoto()
            let viewerWindow = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
            let canvas = try XCTUnwrap(viewerWindow.contentView as? PhotoCanvas)
            XCTAssertEqual(viewerWindow.title, "031.jpg — " + AppBranding.displayName)
            let decoded = try XCTUnwrap(canvas.decoded) // Reopening a decoded selection must be synchronous.
            if pass == 0 { originalViewerImage = decoded.image }
            else { XCTAssertTrue(decoded.image === originalViewerImage) }
            viewerWindow.close()
            // Let queued cache/decode callbacks run; an unnecessary reload would
            // replace NSImage/collection items even when the bitmap cache hits.
            let settled = expectation(description: "round trip callbacks settled \(pass)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { settled.fulfill() }
            wait(for: [settled], timeout: 2)
            XCTAssertTrue(preview.imageView.image === originalPreview)
            XCTAssertTrue(grid.item(at: selected) === originalItem)
            XCTAssertEqual(scroll.contentView.bounds.origin, originalOrigin)
            XCTAssertEqual(grid.selectionIndexPaths, [selected])
        }
    }

    @MainActor
    func testFailedPreviewRemainsAnErrorWhenOpeningViewerAndEscapeReturns() throws {
        _ = NSApplication.shared
        let root = try folder(), broken = root.appendingPathComponent("broken.jpg")
        try Data("invalid JPEG fixture".utf8).write(to: broken)
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("metadata/tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("broken photo reports completed preview failure") {
            preview.filename.stringValue == "broken.jpg" && !preview.detail.stringValue.isEmpty && preview.detail.stringValue != "불러오는 중…"
        }
        let originalFailure = preview.detail.stringValue
        XCTAssertNil(preview.imageView.image)
        // Replacing the fixture on disk would succeed if opening the viewer
        // unnecessarily restarted decoding. Keep the existing failure until refresh.
        try jpegData().write(to: broken)
        browser.openSelectedPhoto()
        let viewerWindow = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        defer { viewerWindow.close() }
        let canvas = try XCTUnwrap(viewerWindow.contentView as? PhotoCanvas)
        let hud = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(viewerWindow.title, "broken.jpg — " + AppBranding.displayName)
        XCTAssertTrue(hud.stringValue.contains(originalFailure))
        XCTAssertFalse(hud.stringValue.contains("읽는 중"))
        let settled = expectation(description: "failed viewer does not restart decoding")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertNil(canvas.decoded)
        XCTAssertEqual(preview.detail.stringValue, originalFailure)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: viewerWindow.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: escape)
        XCTAssertFalse(viewerWindow.isVisible)
        XCTAssertEqual(grid.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
        XCTAssertTrue(browser.window?.firstResponder === grid)
    }

    @MainActor
    func testDeviceChangeNotificationRetainsErrorWhenReopeningViewer() throws {
        _ = NSApplication.shared
        let root = try folder(), photo = root.appendingPathComponent("photo.jpg"), data = jpegData()
        try data.write(to: photo)
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("metadata/tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("photo ready before simulated device change") { preview.imageView.image != nil }
        // This posts only the observer notification; it never unmounts a device.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification,
            object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: root])
        waitUntil("device change clears stale preview") { preview.imageView.image == nil }
        browser.openSelectedPhoto()
        let viewerWindow = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        defer { viewerWindow.close() }
        let canvas = try XCTUnwrap(viewerWindow.contentView as? PhotoCanvas)
        let hud = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertNil(canvas.decoded)
        XCTAssertTrue(hud.stringValue.contains("저장장치 변경"))
        XCTAssertFalse(hud.stringValue.contains("읽는 중"))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: viewerWindow.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: escape)
        XCTAssertFalse(viewerWindow.isVisible)
        XCTAssertEqual(grid.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
        XCTAssertTrue(browser.window?.firstResponder === grid)
        XCTAssertEqual(try Data(contentsOf: photo), data)
    }

    @MainActor
    func testDraggedSidebarWidthSurvivesWindowResizeAndPhotoSwitch() throws {
        _ = NSApplication.shared
        let root = try folder(), data = jpegData()
        for name in ["1.jpg", "2.jpg"] { try data.write(to: root.appendingPathComponent(name)) }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("metadata/tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let window = try XCTUnwrap(browser.window), content = try XCTUnwrap(window.contentView)
        window.setContentSize(NSSize(width: 1200, height: 650))
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let split = try XCTUnwrap(views.compactMap { $0 as? NSSplitView }.first)
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("first photo before divider adjustment") { preview.imageView.image != nil }
        // setPosition does not model user tracking's delegate callback itself.
        // Exercise that callback, its constraints, then AppKit's divider movement.
        let requested: CGFloat = 320
        let accepted = browser.splitView(split, constrainSplitPosition: requested, ofSubviewAt: 0)
        split.setPosition(accepted, ofDividerAt: 0)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, requested, accuracy: 2)
        window.setContentSize(NSSize(width: 1000, height: 650))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, requested, accuracy: 2)
        let second = IndexPath(item: 1, section: 0)
        grid.selectionIndexPaths = [second]
        browser.collectionView(grid, didSelectItemsAt: [second])
        waitUntil("second photo after divider adjustment") { preview.filename.stringValue == "2.jpg" && preview.imageView.image != nil }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, requested, accuracy: 2)
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[1].frame.width, 300)
    }

    @MainActor
    func testRealA7M4PreviewStaysIdenticalDuringHeldZoomAndCachedNavigation() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOSELECT_ARW_SAMPLE_DIRECTORY"] else {
            throw XCTSkip("Real Sony ARW fixtures require PHOTOSELECT_ARW_SAMPLE_DIRECTORY.")
        }
        _ = NSApplication.shared
        let sampleDirectory = URL(fileURLWithPath: path, isDirectory: true)
        let samples = try FileManager.default.contentsOfDirectory(at: sampleDirectory, includingPropertiesForKeys: nil)
        let source = try XCTUnwrap(samples.first {
            $0.pathExtension.lowercased() == "arw" && $0.lastPathComponent.lowercased().contains("a7m4")
        }, "Configured fixture directory must contain the Sony A7M4 ARW.")
        let root = try folder(), raw = root.appendingPathComponent("1.ARW")
        do { try FileManager.default.linkItem(at: source, to: raw) }
        catch { try FileManager.default.copyItem(at: source, to: raw) }
        try jpegData().write(to: root.appendingPathComponent("2.jpg"))
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("metadata/tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        waitUntil("real A7M4 initial embedded JPEG", timeout: 20) {
            preview.filename.stringValue == "1.ARW" && preview.imageView.image != nil
        }
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 2)
        browser.openSelectedPhoto()
        let viewerWindow = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        defer { viewerWindow.close() }
        let canvas = try XCTUnwrap(viewerWindow.contentView as? PhotoCanvas)
        let initial = try XCTUnwrap(canvas.decoded)
        let originalPixels = try XCTUnwrap(initial.image.dataProvider?.data)
        XCTAssertTrue(initial.raw)
        XCTAssertEqual(initial.provenance, .embeddedJPEG)
        XCTAssertTrue(initial.qualityDescription.contains("카메라 내장 JPEG"))
        XCTAssertEqual(initial.sourceSize, CGSize(width: initial.image.width, height: initial.image.height))
        let initialColorSpace = try XCTUnwrap(initial.image.colorSpace)
        let fit = PhotoCanvas.imageRect(for: initial, view: canvas.bounds.size, cursor: .zero,
            backingScale: viewerWindow.backingScaleFactor, zoomed: false)
        XCTAssertEqual(fit.width / fit.height, CGFloat(initial.image.width) / CGFloat(initial.image.height), accuracy: 0.000001)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 50, y: 50),
                modifierFlags: [], timestamp: 0, windowNumber: viewerWindow.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        func arrow(_ code: UInt16) throws -> NSEvent {
            let character = code == 123 ? "\u{F702}" : "\u{F703}"
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: viewerWindow.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code))
        }
        func assertStableRAW(for duration: TimeInterval, description: String) {
            let stable = expectation(description: description)
            let deadline = Date().addingTimeInterval(duration)
            func sample() {
                XCTAssertTrue(canvas.decoded?.image === initial.image, "RAW display must never swap sources after presentation.")
                if Date() >= deadline { stable.fulfill() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sample() } }
            }
            sample(); wait(for: [stable], timeout: duration + 2)
        }
        canvas.mouseDown(with: try mouse(.leftMouseDown))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged)) // Intentional drag commits held zoom immediately.
        assertStableRAW(for: 1.2, description: "held RAW zoom has no late decoder/color replacement")
        let held = try XCTUnwrap(canvas.decoded)
        XCTAssertEqual(held.sourceSize, initial.sourceSize)
        XCTAssertTrue(CFEqual(try XCTUnwrap(held.image.dataProvider?.data), originalPixels))
        XCTAssertTrue(CFEqual(try XCTUnwrap(held.image.colorSpace), initialColorSpace))
        let zoomed = PhotoCanvas.imageRect(for: held, view: canvas.bounds.size, cursor: CGPoint(x: 50, y: 50),
            backingScale: viewerWindow.backingScaleFactor, zoomed: true)
        XCTAssertEqual(zoomed.width * viewerWindow.backingScaleFactor, CGFloat(initial.image.width), accuracy: 0.01)
        XCTAssertEqual(zoomed.height * viewerWindow.backingScaleFactor, CGFloat(initial.image.height), accuracy: 0.01)
        canvas.keyDown(with: try arrow(124)) // Continue navigating with the mouse held.
        waitUntil("JPEG neighbor ready", timeout: 20) { canvas.decoded?.raw == false && preview.filename.stringValue == "2.jpg" }
        let jpeg = try XCTUnwrap(canvas.decoded)
        XCTAssertEqual(jpeg.provenance, .jpegOriginal)
        XCTAssertEqual(jpeg.image.width, 20); XCTAssertEqual(jpeg.image.height, 10)
        let backStart = ProcessInfo.processInfo.systemUptime
        canvas.keyDown(with: try arrow(123))
        let backMilliseconds = (ProcessInfo.processInfo.systemUptime - backStart) * 1000
        XCTAssertTrue(canvas.decoded?.image === initial.image, "A cached previous RAW must display synchronously without a blank canvas.")
        XCTAssertEqual(preview.filename.stringValue, "1.ARW")
        assertStableRAW(for: 1.2, description: "cached RAW remains stable while zoom stays held")
        XCTAssertTrue(CFEqual(try XCTUnwrap(canvas.decoded?.image.dataProvider?.data), originalPixels))
        canvas.mouseUp(with: try mouse(.leftMouseUp))
        XCTAssertTrue(canvas.decoded?.image === initial.image)
        let forwardStart = ProcessInfo.processInfo.systemUptime
        canvas.keyDown(with: try arrow(124))
        let forwardMilliseconds = (ProcessInfo.processInfo.systemUptime - forwardStart) * 1000
        XCTAssertTrue(canvas.decoded?.image === jpeg.image, "A cached JPEG neighbor must also display synchronously.")
        print("ARW UI evidence: A7M4 embedded JPEG \(initial.image.width)x\(initial.image.height), cached back \(backMilliseconds) ms, JPEG forward \(forwardMilliseconds) ms")
        if let screenshotPath = ProcessInfo.processInfo.environment["PHOTOSELECT_UI_SNAPSHOT_PATH"] {
            let output = URL(fileURLWithPath: screenshotPath).deletingLastPathComponent().appendingPathComponent("arw-ui-evidence.json")
            #if DEBUG
            let configuration = "Debug"
            #else
            let configuration = "Release"
            #endif
            let evidence: [String: Any] = ["configuration": configuration, "camera": "Sony A7M4", "display_source": "embeddedJPEG",
                "width": initial.image.width, "height": initial.image.height,
                "held_zoom_source_stable": true, "cached_raw_back_synchronous": true,
                "cached_jpeg_forward_synchronous": true, "cached_raw_back_ms": backMilliseconds,
                "cached_jpeg_forward_ms": forwardMilliseconds]
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        }
    }

    @MainActor
    func testSoftRomanticPaletteRendersInDarkAndLightAppearances() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let root = try folder()
        try jpegData(width: 3200, height: 2200).write(to: root.appendingPathComponent("sample.jpg"))
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("metadata/tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let window = try XCTUnwrap(browser.window)
        window.setContentSize(NSSize(width: 1100, height: 650))
        let content = try XCTUnwrap(window.contentView)
        let preview = try XCTUnwrap(descendants(content).compactMap { $0 as? PreviewPane }.first)
        waitUntil("photo ready for theme render") { preview.imageView.image != nil }
        let originalPreview = try XCTUnwrap(preview.imageView.image)
        for (name, filename, expected) in [
            (NSAppearance.Name.darkAqua, "browser-dark.png", [32.0 / 255, 35.0 / 255, 41.0 / 255]),
            (NSAppearance.Name.aqua, "browser-light.png", [244.0 / 255, 243.0 / 255, 244.0 / 255])
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            NSApp.appearance = appearance
            window.appearance = appearance
            content.layoutSubtreeIfNeeded()
            for view in descendants(content) { view.needsDisplay = true }
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            appearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            // The centered one-pixel outer margin contains the actual root
            // surface fill and avoids text, icons, photos and selection color.
            // Read back the same ICC-tagged PNG that is saved as UI evidence.
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let captured = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let pixel = try XCTUnwrap(captured.cropping(to: CGRect(x: CGFloat(bitmap.pixelsWide / 2), y: 1, width: 1, height: 1)))
            // colorAt can return device/calibrated NSColor components even when
            // the capture carries a display ICC profile. Convert that profile
            // through CoreGraphics into an explicit sRGB RGBA buffer instead.
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4,
                    space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertEqual(CGFloat(rgba[0]) / 255, CGFloat(expected[0]), accuracy: 0.04)
            XCTAssertEqual(CGFloat(rgba[1]) / 255, CGFloat(expected[1]), accuracy: 0.04)
            XCTAssertEqual(CGFloat(rgba[2]) / 255, CGFloat(expected[2]), accuracy: 0.04)
            XCTAssertTrue(preview.imageView.image === originalPreview)
            if let path = ProcessInfo.processInfo.environment["PHOTOSELECT_UI_SNAPSHOT_PATH"] {
                let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(filename)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: output)
            }
        }
    }

    @MainActor
    func testSelectingGeneralFileKeepsPhotoPreviewAndPhotoList() throws {
        _ = NSApplication.shared
        let root = try folder()
        try jpegData().write(to: root.appendingPathComponent("photo.jpg"))
        // These deliberately are not decodable images; selecting them must not
        // replace the current photo or attempt the image error display path.
        for name in ["notes.pdf", "movie.mov", "archive.zip"] {
            try Data("general file fixture".utf8).write(to: root.appendingPathComponent(name))
        }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let outline = try XCTUnwrap(views.compactMap { $0 as? NSOutlineView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("photo and general files ready") {
            preview.imageView.image != nil && (0..<outline.numberOfRows).contains {
                (outline.item(atRow: $0) as? FolderNode)?.url.lastPathComponent == "notes.pdf"
            }
        }
        let originalImage = try XCTUnwrap(preview.imageView.image)
        let originalDetail = preview.detail.stringValue
        for name in ["notes.pdf", "movie.mov", "archive.zip"] {
            let row = try XCTUnwrap((0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? FolderNode)?.url.lastPathComponent == name
            })
            let node = try XCTUnwrap(outline.item(atRow: row) as? FolderNode)
            XCTAssertFalse(node.isDirectory)
            XCTAssertFalse(outline.isExpandable(node))
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertEqual(preview.filename.stringValue, "photo.jpg")
            XCTAssertTrue(preview.imageView.image === originalImage)
            XCTAssertEqual(preview.detail.stringValue, originalDetail)
            XCTAssertEqual(grid.numberOfItems(inSection: 0), 1)
            XCTAssertEqual(grid.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
        }
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
    func testViewerStartsAsMaximizedWindowInsideVisibleScreen() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let viewer = ViewerController(); defer { viewer.close() }
        viewer.present(on: screen)
        let window = try XCTUnwrap(viewer.window)
        XCTAssertTrue(window.styleMask.contains(.titled)); XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        func assertFillsAvailableScreen() {
            XCTAssertEqual(window.frame.minX, screen.visibleFrame.minX, accuracy: 1)
            XCTAssertEqual(window.frame.minY, screen.visibleFrame.minY, accuracy: 1)
            XCTAssertEqual(window.frame.width, screen.visibleFrame.width, accuracy: 1)
            XCTAssertEqual(window.frame.height, screen.visibleFrame.height, accuracy: 1)
        }
        assertFillsAvailableScreen()
        viewer.windowDidChangeBackingProperties(Notification(name: NSWindow.didChangeBackingPropertiesNotification, object: window))
        viewer.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: window))
        assertFillsAvailableScreen()
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
