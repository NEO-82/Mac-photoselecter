import AppKit
import XCTest
@testable import PhotoSelect

final class FolderTreeTests: XCTestCase {
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
    @MainActor
    private func mount(_ tree: FolderTree) -> NSWindow {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        scroll.hasVerticalScroller = true
        tree.view.frame = scroll.contentView.bounds
        scroll.documentView = tree.view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        return window
    }
    @MainActor
    private func state(_ tree: FolderTree) -> String {
        let rows = (0..<tree.view.numberOfRows).compactMap { row -> String? in
            guard let node = tree.view.item(atRow: row) as? FolderNode else { return nil }
            return "\(row):\(node.title) children=\(node.children?.count.description ?? "nil") expanded=\(tree.view.isItemExpanded(node)) requested=\(node.expanded) loading=\(node.loading)"
        }.joined(separator: "; ")
        return "selectedRow=\(tree.view.selectedRow); \(rows)"
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testGeneralEntriesStaySeparateFromPhotoDecodeList() throws {
        let root = try folder()
        for name in ["a.jpg", "b.ARW", "notes.pdf", "movie.mov", "archive.zip", ".hidden.jpg"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        XCTAssertEqual(try FolderReader.entries(root, directories: false).map(\.lastPathComponent), ["a.jpg", "b.ARW"])
        XCTAssertEqual(try FolderReader.entries(root, directories: true, allFiles: true).count, 6)
        XCTAssertEqual(try FolderReader.entries(root, directories: true, allFiles: true, showHidden: true).count, 7)
    }

    @MainActor
    func testDesktopShortcutUsesSystemDesktopLocation() throws {
        _ = NSApplication.shared
        let tree = FolderTree(directoryReader: { _ in [] })
        let desktop = try XCTUnwrap(FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)
        XCTAssertTrue(tree.roots.contains { $0.title == "데스크탑" && $0.url.standardizedFileURL.path == desktop.standardizedFileURL.path })
    }
    @MainActor
    func testReauthorizingSameFolderReplacesGrantAndReloadsDeniedCache() throws {
        _ = NSApplication.shared
        let root = try folder(), child = root.appendingPathComponent("Desktop Photos", isDirectory: true)
        let oldGrant = FolderLease(root)
        let node = FolderNode(url: root, lease: oldGrant)
        var allowed = false
        var reads = 0
        let tree = FolderTree(roots: [node], directoryReader: { url in
            guard url == root else { return [] }
            reads += 1
            guard allowed else { throw CocoaError(.fileReadNoPermission) }
            return [child]
        })
        tree.select(root)
        waitUntil("initial denial") { node.error != nil && !node.loading }
        XCTAssertTrue(node.children?.isEmpty == true)
        XCTAssertTrue(node.error?.contains("폴더 열기") == true)
        let newGrant = FolderLease(root)
        allowed = true
        tree.select(root, lease: newGrant, renewAccess: true)
        waitUntil("children after authorization") { node.error == nil && node.children?.count == 1 && !node.loading }
        XCTAssertTrue(node.lease === newGrant)
        XCTAssertTrue(node.children?.first?.lease === newGrant)
        XCTAssertEqual(node.children?.first?.url, child)
        XCTAssertEqual(tree.view.selectedRow, tree.view.row(forItem: node))
        XCTAssertGreaterThanOrEqual(tree.view.row(forItem: node.children!.first!), 0)
        XCTAssertEqual(reads, 2)
    }
    @MainActor
    func testDeniedFolderCanBeExpandedAgainAfterAccessChanges() throws {
        _ = NSApplication.shared
        let root = try folder(), child = root.appendingPathComponent("visible", isDirectory: true)
        let node = FolderNode(url: root, lease: FolderLease(root))
        var allowed = false
        let tree = FolderTree(roots: [node], directoryReader: { url in
            guard url == root else { return [] }
            guard allowed else { throw CocoaError(.fileReadNoPermission) }
            return [child]
        })
        tree.select(root)
        waitUntil("denied") { node.error != nil && !node.loading }
        XCTAssertTrue(tree.outlineView(tree.view, isItemExpandable: node))
        allowed = true
        XCTAssertTrue(tree.outlineView(tree.view, shouldExpandItem: node))
        tree.view.expandItem(node)
        waitUntil("retried") { node.error == nil && node.children?.first?.url == child }
    }
    @MainActor
    func testSelectingCachedFolderRevealsCollapsedAncestors() throws {
        _ = NSApplication.shared
        let root = try folder(), child = root.appendingPathComponent("Desktop", isDirectory: true)
        let grant = FolderLease(root)
        let parent = FolderNode(url: root, lease: grant)
        let target = FolderNode(url: child, lease: grant)
        parent.children = [target]; target.children = []
        let tree = FolderTree(roots: [parent], directoryReader: { _ in [] })
        tree.view.collapseItem(parent)
        tree.select(child, lease: grant)
        XCTAssertTrue(tree.view.isItemExpanded(parent))
        XCTAssertGreaterThanOrEqual(tree.view.row(forItem: target), 0)
        XCTAssertEqual(tree.view.selectedRow, tree.view.row(forItem: target))
    }
    @MainActor
    func testNativeDisclosureExpandsWithoutSelectingAndHasVisibleGutter() throws {
        _ = NSApplication.shared
        let root = try folder(), childURL = root.appendingPathComponent("Child", isDirectory: true)
        let lease = FolderLease(root)
        let parent = FolderNode(url: root, lease: lease)
        let child = FolderNode(url: childURL, lease: lease, isDirectory: true)
        child.children = []; parent.children = [child]
        let tree = FolderTree(roots: [parent], directoryReader: { _ in [] })
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        tree.view.frame = scroll.bounds; scroll.documentView = tree.view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(tree.view.outlineTableColumn === tree.view.tableColumns.first)
        XCTAssertEqual(tree.view.indentationPerLevel, 18)
        XCTAssertTrue(tree.outlineView(tree.view, shouldShowOutlineCellForItem: parent))
        XCTAssertFalse(tree.outlineView(tree.view, shouldShowOutlineCellForItem: child))
        let gutter = tree.view.frameOfOutlineCell(atRow: 0)
        XCTAssertGreaterThan(gutter.width, 0)
        XCTAssertGreaterThan(gutter.height, 0)
        let cell = try XCTUnwrap(tree.outlineView(tree.view, viewFor: tree.view.outlineTableColumn, item: parent) as? NSTableCellView)
        XCTAssertNotNil(cell.imageView); XCTAssertNotNil(cell.textField)
        var selections = 0
        tree.onSelect = { _ in selections += 1 }
        // Exercise AppKit's actual disclosure button target/action rather than
        // calling our delegate directly. Neither click selects the folder.
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        func disclosure() throws -> NSButton {
            _ = tree.view.rowView(atRow: 0, makeIfNecessary: true)
            return try XCTUnwrap(descendants(tree.view).compactMap { $0 as? NSButton }.first {
                $0.identifier == NSOutlineView.disclosureButtonIdentifier
            })
        }
        try disclosure().performClick(nil)
        XCTAssertTrue(tree.view.isItemExpanded(parent))
        XCTAssertEqual(tree.view.numberOfRows, 2)
        try disclosure().performClick(nil)
        XCTAssertFalse(tree.view.isItemExpanded(parent))
        XCTAssertEqual(tree.view.numberOfRows, 1)
        XCTAssertEqual(selections, 0)
    }

    @MainActor
    func testHiddenRefreshPreservesExpandedPathAndSelectedFolder() throws {
        _ = NSApplication.shared
        let root = try folder(), nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("visible.jpg"))
        try Data().write(to: nested.appendingPathComponent(".hidden.txt"))
        // FileManager may enumerate the canonical /private/var location while
        // temporaryDirectory uses its /var alias on macOS. Compare identity.
        let expectedLocation = nested.resolvingSymlinksInPath().standardizedFileURL
        let parent = FolderNode(url: root, lease: FolderLease(root))
        let tree = FolderTree(roots: [parent])
        let window = mount(tree); defer { window.close() }
        tree.select(root)
        waitUntil("initial child directory") { parent.children?.count == 1 }
        tree.select(nested, lease: parent.lease)
        waitUntil("initial nested entries") { (tree.view.item(atRow: tree.view.selectedRow) as? FolderNode)?.children?.count == 1 }
        var selections = 0
        tree.onSelect = { _ in selections += 1 }
        tree.showHidden = true
        waitUntil("expanded selection restored with hidden file") {
            guard let selected = tree.view.item(atRow: tree.view.selectedRow) as? FolderNode else { return false }
            return selected.url.resolvingSymlinksInPath().standardizedFileURL == expectedLocation && selected.children?.count == 2 && tree.view.isItemExpanded(selected)
        }
        XCTAssertTrue(tree.view.isItemExpanded(parent), state(tree))
        XCTAssertEqual((tree.view.item(atRow: tree.view.selectedRow) as? FolderNode)?.url.resolvingSymlinksInPath().standardizedFileURL, expectedLocation, state(tree))
        XCTAssertEqual((tree.view.item(atRow: tree.view.selectedRow) as? FolderNode)?.children?.count, 2, state(tree))
        XCTAssertEqual(selections, 0)
        tree.showHidden = false
        waitUntil("hidden file removed without losing location") {
            guard let selected = tree.view.item(atRow: tree.view.selectedRow) as? FolderNode else { return false }
            return selected.url.resolvingSymlinksInPath().standardizedFileURL == expectedLocation && selected.children?.count == 1 && tree.view.isItemExpanded(selected)
        }
        XCTAssertEqual(selections, 0)
    }

    @MainActor
    func testUserSelectionDuringRefreshOverridesPendingRestoration() throws {
        _ = NSApplication.shared
        let firstURL = try folder(), otherURL = try folder()
        let childURL = firstURL.appendingPathComponent("Child", isDirectory: true)
        let lease = FolderLease(firstURL)
        let first = FolderNode(url: firstURL, lease: lease)
        let child = FolderNode(url: childURL, lease: lease, isDirectory: true)
        child.children = []; first.children = [child]
        let other = FolderNode(url: otherURL, lease: FolderLease(otherURL))
        other.children = []
        let entered = expectation(description: "refresh worker paused")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let tree = FolderTree(roots: [first, other], directoryReader: { url in
            guard url == firstURL else { return [] }
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            return [childURL]
        })
        let window = mount(tree); defer { window.close() }
        tree.select(childURL, lease: lease)
        var selections: [URL] = []
        tree.onSelect = { selections.append($0.url) }
        tree.refresh(all: true)
        // Only the background reader blocks. The main thread remains available
        // for a new selection before the old folder's result is delivered.
        wait(for: [entered], timeout: 2)
        let otherRow = tree.view.row(forItem: other)
        XCTAssertGreaterThanOrEqual(otherRow, 0)
        tree.view.selectRowIndexes(IndexSet(integer: otherRow), byExtendingSelection: false)
        release.signal()
        waitUntil("old refresh and child restoration completed") {
            first.children?.count == 1 && !first.loading && first.children?.first?.loading == false && first.children?.first?.children != nil
        }
        XCTAssertEqual((tree.view.item(atRow: tree.view.selectedRow) as? FolderNode)?.url, otherURL, state(tree))
        XCTAssertEqual(selections, [otherURL])
    }

    @MainActor
    func testLargeMixedDirectoryUsesLazyWorkerEnumerationAndPhotoFilter() throws {
        _ = NSApplication.shared
        let root = try folder()
        for index in 0..<750 {
            for ext in ["ARW", "jpg"] { try Data().write(to: root.appendingPathComponent("image\(index).\(ext)")) }
        }
        for name in ["movie.mov", "document.pdf", "archive.zip", "notes.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        let node = FolderNode(url: root, lease: FolderLease(root))
        var reads = 0
        let tree = FolderTree(roots: [node], directoryReader: { url in
            XCTAssertFalse(Thread.isMainThread)
            reads += 1
            return try FolderReader.entries(url, directories: true, allFiles: true)
        })
        let window = mount(tree); defer { window.close() }
        XCTAssertEqual(reads, 0)
        tree.select(root)
        withExtendedLifetime(tree) {
            waitUntil("1500 photos and general files enumerated") { node.children?.count == 1504 && !node.loading }
        }
        XCTAssertEqual(node.children?.count, 1504, "reads=\(reads) error=\(node.error ?? "nil") loading=\(node.loading)")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try FolderReader.entries(root, directories: false).count, 1500)
        XCTAssertTrue(node.children?.allSatisfy { !$0.isDirectory } == true)
    }

}
