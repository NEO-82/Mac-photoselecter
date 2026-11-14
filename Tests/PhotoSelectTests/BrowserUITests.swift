import AppKit
import Darwin
import ImageIO
import XCTest
@testable import PhotoSelect

private final class BrowserDoubleClick: NSClickGestureRecognizer {
    var itemPoint = NSPoint.zero
    override func location(in view: NSView?) -> NSPoint { itemPoint }
}

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
    func testFinderOpenSelectsARWLoadsParentAndReusesWindow() throws {
        _ = NSApplication.shared
        let root = try folder()
        let first = root.appendingPathComponent("A.ARW")
        let second = root.appendingPathComponent("B.arw")
        // Invalid RAWs exercise selection and the normal decode-error path;
        // actual Sony preview decoding remains covered by the RAW regression suite.
        try Data("invalid RAW fixture".utf8).write(to: first)
        try Data("invalid RAW fixture".utf8).write(to: second)
        try jpegData().write(to: root.appendingPathComponent("neighbor.jpg"))
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent("tags.json")), initialFolder: nil)
        defer { browser.close() }
        let window = browser.window
        let views = descendants(try XCTUnwrap(window?.contentView))
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        let grid = try XCTUnwrap(views.compactMap { $0 as? NSCollectionView }.first)
        let filter = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "태그된 사진만 보기" })
        filter.state = .on
        browser.openFinderFile(first)
        waitUntil("Finder selects first ARW") {
            preview.filename.stringValue == "A.ARW" && !browser.sorting && grid.numberOfItems(inSection: 0) >= 3
        }
        XCTAssertEqual(filter.state, .off)
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(preview.filename.toolTip)).resolvingSymlinksInPath(), first.resolvingSymlinksInPath())
        browser.openFinderFile(second)
        waitUntil("running browser selects second ARW") { preview.filename.stringValue == "B.arw" }
        XCTAssertTrue(browser.window === window)
        browser.nextPhoto()
        waitUntil("normal neighbor preview remains usable") {
            preview.filename.stringValue == "neighbor.jpg" && preview.imageView.image != nil
        }
        browser.openFinderFile(second)
        waitUntil("cached folder selects RAW again") { preview.filename.stringValue == "B.arw" }
    }

    @MainActor
    func testFinderOpenRealSonyPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOSELECT_ARW_SAMPLE_DIRECTORY"] else {
            throw XCTSkip("Sony samples required")
        }
        _ = NSApplication.shared
        let root = try folder()
        let raw = root.appendingPathComponent("Finder selected.ARW")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: directory).appendingPathComponent("Sony-A7M4.ARW"), to: raw)
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), initialFolder: nil)
        defer { browser.close() }
        let preview = try XCTUnwrap(descendants(try XCTUnwrap(browser.window?.contentView)).compactMap { $0 as? PreviewPane }.first)
        browser.openFinderFile(raw)
        waitUntil("Finder Sony embedded JPEG", timeout: 30) {
            preview.filename.stringValue == raw.lastPathComponent && preview.imageView.image != nil
        }
        XCTAssertTrue(preview.detail.stringValue.contains("ARW 내장 JPEG"))
        let count = browser.navigationSamples.count
        browser.openFinderFile(raw)
        waitUntil("same-folder Finder open reuses RAW cache") { browser.navigationSamples.count > count }
        XCTAssertEqual(browser.navigationSamples.last?["cacheHit"], 1)
    }

    @MainActor
    func testFinderRapidFolderOpenKeepsLatestSelection() throws {
        _ = NSApplication.shared
        let firstRoot = try folder(), secondRoot = try folder()
        let first = firstRoot.appendingPathComponent("first.arw")
        let second = secondRoot.appendingPathComponent("second.ARW")
        try Data().write(to: first); try Data().write(to: second)
        let browser = BrowserController(tagStore: TagStore(fileURL: secondRoot.appendingPathComponent("tags.json")), initialFolder: nil)
        defer { browser.close() }
        let preview = try XCTUnwrap(descendants(try XCTUnwrap(browser.window?.contentView)).compactMap { $0 as? PreviewPane }.first)
        browser.openFinderFile(first); browser.openFinderFile(second)
        waitUntil("latest Finder request wins") { preview.filename.stringValue == "second.ARW" && !browser.sorting }
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(preview.filename.toolTip)).resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
    }

    @MainActor
    private func nativeGridClick(_ grid: PhotoCollectionView, item: Int, flags: NSEvent.ModifierFlags = []) throws {
        let window = try XCTUnwrap(grid.window)
        let path = IndexPath(item: item, section: 0)
        grid.scrollToItems(at: [path], scrollPosition: .centeredVertically)
        grid.layoutSubtreeIfNeeded()
        let frame = try XCTUnwrap(grid.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame)
        let point = grid.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags,
            timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
            timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        grid.mouseDown(with: down); grid.mouseUp(with: up)
    }

    @MainActor
    func testMultiSelectionNativeCommandShiftSelectAllEscapeAndStableSort() throws {
        _ = NSApplication.shared
        let root = try folder(), data = jpegData()
        for index in 0..<8 { try data.write(to: root.appendingPathComponent("\(index).jpg")) }
        try Data("document".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let noMove = expectation(description: "empty browser selection cannot delete")
        noMove.isInverted = true
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), trashService: PhotoTrash { _ in noMove.fulfill() }, initialFolder: root)
        defer { browser.close() }; browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("multi-selection folder ready") { grid.numberOfItems(inSection: 0) == 9 && !browser.sorting && preview.imageView.image != nil }
        try nativeGridClick(grid, item: 1)
        waitUntil("plain single selection") { browser.selectedPhotoIDs.count == 1 }
        try nativeGridClick(grid, item: 4, flags: .shift)
        XCTAssertEqual(grid.selectionIndexPaths, Set((1...4).map { IndexPath(item: $0, section: 0) }))
        try nativeGridClick(grid, item: 2, flags: .command)
        XCTAssertEqual(grid.selectionIndexPaths, Set([1, 3, 4].map { IndexPath(item: $0, section: 0) }))
        try nativeGridClick(grid, item: 6, flags: .command)
        XCTAssertEqual(browser.selectedPhotoIDs.count, 4)
        let selected = browser.selectedPhotoIDs
        let size = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoSort-name" })
        size.performClick(nil)
        waitUntil("sort preserves file selection") { !browser.sorting && browser.selectedPhotoIDs == selected }
        try nativeGridClick(grid, item: 5, flags: .shift)
        XCTAssertEqual(grid.selectionIndexPaths, Set((1...5).map { IndexPath(item: $0, section: 0) }), "Shift anchor must follow its file identity across descending sort")
        try nativeGridClick(grid, item: 3)
        XCTAssertEqual(browser.selectedPhotoIDs.count, 1)
        let commandA = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        grid.keyDown(with: commandA)
        XCTAssertEqual(browser.selectedPhotoIDs.count, 8)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        grid.keyDown(with: escape)
        XCTAssertTrue(browser.selectedPhotoIDs.isEmpty); XCTAssertTrue(grid.selectionIndexPaths.isEmpty)
        XCTAssertNotNil(preview.imageView.image, "Clearing browser selection must retain the current preview")
        grid.trashCurrent?()
        wait(for: [noMove], timeout: 0.1)
    }

    @MainActor
    func testMultiSelectionThreeThousandMarqueeOffscreenAndAutoScrollPerformance() throws {
        _ = NSApplication.shared
        let root = try folder(), data = jpegData()
        for index in 0..<3005 { try data.write(to: root.appendingPathComponent(String(format: "%04d.jpg", index))) }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), initialFolder: root)
        defer { browser.close() }; browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("3005 photo layout", timeout: 30) { grid.numberOfItems(inSection: 0) == 3005 && !browser.sorting && preview.imageView.image != nil }
        grid.layoutSubtreeIfNeeded()
        let last = try XCTUnwrap(grid.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: 3004, section: 0)))
        let navigation = browser.navigationSamples.count
        for step in 1...60 {
            grid.updateMarquee(from: .zero, to: NSPoint(x: grid.bounds.maxX, y: last.frame.maxY * CGFloat(step) / 60 + 1), original: [], additive: false, toggle: false)
        }
        XCTAssertEqual(browser.selectedPhotoIDs.count, 3005)
        XCTAssertEqual(grid.selectionIndexPaths.count, 3005)
        XCTAssertEqual(browser.navigationSamples.count, navigation, "Dragging must not decode/change the main preview")
        let times = grid.marqueeFrameTimes.sorted(), p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        print("3005-photo marquee p95 ms: \(p95), max ms: \(times.last ?? 0)")
        XCTAssertLessThan(p95, 100, "Main-thread selection geometry must remain bounded, even in Debug CI")
        let scroll = try XCTUnwrap(grid.enclosingScrollView)
        let before = scroll.contentView.bounds.origin.y
        for _ in 0..<20 { _ = grid.scrollMarquee(toward: NSPoint(x: 50, y: grid.visibleRect.maxY + 10)) }
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, before)
        XCTAssertEqual(browser.selectedPhotoIDs.count, 3005, "Autoscroll cannot drop offscreen selections")
        let first = try XCTUnwrap(grid.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        grid.updateMarquee(from: first.frame.origin, to: NSPoint(x: first.frame.maxX, y: first.frame.maxY), original: grid.photoPaths, additive: false, toggle: true)
        XCTAssertEqual(browser.selectedPhotoIDs.count, 3004)
        if let path = ProcessInfo.processInfo.environment["PHOTOSELECT_UI_SNAPSHOT_PATH"] {
            let maximum: Double = times.last ?? 0
            let result: [String: Any] = ["photoCount": 3005, "marqueeP95Ms": p95, "marqueeMaxMs": maximum, "previewRequestsDuringDrag": browser.navigationSamples.count - navigation, "offscreenSelected": true, "autoScroll": true]
            let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("selection-performance.json")
            try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: output)
        }
    }

    @MainActor
    func testSelectedRenameScopeTagFilterMixedFilesAndIdentityPreservation() throws {
        _ = NSApplication.shared
        let root = try folder(), metadata = try folder(), data = jpegData()
        let names = ["01.ARW", "02.JPG", "03.ARW", "04.JPG"]
        for name in names { try data.write(to: root.appendingPathComponent(name)) }
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json"))
        for name in ["01.ARW", "04.JPG"] {
            let done = expectation(description: "seed selected tag")
            store.toggle(root.appendingPathComponent(name)) { result in XCTAssertEqual(try? result.get(), true); done.fulfill() }
            wait(for: [done], timeout: 5)
        }
        let browser = BrowserController(tagStore: store, initialFolder: root)
        defer { browser.close() }; browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        waitUntil("rename folder ready") { grid.numberOfItems(inSection: 0) == 4 && !browser.sorting }
        let filter = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoBrowserTagFilter" })
        filter.performClick(nil)
        waitUntil("tagged photo projection") { grid.numberOfItems(inSection: 0) == 2 }
        grid.selectAll(nil)
        XCTAssertEqual(browser.selectedPhotoIDs.count, 2)
        let identities = browser.selectedPhotoIDs
        browser.openBatchRename()
        waitUntil("selected rename sheet") { browser.window?.attachedSheet != nil }
        let sheet = try XCTUnwrap(browser.window?.attachedSheet)
        let controller = try XCTUnwrap(sheet.windowController as? BatchRenameWindow)
        let controls = descendants(try XCTUnwrap(sheet.contentView))
        let selected = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "RenameSelectedScope" })
        let all = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "RenameAllScope" })
        XCTAssertEqual(selected.state, .on)
        waitUntil("only selected preview") { controller.plan?.rows.count == 2 }
        all.performClick(nil)
        waitUntil("all-folder scope ignores tag filter") { controller.plan?.rows.count == 4 }
        selected.performClick(nil)
        waitUntil("switch back to selected") { controller.plan?.rows.count == 2 }
        let prefix = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "RenameBase" })
        prefix.stringValue = "Wedding"; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: prefix))
        let digits = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "RenameDigits" })
        digits.selectItem(withTitle: "3"); NSApp.sendAction(try XCTUnwrap(digits.action), to: digits.target, from: digits)
        let run = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "RenameExecute" })
        waitUntil("selected preview updated") { controller.plan?.rows.first?.proposed == "Wedding_001.ARW" && run.isEnabled }
        XCTAssertTrue(run.title.contains("2")); run.performClick(nil)
        waitUntil("selected rename completed", timeout: 15) { !controller.busy && FileManager.default.fileExists(atPath: root.appendingPathComponent("Wedding_002.JPG").path) && !browser.sorting }
        for name in ["Wedding_001.ARW", "Wedding_002.JPG", "02.JPG", "03.ARW"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("01.ARW").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("04.JPG").path))
        XCTAssertEqual(browser.selectedPhotoIDs, identities)
        let loaded = expectation(description: "selected rename tags preserved")
        store.load { result in
            XCTAssertEqual(try? result.get(), Set(["Wedding_001.ARW", "Wedding_002.JPG"].map { TagStore.key(root.appendingPathComponent($0)) })); loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        sheet.performClose(nil)
    }

    @MainActor
    func testBulkTrashConfirmationCancelPartialFailureAndSelectionRetention() throws {
        _ = NSApplication.shared
        let root = try folder(), trash = try folder(), data = jpegData()
        for name in ["1.jpg", "2.jpg", "3.jpg"] { try data.write(to: root.appendingPathComponent(name)) }
        let service = PhotoTrash { url in
            if url.lastPathComponent == "2.jpg" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), trashService: service, initialFolder: root)
        defer { browser.close() }; browser.showWindow(nil)
        let grid = try XCTUnwrap(descendants(try XCTUnwrap(browser.window?.contentView)).compactMap { $0 as? PhotoCollectionView }.first)
        waitUntil("bulk trash folder") { grid.numberOfItems(inSection: 0) == 3 && !browser.sorting }
        grid.selectAll(nil); let ids = browser.selectedPhotoIDs
        grid.trashCurrent?()
        let cancelSheet = try XCTUnwrap(browser.window?.attachedSheet)
        let cancel = try XCTUnwrap(descendants(try XCTUnwrap(cancelSheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "취소" })
        cancel.performClick(nil)
        waitUntil("cancelled bulk trash") { browser.window?.attachedSheet == nil }
        XCTAssertEqual(browser.selectedPhotoIDs, ids)
        XCTAssertEqual(try BrowserEntry.read(root, showHidden: false).filter(\.isPhoto).count, 3)
        grid.trashCurrent?()
        let confirmSheet = try XCTUnwrap(browser.window?.attachedSheet)
        let confirm = try XCTUnwrap(descendants(try XCTUnwrap(confirmSheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "3장 휴지통으로 이동" })
        confirm.performClick(nil)
        waitUntil("two success one failure") { grid.numberOfItems(inSection: 0) == 1 && browser.window?.attachedSheet != nil }
        XCTAssertEqual(browser.selectedPhotoIDs.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("2.jpg")), data)
        for name in ["1.jpg", "3.jpg"] { XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent(name)), data) }
        let report = try XCTUnwrap(browser.window?.attachedSheet)
        let text = try XCTUnwrap(descendants(try XCTUnwrap(report.contentView)).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(text.string.contains("실패 · 2.jpg")); XCTAssertTrue(text.string.contains("완료 · 1.jpg"))
        let ok = try XCTUnwrap(descendants(try XCTUnwrap(report.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "확인" })
        ok.performClick(nil)
    }

    @MainActor
    func testViewerHeldZoomDeleteIsSingleEvenWithBrowserMultiSelection() throws {
        _ = NSApplication.shared
        let root = try folder(), trash = try folder(), data = jpegData()
        for name in ["1.jpg", "2.jpg"] { try data.write(to: root.appendingPathComponent(name)) }
        let service = PhotoTrash { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), trashService: service, initialFolder: root)
        defer { browser.close() }; browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("single viewer delete ready") { preview.imageView.image != nil && !browser.sorting }
        grid.selectAll(nil); XCTAssertEqual(browser.selectedPhotoIDs.count, 2)
        browser.openSelectedPhoto()
        let viewer = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        defer { viewer.close() }
        let canvas = try XCTUnwrap(viewer.contentView as? PhotoCanvas)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: viewer.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 52, y: 52), modifierFlags: [], timestamp: 0.1,
            windowNumber: viewer.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down); canvas.mouseDragged(with: drag)
        let delete = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: viewer.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        canvas.keyDown(with: delete)
        XCTAssertNil(browser.window?.attachedSheet)
        waitUntil("held viewer single delete") { FileManager.default.fileExists(atPath: trash.appendingPathComponent("1.jpg").path) && preview.filename.stringValue == "2.jpg" }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("2.jpg")), data)
        XCTAssertNil(browser.window?.attachedSheet)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: viewer.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        canvas.mouseUp(with: up)
    }

    @MainActor
    private func saveBrowserSnapshot(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOSELECT_UI_SNAPSHOT_PATH"] else { return }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        for view in descendants(content) { view.needsDisplay = true }
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
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
    func testNavigationKeepsLastFrameRejectsStaleCompletionAndSurvivesFailure() throws {
        _ = NSApplication.shared
        let root = try folder()
        for name in ["1.jpg", "2.jpg", "3.jpg", "4.jpg"] { try jpegData().write(to: root.appendingPathComponent(name)) }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpegData() as CFData, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let image = DecodedImage(image: bitmap, sourceSize: CGSize(width: 20, height: 10), fullResolution: true, raw: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pipeline = ImagePipeline(decoder: { url, _ in
            if url.lastPathComponent == "2.jpg" { _ = release.wait(timeout: .now() + 10) }
            if url.lastPathComponent == "4.jpg" { throw CocoaError(.fileReadCorruptFile) }
            return image
        })
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), initialFolder: root, pipeline: pipeline)
        defer { browser.close() }
        browser.showWindow(nil)
        waitUntil("initial frame") { !browser.navigationSamples.isEmpty }
        browser.openSelectedPhoto()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        defer { window.close() }
        let canvas = try XCTUnwrap(window.contentView as? PhotoCanvas)
        canvas.display()
        browser.nextPhoto()
        XCTAssertTrue(canvas.decoded?.image === bitmap)
        XCTAssertTrue(descendants(canvas).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("이전 사진 유지") })
        canvas.display()
        browser.nextPhoto()
        waitUntil("latest target replaces held frame") { browser.navigationSamples.count == 2 }
        release.signal()
        let drained = expectation(description: "stale result drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(window.title.hasPrefix("3.jpg"))
        XCTAssertEqual(browser.navigationSamples.count, 2)
        browser.nextPhoto()
        waitUntil("failed target is clearly labeled") {
            self.descendants(canvas).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("이전 사진 유지") && !$0.stringValue.contains("읽는 중") }
        }
        canvas.display()
        XCTAssertNotNil(canvas.decoded)
        XCTAssertEqual(canvas.emptyFramesAfterImage, 0)
        browser.previousPhoto()
        XCTAssertEqual(browser.navigationSamples.last?["cacheHit"], 1)
        XCTAssertLessThan(browser.navigationSamples.last?["requestToApplyMs"] ?? 1000, 100)
    }

    @MainActor
    func testRealA7M4NavigationBenchmark() throws {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["PHOTOSELECT_ARW_SAMPLE_DIRECTORY"] else { throw XCTSkip("Sony samples required") }
        let root = try folder(), original = URL(fileURLWithPath: directory).appendingPathComponent("Sony-A7M4.ARW")
        for index in 0..<12 {
            try FileManager.default.linkItem(at: original, to: root.appendingPathComponent(String(format: "%02d.ARW", index)))
        }
        let pipeline = ImagePipeline(foregroundConcurrency: 1)
        let start = ProcessInfo.processInfo.systemUptime
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), initialFolder: root, pipeline: pipeline)
        defer { browser.close() }
        browser.showWindow(nil)
        waitUntil("first Sony image", timeout: 30) { !browser.navigationSamples.isEmpty }
        let firstMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        browser.openSelectedPhoto()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        defer { window.close() }
        let canvas = try XCTUnwrap(window.contentView as? PhotoCanvas)
        canvas.display()
        var scenarios: [String: Any] = [:]
        func navigate(_ name: String, steps: Int, forward: Bool) {
            let start = ProcessInfo.processInfo.systemUptime, before = browser.navigationSamples.count
            var draws: [Double] = [], requestDraws: [Double] = []
            for _ in 0..<steps {
                let count = browser.navigationSamples.count
                if forward { browser.nextPhoto() } else { browser.previousPhoto() }
                canvas.display()
                waitUntil(name, timeout: 30) { browser.navigationSamples.count > count }
                canvas.display(); draws.append(canvas.lastDrawMs); requestDraws.append(canvas.lastRequestToDrawMs)
            }
            scenarios[name] = ["totalMs": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                "requests": Array(browser.navigationSamples.dropFirst(before)), "drawMs": draws, "requestToDrawMs": requestDraws]
        }
        navigate("forward10", steps: 10, forward: true)
        navigate("reverse10", steps: 10, forward: false)
        navigate("forward10Again", steps: 10, forward: true)
        navigate("back5", steps: 5, forward: false)
        // Rapid input without awaiting each intermediate target.
        for _ in 0..<5 { browser.previousPhoto(); canvas.display() }
        waitUntil("rapid final target", timeout: 30) { window.title.hasPrefix("00.ARW") && browser.navigationSamples.last?["index"] == 0 }
        canvas.display()
        XCTAssertEqual(canvas.emptyFramesAfterImage, 0)
        let hitTimes = browser.navigationSamples.filter { $0["cacheHit"] == 1 }.compactMap { $0["requestToApplyMs"] }
        XCTAssertFalse(hitTimes.isEmpty)
        XCTAssertLessThan(hitTimes.max() ?? 1000, 100)
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        if let path = ProcessInfo.processInfo.environment["PHOTOSELECT_UI_SNAPSHOT_PATH"] {
            var info = mach_task_basic_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            let memory: [String: Any] = status == KERN_SUCCESS
                ? ["residentBytes": UInt64(info.resident_size), "peakResidentBytes": UInt64(info.resident_size_max)]
                : ["unavailableStatus": status]
            let evidence: [String: Any] = ["configuration": configuration, "processMemory": memory,
                "fixture": "12 distinct paths hard-linked to one real Sony A7M4 file; same pixel contents",
                "firstFolderToImageMs": firstMs, "scenarios": scenarios, "cacheHitApplyMaxMs": hitTimes.max() ?? 0,
                "navigationRequests": browser.navigationSamples, "emptyDrawsAfterFirstImage": canvas.emptyFramesAfterImage,
                "drawnFrames": canvas.drawnFrames, "pipeline": pipeline.diagnostics,
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory, "cacheBudgetBytes": ImagePipeline.defaultCacheLimit,
                "limitation": "Intel macOS CI; warm OS file cache; draw callback timing, not GPU presentation or M1 Pro/SSD comparison"]
            let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("arw-navigation.json")
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        }
    }

    @MainActor
    func testLargeFolders2000And3000UseLazyThumbnailsAndBoundedDisplayWork() throws {
        _ = NSApplication.shared
        let root = try folder(), data = jpegData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let image = DecodedImage(image: bitmap, sourceSize: CGSize(width: 20, height: 10), fullResolution: true, raw: false)
        for count in [2000, 3000] {
            let directory = root.appendingPathComponent(String(count))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<count { try data.write(to: directory.appendingPathComponent(String(format: "%04d.jpg", index))) }
            let lock = NSLock(); var calls = 0
            let pipeline = ImagePipeline(foregroundConcurrency: 1, decoder: { _, _ in lock.lock(); calls += 1; lock.unlock(); return image })
            let start = ProcessInfo.processInfo.systemUptime
            let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), initialFolder: directory, pipeline: pipeline)
            browser.showWindow(nil)
            let views = descendants(try XCTUnwrap(browser.window?.contentView))
            let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
            waitUntil("large folder loaded", timeout: 20) { grid.numberOfItems(inSection: 0) == count && !browser.navigationSamples.isEmpty }
            lock.lock(); let initialCalls = calls; lock.unlock()
            XCTAssertLessThanOrEqual(initialCalls, 4, "Do not decode the whole folder")
            grid.scrollToItems(at: [IndexPath(item: count - 1, section: 0)], scrollPosition: .bottom)
            grid.layoutSubtreeIfNeeded()
            XCTAssertLessThan(grid.visibleItems().count, 100)
            for _ in 0..<20 { browser.nextPhoto() }
            for _ in 0..<10 { browser.previousPhoto() }
            waitUntil("rapid final selection") { browser.navigationSamples.last?["index"] == 10 }
            let filter = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoBrowserTagFilter" })
            filter.performClick(nil); XCTAssertEqual(grid.numberOfItems(inSection: 0), 0)
            filter.performClick(nil); XCTAssertEqual(grid.numberOfItems(inSection: 0), count)
            print("LARGE_FOLDER count=\(count) elapsedMs=\((ProcessInfo.processInfo.systemUptime - start) * 1000) initialDisplayDecodes=\(initialCalls)")
            if count == 3000 {
                browser.openBatchRename()
                waitUntil("3000-row rename preview", timeout: 15) { browser.window?.attachedSheet != nil }
                let sheet = try XCTUnwrap(browser.window?.attachedSheet)
                let sheetViews = descendants(try XCTUnwrap(sheet.contentView))
                let table = try XCTUnwrap(sheetViews.compactMap { $0 as? NSTableView }.first)
                waitUntil("3000 preview names ready", timeout: 15) { table.numberOfRows == 3000 }
                XCTAssertEqual(table.numberOfRows, 3000)
                table.scrollRowToVisible(2999); table.layoutSubtreeIfNeeded()
                XCTAssertLessThan(descendants(table).filter { $0 is NSTableRowView }.count, 100)
                try XCTUnwrap(sheetViews.compactMap { $0 as? NSButton }.first { $0.title == "닫기" }).performClick(nil)
            }
            let finished = expectation(description: "cleanup and tags drained")
            browser.finishPendingTagWrites { finished.fulfill() }
            wait(for: [finished], timeout: 5)
            browser.close()
        }
    }

    @MainActor
    func testSortButtonsKeepSelectionAndViewerOrderWithoutTouchingTags() throws {
        _ = NSApplication.shared
        let root = try folder(), data = jpegData()
        for name in ["1.jpg", "2.jpg", "10.jpg"] { try data.write(to: root.appendingPathComponent(name)) }
        let tags = root.appendingPathComponent(".tags.json")
        let original = Data(#"{"version":1,"taggedPaths":[]}"#.utf8); try original.write(to: tags)
        let browser = BrowserController(tagStore: TagStore(fileURL: tags), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("ready for sort") { preview.imageView.image != nil }
        let nameButton = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoSort-name" })
        nameButton.performClick(nil)
        waitUntil("name direction applied") { !browser.sorting }
        XCTAssertEqual(preview.filename.stringValue, "1.jpg")
        browser.previousPhoto()
        waitUntil("descending viewer order") { preview.filename.stringValue == "2.jpg" }
        let sizeButton = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoSort-size" })
        sizeButton.performClick(nil)
        waitUntil("size direction applied") { !browser.sorting }
        XCTAssertTrue(sizeButton.title.contains("↑")); XCTAssertEqual(preview.filename.stringValue, "2.jpg")
        let dateButton = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoSort-captured" })
        dateButton.performClick(nil)
        waitUntil("date metadata applied") { !browser.sorting }
        XCTAssertEqual(try Data(contentsOf: tags), original)
    }

    @MainActor
    func testBatchRenamePreviewWhileTaggedFilterIncludesEveryPhotoAndKeepsTags() throws {
        _ = NSApplication.shared
        let root = try folder(), journals = try folder(), metadata = try folder()
        for name in ["1.jpg", "2.jpg", "3.jpg"] { try jpegData().write(to: root.appendingPathComponent(name)) }
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json"))
        let browser = BrowserController(tagStore: store, initialFolder: root, renameEngine: BatchRenameEngine(journalDirectory: journals))
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        waitUntil("batch folder ready") { preview.imageView.image != nil && !browser.sorting }
        grid.toggleTag?(); waitUntil("batch initial tag") { !preview.tagMarker.isHidden }
        let filter = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoBrowserTagFilter" })
        filter.performClick(nil); XCTAssertEqual(grid.numberOfItems(inSection: 0), 1)
        browser.openBatchRename()
        waitUntil("rename sheet") { browser.window?.attachedSheet != nil }
        let sheet = try XCTUnwrap(browser.window?.attachedSheet)
        let contents = descendants(try XCTUnwrap(sheet.contentView))
        let table = try XCTUnwrap(contents.compactMap { $0 as? NSTableView }.first)
        waitUntil("rename names ready") { table.numberOfRows == 3 }
        XCTAssertEqual(table.numberOfRows, 3)
        sheet.appearance = NSAppearance(named: .darkAqua)
        try saveBrowserSnapshot(sheet, name: "browser-mixed-rename.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("1.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Photo_0001.jpg").path))
        let run = try XCTUnwrap(contents.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "RenameExecute" })
        run.performClick(nil)
        waitUntil("all names committed", timeout: 15) { FileManager.default.fileExists(atPath: root.appendingPathComponent("Photo_0003.jpg").path) && preview.filename.stringValue == "Photo_0001.jpg" && !browser.sorting }
        XCTAssertEqual(filter.state, .on); XCTAssertEqual(grid.numberOfItems(inSection: 0), 1)
        XCTAssertFalse(preview.tagMarker.isHidden)
        let close = try XCTUnwrap(contents.compactMap { $0 as? NSButton }.first { $0.title == "닫기" })
        close.performClick(nil)
        XCTAssertNil(browser.window?.attachedSheet)
    }

    @MainActor
    func testDeviceChangeInvalidatesRenamePreviewAndAllowsReopening() throws {
        _ = NSApplication.shared
        let root = try folder(), journals = try folder(), metadata = try folder()
        try jpegData().write(to: root.appendingPathComponent("photo.jpg"))
        let browser = BrowserController(tagStore: TagStore(fileURL: metadata.appendingPathComponent("tags.json")), initialFolder: root, renameEngine: BatchRenameEngine(journalDirectory: journals))
        defer { browser.close() }
        browser.showWindow(nil)
        waitUntil("device-preview initial folder") { !browser.navigationSamples.isEmpty && !browser.sorting }
        browser.openBatchRename()
        waitUntil("device-preview sheet") { browser.window?.attachedSheet != nil }
        let sheet = try XCTUnwrap(browser.window?.attachedSheet)
        let views = descendants(try XCTUnwrap(sheet.contentView))
        let run = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "RenameExecute" })
        waitUntil("device-preview ready") { run.isEnabled }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: nil)
        XCTAssertFalse(run.isEnabled)
        try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "닫기" }).performClick(nil)
        browser.openBatchRename()
        waitUntil("preview reopens after device signal") { browser.window?.attachedSheet != nil }
        let next = try XCTUnwrap(browser.window?.attachedSheet)
        try XCTUnwrap(descendants(try XCTUnwrap(next.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "닫기" }).performClick(nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.jpg").path))
    }

    @MainActor
    func testTaggedFilter1500PhotosKeepsFolderSnapshotCachesAndIndependentPaths() throws {
        _ = NSApplication.shared
        let root = try folder(), metadata = try folder()
        let file = metadata.appendingPathComponent("tags.json")
        let data = jpegData()
        for index in 0..<1500 {
            try data.write(to: root.appendingPathComponent(String(format: "%04d.jpg", index)))
        }
        // Same-stem RAW remains untagged and must not inherit the JPG tag.
        try Data().write(to: root.appendingPathComponent("0000.arw"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)
        let selected = root.appendingPathComponent("0001.jpg")
        let paths = [root.appendingPathComponent("0000.jpg"), selected,
                     root.appendingPathComponent("child/inside.jpg"), metadata.appendingPathComponent("outside.jpg")]
        let document: [String: Any] = ["version": 1, "taggedPaths": paths.map { TagStore.key($0) }]
        let original = try JSONSerialization.data(withJSONObject: document)
        try original.write(to: file)
        let browser = BrowserController(tagStore: TagStore(fileURL: file), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        let filter = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoBrowserTagFilter" })
        waitUntil("1500 photo folder loaded") { grid.numberOfItems(inSection: 0) == 1502 }
        let loaded = try BrowserEntry.read(root, showHidden: false)
        let index = try XCTUnwrap(loaded.firstIndex { TagStore.key($0.url) == TagStore.key(selected) })
        browser.collectionView(grid, didSelectItemsAt: [IndexPath(item: index, section: 0)])
        waitUntil("selected tagged JPG cached") { preview.imageView.image != nil && !preview.tagMarker.isHidden }
        let image = preview.imageView.image
        // A new disk entry stays invisible until an explicit refresh.
        try data.write(to: root.appendingPathComponent("new.jpg"))
        let start = ProcessInfo.processInfo.systemUptime
        filter.performClick(nil)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("Tagged filter 1500 JPG + RAW transition seconds: \(elapsed)")
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 2)
        XCTAssertEqual(grid.selectionIndexPaths, [IndexPath(item: 1, section: 0)])
        XCTAssertTrue(preview.imageView.image === image)
        browser.previousPhoto()
        XCTAssertEqual(preview.filename.stringValue, "0000.jpg")
        browser.nextPhoto()
        XCTAssertEqual(preview.filename.stringValue, "0001.jpg")
        filter.performClick(nil)
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 1502)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: selected), data)
    }

    @MainActor
    func testTaggedFilterViewerNavigationUntagTrashAndPersistence() throws {
        _ = NSApplication.shared
        let root = try folder(), metadata = try folder(), trash = try folder()
        let file = metadata.appendingPathComponent("tags.json")
        let data = jpegData()
        for name in ["1.jpg", "2.jpg", "3.jpg", "4.jpg"] {
            try data.write(to: root.appendingPathComponent(name))
        }
        let store = TagStore(fileURL: file)
        for name in ["1.jpg", "3.jpg", "4.jpg"] {
            let done = expectation(description: "seed tag")
            store.toggle(root.appendingPathComponent(name)) { result in
                XCTAssertEqual(try? result.get(), true); done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
        let originalTags = try Data(contentsOf: file)
        let service = PhotoTrash { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let browser = BrowserController(tagStore: store, trashService: service, initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let views = descendants(try XCTUnwrap(browser.window?.contentView))
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        let filter = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "PhotoBrowserTagFilter" })
        waitUntil("folder and tags loaded") { preview.imageView.image != nil && !preview.tagMarker.isHidden }
        let image = preview.imageView.image
        filter.performClick(nil)
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 3)
        XCTAssertTrue(preview.imageView.image === image)
        browser.window?.appearance = NSAppearance(named: .darkAqua)
        try saveBrowserSnapshot(try XCTUnwrap(browser.window), name: "browser-mixed-tagged.png")
        filter.performClick(nil)
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 4)
        XCTAssertEqual(try Data(contentsOf: file), originalTags)
        filter.performClick(nil)
        // Exercise the real double-click handler with the filtered grid index.
        grid.layoutSubtreeIfNeeded()
        let item = try XCTUnwrap(grid.item(at: IndexPath(item: 0, section: 0)))
        let recognizer = try XCTUnwrap(grid.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
        let click = BrowserDoubleClick()
        let rect = item.view.convert(item.view.bounds, to: grid)
        click.itemPoint = NSPoint(x: rect.midX, y: rect.midY)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(recognizer.action), to: recognizer.target, from: click))
        let viewer = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        defer { viewer.close() }
        let canvas = try XCTUnwrap(viewer.contentView as? PhotoCanvas)
        func key(_ code: UInt16, _ characters: String) throws {
            canvas.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: viewer.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        try key(124, "")
        XCTAssertEqual(preview.filename.stringValue, "3.jpg")
        try key(123, "")
        XCTAssertEqual(preview.filename.stringValue, "1.jpg")
        try key(42, "\\")
        waitUntil("untag moves to next tagged photo") { grid.numberOfItems(inSection: 0) == 2 && preview.filename.stringValue == "3.jpg" }
        try key(124, "")
        XCTAssertEqual(preview.filename.stringValue, "4.jpg")
        try key(42, "₩")
        waitUntil("last untag moves backward") { grid.numberOfItems(inSection: 0) == 1 && preview.filename.stringValue == "3.jpg" }
        try key(53, "\u{1b}")
        XCTAssertFalse(viewer.isVisible)
        XCTAssertEqual(filter.state, .on)
        browser.openSelectedPhoto()
        let finalViewer = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        let finalCanvas = try XCTUnwrap(finalViewer.contentView as? PhotoCanvas)
        finalCanvas.trashCurrent?()
        waitUntil("trash empties filtered viewer") { grid.numberOfItems(inSection: 0) == 0 && !finalViewer.isVisible }
        XCTAssertEqual(filter.state, .on)
        filter.performClick(nil)
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 3)
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("3.jpg")), data)
        for name in ["1.jpg", "2.jpg", "4.jpg"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data) }
        let restored = expectation(description: "restore existing format")
        TagStore(fileURL: file).load { result in
            XCTAssertEqual(try? result.get(), [TagStore.key(root.appendingPathComponent("3.jpg"))])
            restored.fulfill()
        }
        wait(for: [restored], timeout: 5)
        // Removing the sole remaining tag closes the viewer without changing files.
        grid.toggleTag?()
        waitUntil("retag after filter off") { !preview.tagMarker.isHidden }
        filter.performClick(nil)
        browser.openSelectedPhoto()
        let soleViewer = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PhotoCanvas })
        (soleViewer.contentView as? PhotoCanvas)?.toggleTag?()
        waitUntil("sole untag closes viewer") { grid.numberOfItems(inSection: 0) == 0 && !soleViewer.isVisible }
        XCTAssertEqual(preview.filename.stringValue, "선택한 사진 없음")
        // A tag write started before switching modes completes into the live filter.
        filter.performClick(nil)
        let remaining = try BrowserEntry.read(root, showHidden: false)
        let second = try XCTUnwrap(remaining.firstIndex { $0.url.lastPathComponent == "2.jpg" })
        browser.collectionView(grid, didSelectItemsAt: [IndexPath(item: second, section: 0)])
        grid.toggleTag?()
        filter.performClick(nil)
        waitUntil("new tag joins active filter") {
            grid.numberOfItems(inSection: 0) == 1 && preview.filename.stringValue == "2.jpg" && !preview.tagMarker.isHidden
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("2.jpg")), data)
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
        window.appearance = NSAppearance(named: .darkAqua)
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
            XCTAssertEqual(buttons.count, 4)
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
            preview.filename.stringValue == "031.jpg" && preview.imageView.image != nil && grid.item(at: selected) != nil && browser.navigationSamples.last?["index"] == 30
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
            preview.filename.stringValue == "broken.jpg" && !preview.detail.stringValue.isEmpty && !preview.detail.stringValue.contains("읽는 중") && preview.detail.stringValue != "불러오는 중…"
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
        XCTAssertTrue(grid.selectionIndexPaths.isEmpty, "Automatic preview is distinct from an explicit browser selection")
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
        XCTAssertTrue(grid.selectionIndexPaths.isEmpty, "Automatic preview is distinct from an explicit browser selection")
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
            XCTAssertEqual(grid.numberOfItems(inSection: 0), 4)
            XCTAssertTrue(grid.selectionIndexPaths.isEmpty, "Outline general-file clicks must not create a photo multi-selection")
        }
    }

    @MainActor
    func testMixedBrowserFolderNavigationFilePreviewAndCreditLayout() throws {
        _ = NSApplication.shared
        let root = try folder()
        let child = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try jpegData().write(to: root.appendingPathComponent("photo.jpg"))
        try jpegData().write(to: child.appendingPathComponent("inside.jpg"))
        for name in ["notes.txt", "metadata.xmp", "settings.json"] {
            try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
        }
        let browser = BrowserController(tagStore: TagStore(fileURL: root.appendingPathComponent(".tags.json")), initialFolder: root)
        defer { browser.close() }
        browser.showWindow(nil)
        let window = try XCTUnwrap(browser.window)
        window.appearance = NSAppearance(named: .darkAqua)
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let grid = try XCTUnwrap(views.compactMap { $0 as? PhotoCollectionView }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? PreviewPane }.first)
        let credit = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "PhotoBrowserCredit" })
        let status = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PhotoBrowserStatus" })
        waitUntil("mixed contents and image preview") { grid.numberOfItems(inSection: 0) == 5 && preview.imageView.image != nil }
        let contents = try BrowserEntry.read(root, showHidden: false)
        XCTAssertEqual(contents.first?.url.lastPathComponent, "Folder")
        for name in ["notes.txt", "metadata.xmp", "settings.json"] {
            let index = try XCTUnwrap(contents.firstIndex { $0.url.lastPathComponent == name })
            browser.collectionView(grid, didSelectItemsAt: [IndexPath(item: index, section: 0)])
            XCTAssertEqual(preview.filename.stringValue, name)
            XCTAssertNotNil(preview.imageView.image)
            XCTAssertTrue(preview.detail.stringValue.contains(URL(fileURLWithPath: name).pathExtension.uppercased()))
            XCTAssertTrue(preview.tagMarker.isHidden)
            let item = browser.collectionView(grid, itemForRepresentedObjectAt: IndexPath(item: index, section: 0)) as! ThumbnailItem
            XCTAssertNotNil(item.imageView?.image)
            XCTAssertNil(item.request)
        }
        try saveBrowserSnapshot(window, name: "browser-document.png")
        browser.collectionView(grid, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
        XCTAssertTrue(preview.detail.stringValue.contains("폴더"))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        grid.keyDown(with: enter)
        waitUntil("Return entered child folder") { preview.filename.stringValue == "inside.jpg" && preview.imageView.image != nil }
        browser.parentFolder()
        waitUntil("returned to parent") { grid.numberOfItems(inSection: 0) == 5 && preview.filename.stringValue == "photo.jpg" && preview.imageView.image != nil }
        content.layoutSubtreeIfNeeded()
        let folderPath = IndexPath(item: 0, section: 0)
        grid.scrollToItems(at: [folderPath], scrollPosition: .top)
        grid.layoutSubtreeIfNeeded()
        let folderItem = try XCTUnwrap(grid.item(at: folderPath))
        XCTAssertEqual(folderItem.textField?.stringValue, "Folder")
        XCTAssertNotNil(folderItem.imageView?.image)
        let recognizer = try XCTUnwrap(grid.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first { $0.numberOfClicksRequired == 2 })
        let doubleClick = BrowserDoubleClick()
        let rect = folderItem.view.convert(folderItem.view.bounds, to: grid)
        doubleClick.itemPoint = NSPoint(x: rect.midX, y: rect.midY)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(recognizer.action), to: recognizer.target, from: doubleClick))
        waitUntil("double-click handler entered child folder") { preview.filename.stringValue == "inside.jpg" && preview.imageView.image != nil }
        browser.parentFolder()
        waitUntil("double-click parent navigation") { grid.numberOfItems(inSection: 0) == 5 && preview.filename.stringValue == "photo.jpg" && preview.imageView.image != nil }
        let photoIndex = try XCTUnwrap(contents.firstIndex { $0.url.lastPathComponent == "photo.jpg" })
        for size in [NSSize(width: 900, height: 560), NSSize(width: 1200, height: 760)] {
            window.setContentSize(size)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            print("Browser resize request=\(size) frame=\(window.frame) contentFrame=\(content.frame) content=\(content.bounds) parent=\(String(describing: content.superview?.frame)) visible=\(window.isVisible) min=\(window.minSize) max=\(window.maxSize)")
            waitUntil("window resized to \(size.width)") {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                return abs(content.bounds.width - size.width) < 1 && abs(content.bounds.height - size.height) < 1
            }
            content.layoutSubtreeIfNeeded()
            waitUntil("photo thumbnail visible after resizing") {
                grid.item(at: IndexPath(item: photoIndex, section: 0))?.imageView?.image != nil
            }
            XCTAssertEqual(credit.stringValue, "Made with Seoa ♡")
            XCTAssertFalse(credit.isHiddenOrHasHiddenAncestor)
            // NSTextField frames include a two-point text inset beyond their
            // Auto Layout alignment rectangles. Compare the anchored rectangles.
            let creditRect = credit.alignmentRect(forFrame: credit.frame)
            let statusRect = status.alignmentRect(forFrame: status.frame)
            XCTAssertEqual(creditRect.maxX, content.bounds.maxX - 12, accuracy: 1)
            XCTAssertLessThanOrEqual(statusRect.maxX + 12, creditRect.minX + 1)
            XCTAssertGreaterThanOrEqual(credit.frame.minY, content.bounds.minY)
            XCTAssertFalse(credit.hasAmbiguousLayout)
            XCTAssertGreaterThan(credit.visibleRect.height, 0)
            try saveBrowserSnapshot(window, name: size.width == 900 ? "browser-mixed-compact.png" : "browser-mixed.png")
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
        XCTAssertEqual(menu.items.map(\.title), [AppBranding.displayName, "파일", "편집", "보기", "사진", "윈도우"])
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
        grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        browser.collectionView(grid, didSelectItemsAt: grid.selectionIndexPaths)
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
