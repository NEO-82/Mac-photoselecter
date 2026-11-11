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
}
