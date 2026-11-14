import Foundation
import Darwin
import XCTest
@testable import PhotoSelect

final class FilesystemRenameTests: XCTestCase {
    private func folder(onVolume: Bool = true) throws -> URL {
        let base = onVolume ? ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_VOLUME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory : FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("J-S-filesystem-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func store() throws -> TagStore { TagStore(fileURL: try folder(onVolume: false).appendingPathComponent("tags.json")) }
    private func engine(move: BatchRenameEngine.Move? = nil) throws -> BatchRenameEngine {
        BatchRenameEngine(journalDirectory: try folder(onVolume: false), move: move)
    }
    private func plan(_ root: URL, selected: Set<String>? = nil) throws -> RenamePlan {
        let entries = try BrowserEntry.read(root, showHidden: true).filter { selected?.contains($0.url.lastPathComponent) ?? true }
        return try RenamePlan.make(folder: root, photos: PhotoSortOrder().photos(entries), orderTitle: "파일 이름순 ↑", settings: RenameSettings(base: "Wedding", separator: "_", start: 1, digits: 3), existingNames: Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), selectedOnly: selected != nil)
    }
    private func execute(_ engine: BatchRenameEngine, _ plan: RenamePlan, _ tags: TagStore) throws -> RenameOutcome {
        let done = expectation(description: "volume rename transaction")
        var output: RenameOutcome?
        engine.execute(plan, tagStore: tags, lease: FolderLease(plan.folder), progress: { _, _, _ in }) { output = $0; done.fulfill() }
        wait(for: [done], timeout: 90); return try XCTUnwrap(output)
    }
    private func tag(_ url: URL, _ tags: TagStore) {
        let done = expectation(description: "volume tag")
        tags.toggle(url) { result in XCTAssertEqual(try? result.get(), true); done.fulfill() }
        wait(for: [done], timeout: 5)
    }
    func testVolumeCapabilityNoOverwriteAnd368ARWNamesPreserveBytesAndTags() throws {
        let root = try folder(), tags = try store(), engine = try engine()
        let support = try RenameFilesystem.prepare(in: root)
        print("Verified volume: \(support.description)")
        let realSony = try ProcessInfo.processInfo.environment["PHOTOSELECT_ARW_SAMPLE_DIRECTORY"].map {
            try Data(contentsOf: URL(fileURLWithPath: $0).appendingPathComponent("Sony-A7M4.ARW"))
        }
        func bytes(_ index: Int) -> Data {
            if index == 0, let realSony { return realSony }
            return Data("ARW original payload \(index)\u{0}Exif preserved".utf8)
        }
        for index in 0..<368 {
            try bytes(index).write(to: root.appendingPathComponent(String(format: "DSC%04d.ARW", index)))
        }
        tag(root.appendingPathComponent("DSC0000.ARW"), tags)
        let result = try execute(engine, plan(root), tags)
        XCTAssertTrue(result.completed, result.message)
        XCTAssertEqual(result.files.count, 368)
        XCTAssertEqual(result.files.filter { $0.state == .renamed }.count, 368)
        for index in 0..<368 {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(String(format: "Wedding_%03d.ARW", index + 1))), bytes(index))
        }
        XCTAssertEqual(result.taggedPaths, [TagStore.key(root.appendingPathComponent("Wedding_001.ARW"))])
        XCTAssertTrue(try engine.pending(in: root).isEmpty)
        let report: [String: Any] = ["format": support.volume.format, "method": support.method.rawValue, "files": 368, "allRenamed": result.completed, "bytesAndTagsPreserved": true, "physicalDevice": false, "realSonySamplePreserved": realSony != nil]
        if let output = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
    }
    func testVolumeSelectedMixedFilesCollisionAndLateCollisionDoNotOverwrite() throws {
        let root = try folder(), tags = try store(), data = Data("unchanged original".utf8)
        for name in ["A.ARW", "A.JPG", "B.ARW", "notes.txt"] { try data.write(to: root.appendingPathComponent(name)) }
        let result = try execute(engine(), plan(root, selected: ["A.ARW", "A.JPG"]), tags)
        XCTAssertTrue(result.completed, result.message)
        for name in ["Wedding_001.ARW", "Wedding_002.JPG", "B.ARW", "notes.txt"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data) }
        let conflict = try plan(root, selected: ["B.ARW"])
        XCTAssertFalse(conflict.valid)
        let a = root.appendingPathComponent("B.ARW"), b = root.appendingPathComponent("Wedding_001.ARW")
        XCTAssertThrowsError(try BatchRenameEngine.exclusiveMove(a, b))
        XCTAssertEqual(try Data(contentsOf: a), data); XCTAssertEqual(try Data(contentsOf: b), data)
        let lateRoot = try folder(), marker = Data("foreign race winner".utf8)
        try data.write(to: lateRoot.appendingPathComponent("A.ARW"))
        var collision: URL?
        let lateEngine = try engine(move: { source, destination in
            if collision == nil { collision = destination; try marker.write(to: destination, options: .withoutOverwriting) }
            try BatchRenameEngine.exclusiveMove(source, destination)
        })
        let late = try execute(lateEngine, plan(lateRoot), tags)
        XCTAssertFalse(late.completed); XCTAssertTrue(late.restored, late.message)
        XCTAssertEqual(try Data(contentsOf: lateRoot.appendingPathComponent("A.ARW")), data)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(collision)), marker)
    }
    func testVolumeConcurrentRenamesHaveExactlyOneWinner() throws {
        let root = try folder(), operation = try RenameFilesystem.prepare(in: root).operation
        for round in 0..<128 {
            let a = root.appendingPathComponent("a\(round).ARW"), b = root.appendingPathComponent("b\(round).ARW"), target = root.appendingPathComponent("target\(round).ARW")
            let first = Data("first-\(round)".utf8), second = Data("second-\(round)".utf8)
            try first.write(to: a); try second.write(to: b)
            let group = DispatchGroup(), lock = NSLock()
            var results: [(URL, Bool)] = []
            for source in [a, b] {
                group.enter()
                DispatchQueue.global().async {
                    let success: Bool
                    do { try operation(source, target); success = true } catch { success = false }
                    lock.lock(); results.append((source, success)); lock.unlock(); group.leave()
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            XCTAssertEqual(results.filter { $0.1 }.count, 1, "No-replace must have exactly one winner")
            let winner = try XCTUnwrap(results.first { $0.1 }?.0), loser = try XCTUnwrap(results.first { !$0.1 }?.0)
            XCTAssertEqual(try Data(contentsOf: target), winner == a ? first : second)
            XCTAssertEqual(try Data(contentsOf: loser), loser == a ? first : second)
            XCTAssertFalse(FileManager.default.fileExists(atPath: winner.path))
        }
    }
    func testVolumeRollbackInterruptedRecoveryAndRemount() throws {
        let root = try folder(), tags = try store()
        for name in ["A.ARW", "B.JPG"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        tag(root.appendingPathComponent("A.ARW"), tags)
        var failed = false
        let broken = try engine(move: { source, destination in
            if destination.lastPathComponent == "Wedding_002.JPG" { failed = true; throw POSIXError(.EIO) }
            if failed && destination.lastPathComponent == "A.ARW" { throw POSIXError(.EACCES) }
            try BatchRenameEngine.exclusiveMove(source, destination)
        })
        let result = try execute(broken, plan(root), tags)
        XCTAssertFalse(result.completed); XCTAssertFalse(result.restored)
        XCTAssertTrue(result.files.contains { $0.state == .temporary || $0.state == .renamed })
        let journal = try XCTUnwrap(result.journalURL)
        if let image = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_IMAGE"],
           let mount = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_VOLUME"] {
            // Both paths are disposable image paths supplied by the test script;
            // never detach a user-selected or physical volume.
            let imageURL = URL(fileURLWithPath: image), mountURL = URL(fileURLWithPath: mount)
            guard imageURL.pathExtension == "sparseimage", imageURL.deletingLastPathComponent() == mountURL.deletingLastPathComponent(),
                  mountURL.lastPathComponent.hasPrefix("mount-"),
                  try imageURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw RenameProblem(message: "Disposable image provenance missing") }
            try runHdiutil(["detach", mount])
            try runHdiutil(["attach", "-nobrowse", "-mountpoint", mount, image])
            print("Verified disposable-image detach/reattach: \(mountURL.lastPathComponent)")
        }
        let done = expectation(description: "resume recovery after remount")
        var recovered: RenameOutcome?
        let available = BatchRenameEngine(journalDirectory: broken.journalDirectory)
        available.recover(journal, folder: root, tagStore: tags, lease: FolderLease(root), progress: { _, _, _ in }) { recovered = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        let restored = try XCTUnwrap(recovered)
        XCTAssertFalse(restored.completed); XCTAssertTrue(restored.restored, restored.message)
        for name in ["A.ARW", "B.JPG"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8)) }
        XCTAssertEqual(restored.taggedPaths, [TagStore.key(root.appendingPathComponent("A.ARW"))])
        XCTAssertTrue(try available.pending(in: root).isEmpty)
    }
    private func runHdiutil(_ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = args
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RenameProblem(message: "Disposable image test hdiutil failed: \(args[0])") }
    }
    func testVolumeChangedSourceAndUnavailableVolumeNeverReportSuccess() throws {
        let root = try folder(), tags = try store()
        let source = root.appendingPathComponent("A.ARW")
        try Data([1]).write(to: source)
        let preview = try plan(root)
        try Data([2, 3]).write(to: source)
        let changed = try execute(engine(), preview, tags)
        XCTAssertFalse(changed.completed); XCTAssertFalse(changed.restored); XCTAssertTrue(changed.files.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data([2, 3]))
        let gone = try engine(move: { _, _ in throw POSIXError(.ENODEV) })
        let unavailable = try execute(gone, plan(root), tags)
        XCTAssertFalse(unavailable.completed)
        XCTAssertTrue(unavailable.files.allSatisfy { $0.state == .original })
        XCTAssertTrue(unavailable.message.contains("NSPOSIXErrorDomain \(ENODEV)"))

        let hiddenRoot = try folder(), metadata = try folder(onVolume: false)
        let tagFile = metadata.appendingPathComponent("tags.json"), durableTags = TagStore(fileURL: tagFile)
        for name in ["A.ARW", "B.JPG"] { try Data(name.utf8).write(to: hiddenRoot.appendingPathComponent(name)) }
        tag(hiddenRoot.appendingPathComponent("A.ARW"), durableTags)
        let tagBytes = try Data(contentsOf: tagFile)
        let away = hiddenRoot.deletingLastPathComponent().appendingPathComponent(".J-S-unavailable-" + UUID().uuidString)
        var disconnected = false
        let disappearing = try engine(move: { source, destination in
            try BatchRenameEngine.exclusiveMove(source, destination)
            if !disconnected {
                disconnected = true
                try FileManager.default.moveItem(at: hiddenRoot, to: away)
                throw POSIXError(.ENODEV)
            }
        })
        defer {
            if FileManager.default.fileExists(atPath: away.path), !FileManager.default.fileExists(atPath: hiddenRoot.path) {
                try? FileManager.default.moveItem(at: away, to: hiddenRoot)
            }
        }
        let missing = try execute(disappearing, plan(hiddenRoot), durableTags)
        XCTAssertFalse(missing.completed); XCTAssertFalse(missing.restored)
        XCTAssertTrue(missing.mapping.isEmpty); XCTAssertNil(missing.taggedPaths)
        XCTAssertEqual(missing.files.filter { $0.state == .unknown }.count, 2)
        XCTAssertEqual(try Data(contentsOf: tagFile), tagBytes, "Unknown locations must not rewrite tags with guessed paths")
        let pending = try XCTUnwrap(missing.journalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        try FileManager.default.moveItem(at: away, to: hiddenRoot)
        let restored = expectation(description: "recover after path becomes available")
        var recovered: RenameOutcome?
        let recovery = BatchRenameEngine(journalDirectory: disappearing.journalDirectory)
        recovery.recover(pending, folder: hiddenRoot, tagStore: durableTags, lease: FolderLease(hiddenRoot), progress: { _, _, _ in }) { recovered = $0; restored.fulfill() }
        wait(for: [restored], timeout: 30)
        XCTAssertTrue(try XCTUnwrap(recovered).restored, recovered?.message ?? "")
        for name in ["A.ARW", "B.JPG"] { XCTAssertEqual(try Data(contentsOf: hiddenRoot.appendingPathComponent(name)), Data(name.utf8)) }
    }
    func testVolumeUnsafeOrUnsupportedFallbackIsRejectedBeforePhotosChange() throws {
        let root = try folder(), photo = root.appendingPathComponent("original.ARW")
        try Data([1, 2, 3]).write(to: photo)
        var fallbackCalls = 0
        XCTAssertThrowsError(try RenameFilesystem.prepare(in: root, nativeMove: { _, _ in throw POSIXError(.EPERM) }, catalogMove: { _, _ in fallbackCalls += 1 }))
        XCTAssertEqual(fallbackCalls, 0, "Permission errors must not switch backends")
        XCTAssertThrowsError(try RenameFilesystem.prepare(in: root, nativeMove: { _, _ in throw POSIXError(.ENOTSUP) }, catalogMove: { _, _ in throw POSIXError(.ENOTSUP) }))
        XCTAssertThrowsError(try RenameFilesystem.prepare(in: root, nativeMove: { _, _ in throw POSIXError(.ENOTSUP) }, catalogMove: { source, target in
            // Simulate a broken backend that silently overwrites the disposable probe.
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: source, to: target)
        }))
        XCTAssertEqual(try Data(contentsOf: photo), Data([1, 2, 3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["original.ARW"])
    }
}
