import AppKit
import XCTest
@testable import PhotoSelect

@MainActor final class FileTransferUITests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func waitUntil(_ label: String, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline {
            // Activation/key-window events require AppKit dispatch, not just the
            // Foundation run loop used by the existing view-only tests.
            for _ in 0..<64 {
                guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(predicate(), label)
    }
    private func click(_ grid: PhotoCollectionView, item: Int, flags: NSEvent.ModifierFlags = []) throws {
        let frame = try XCTUnwrap(grid.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame)
        let point = grid.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let window = try XCTUnwrap(grid.window)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags,
            timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        grid.mouseDown(with: down); grid.mouseUp(with: up)
    }
    func testResponderCopyIncludesSelectedFolderPhotoAndDocument() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let root = try folder(), tags = TagStore(fileURL: try folder().appendingPathComponent("tags.json"))
        let folder = root.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("DSC.ARW"), document = root.appendingPathComponent("notes.txt")
        for url in [photo, document] { try Data("source".utf8).write(to: url) }
        let browser = BrowserController(tagStore: tags, initialFolder: root)
        browser.showWindow(nil); defer { browser.close(); NSPasteboard.general.clearContents() }
        let window = try XCTUnwrap(browser.window)
        let grid = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? PhotoCollectionView }.first)
        waitUntil("mixed browser ready") { grid.numberOfItems(inSection: 0) == 3 && !browser.sorting }
        NSApp.mainMenu = AppMenus.make(for: browser)
        NSApp.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil); window.makeKey()
        waitUntil("browser key window; canBecomeKey=\(window.canBecomeKey), active=\(NSApp.isActive)") { NSApp.keyWindow === window }
        XCTAssertTrue(window.makeFirstResponder(grid))
        try click(grid, item: 0); try click(grid, item: 1, flags: .command); try click(grid, item: 2, flags: .command)
        XCTAssertEqual(grid.selectionIndexPaths.count, 3)
        let copy = NSMenuItem(title: "copy", action: #selector(BrowserController.copyFiles(_:)), keyEquivalent: "")
        waitUntil("copy selection and tags ready") { browser.validateMenuItem(copy) }
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil))
        XCTAssertEqual(Set(FileClipboard.read(.general).map(TagStore.key)), Set([folder, photo, document].map(TagStore.key)))
        XCTAssertEqual(try Data(contentsOf: photo), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: document), Data("source".utf8))
    }
    func testResponderPasteCopiesAndClearsStaleDestinationTagWhilePreservingOriginal() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let source = try folder(), destination = try folder(), metadata = try folder().appendingPathComponent("tags.json")
        let raw = source.appendingPathComponent("DSC.ARW"), copy = destination.appendingPathComponent("DSC.ARW")
        let bytes = Data("original RAW test bytes".utf8); try bytes.write(to: raw)
        try Data("existing JPEG test bytes".utf8).write(to: destination.appendingPathComponent("keep.JPG"))
        let store = TagStore(fileURL: metadata), tagged = expectation(description: "tags queued")
        tagged.expectedFulfillmentCount = 2
        for url in [raw, copy] { store.toggle(url) { _ in tagged.fulfill() } }
        wait(for: [tagged], timeout: 5)
        let browser = BrowserController(tagStore: store, initialFolder: destination)
        browser.showWindow(nil)
        defer {
            if let parent = browser.window, let sheet = parent.attachedSheet { parent.endSheet(sheet); sheet.orderOut(nil) }
            browser.close(); NSPasteboard.general.clearContents()
        }
        let window = try XCTUnwrap(browser.window)
        let grid = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? PhotoCollectionView }.first)
        XCTAssertTrue(FileClipboard.write([raw]))
        let paste = NSMenuItem(title: "paste", action: #selector(BrowserController.pasteFiles(_:)), keyEquivalent: "")
        NSApp.mainMenu = AppMenus.make(for: browser)
        NSApp.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil); window.makeKey()
        waitUntil("browser key window; canBecomeKey=\(window.canBecomeKey), active=\(NSApp.isActive)") { NSApp.keyWindow === window }
        XCTAssertTrue(window.makeFirstResponder(grid))
        waitUntil("paste destination and tags ready") { browser.validateMenuItem(paste) }
        waitUntil("existing photo selectable") { grid.numberOfItems(inSection: 0) == 1 && !browser.sorting }
        try click(grid, item: 0)
        let trash = NSMenuItem(title: "trash", action: #selector(BrowserController.trashFromMenu), keyEquivalent: "")
        XCTAssertTrue(browser.validateMenuItem(trash))
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil))
        XCTAssertFalse(browser.validateMenuItem(trash), "Copy excludes destructive file operations")
        waitUntil("copy result displayed") { window.attachedSheet != nil }
        XCTAssertEqual(try Data(contentsOf: raw), bytes); XCTAssertEqual(try Data(contentsOf: copy), bytes)
        let loaded = expectation(description: "copy tag absent")
        store.load { result in XCTAssertEqual(try? result.get(), Set([TagStore.key(raw)])); loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
    }
}
