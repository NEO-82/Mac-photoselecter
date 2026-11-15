import Foundation
import AppKit
import Darwin
import XCTest
@testable import PhotoSelect

final class FilesystemRenameTests: XCTestCase {
    func testVolumeCoordinatedProcessRace() throws {
        let env = ProcessInfo.processInfo.environment
        if let role = env["PHOTOSELECT_COORDINATED_RACE_ROLE"], let path = env["PHOTOSELECT_COORDINATED_RACE_FOLDER"] {
            guard ["a", "b"].contains(role) else { throw RenameProblem(message: "Invalid race role") }
            let root = URL(fileURLWithPath: path)
            guard root.lastPathComponent.hasPrefix("J-S-filesystem-test-") else { throw RenameProblem(message: "Race folder provenance missing") }
            let source = root.appendingPathComponent(role + ".ARW")
            var preview = RenamePlan(folder: root, orderTitle: "process race", rows: [RenamePreview(original: source.lastPathComponent, proposed: "target.ARW")])
            preview.selectedOnly = true; preview.volumeUUID = BatchRenameEngine.volume(root).0
            preview.snapshots[source.lastPathComponent] = try RenameSourceSnapshot.read(source)
            let engine = try engine(), tags = try store()
            try Data().write(to: root.appendingPathComponent(role + ".ready"), options: .withoutOverwriting)
            let deadline = Date().addingTimeInterval(15)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("go").path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard Date() < deadline else { throw RenameProblem(message: "Race barrier timed out") }
            var result: [String: Any] = ["executed": true]
            let outcome = try execute(engine, preview, tags)
            result["success"] = outcome.completed; result["message"] = outcome.message
            try JSONSerialization.data(withJSONObject: result).write(to: root.appendingPathComponent(role + ".json"), options: .withoutOverwriting)
            return
        }
        // Both processes use the public coordination path. Arbitrary writers
        // that bypass coordination remain outside this guarantee.
        for _ in 0..<4 {
            let root = try folder()
            for role in ["a", "b"] { try Data(role.utf8).write(to: root.appendingPathComponent(role + ".ARW")) }
            var processes: [Process] = []
            for role in ["a", "b"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["xctest", "-XCTest", "PhotoSelectTests.FilesystemRenameTests/testVolumeCoordinatedProcessRace", Bundle(for: FilesystemRenameTests.self).bundlePath]
                var child = env
                for key in ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCInjectBundleInto", "XCInjectBundle"] { child.removeValue(forKey: key) }
                child["PHOTOSELECT_COORDINATED_RACE_ROLE"] = role
                child["PHOTOSELECT_COORDINATED_RACE_FOLDER"] = root.path
                process.environment = child
                let log = root.appendingPathComponent(role + ".log")
                XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
                let output = try FileHandle(forWritingTo: log)
                process.standardOutput = output; process.standardError = output
                try process.run(); try output.close(); processes.append(process)
            }
            defer { for process in processes where process.isRunning { process.terminate() } }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline && !(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.ready").path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("b.ready").path)) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.ready").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.ready").path))
            try Data().write(to: root.appendingPathComponent("go"))
            while processes.contains(where: \.isRunning), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard processes.allSatisfy({ !$0.isRunning }) else { throw RenameProblem(message: "Coordinated child processes timed out") }
            var winners: [String] = []
            for (index, role) in ["a", "b"].enumerated() {
                let log = try String(contentsOf: root.appendingPathComponent(role + ".log"), encoding: .utf8)
                XCTAssertEqual(processes[index].terminationStatus, 0, log)
                let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(role + ".json"))) as? [String: Any])
                XCTAssertEqual(result["executed"] as? Bool, true)
                if result["success"] as? Bool == true { winners.append(role) }
            }
            XCTAssertEqual(winners.count, 1)
            let winner = try XCTUnwrap(winners.first), loser = winner == "a" ? "b" : "a"
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target.ARW")), Data(winner.utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(loser + ".ARW")), Data(loser.utf8))
        }
    }
    func testVolumeExtendedAttributesAndOrphanSidecarCollision() throws {
        let root = try folder(), source = root.appendingPathComponent("A.ARW")
        try Data("metadata payload".utf8).write(to: source)
        let name = "com.photoselect.rename-test", value = Data("preserve extended metadata".utf8)
        let set = value.withUnsafeBytes { setxattr(source.path, name, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(set, 0)
        let result = try execute(engine(), plan(root), store())
        XCTAssertTrue(result.completed, result.message)
        let target = root.appendingPathComponent("Wedding_001.ARW")
        let count = getxattr(target.path, name, nil, 0, 0, 0)
        XCTAssertEqual(count, value.count)
        if count > 0 {
            var actual = Data(count: count)
            let read = actual.withUnsafeMutableBytes { getxattr(target.path, name, $0.baseAddress, $0.count, 0, 0) }
            XCTAssertEqual(read, value.count); XCTAssertEqual(actual, value)
        }
        if try XCTUnwrap(support(root)).method == .coordinated {
            let other = root.appendingPathComponent("B.ARW"), sidecar = root.appendingPathComponent("._occupied.ARW")
            let marker = Data("unrelated orphan metadata".utf8)
            try Data("another photo".utf8).write(to: other); try marker.write(to: sidecar)
            XCTAssertThrowsError(try RenameFilesystem.coordinatedMove(other, root.appendingPathComponent("occupied.ARW")))
            XCTAssertEqual(try Data(contentsOf: other), Data("another photo".utf8))
            XCTAssertEqual(try Data(contentsOf: sidecar), marker)
        }
    }
    @MainActor
    func testVolumeCompatibilityConsentCancelAndActualRename() throws {
        _ = NSApplication.shared
        let root = try folder(), tags = try store()
        let source = root.appendingPathComponent("A.ARW"), bytes = Data("original fixture".utf8)
        try bytes.write(to: source)
        let engine = BatchRenameEngine(journalDirectory: try folder(onVolume: false))
        let entries = try BrowserEntry.read(root, showHidden: true)
        let controller = BatchRenameWindow(folder: root, photos: entries, existingNames: ["A.ARW"], orderTitle: "test",
            engine: engine, tags: tags, lease: FolderLease(root), sourceVolumeUUID: BatchRenameEngine.volume(root).0)
        let window = try XCTUnwrap(controller.window)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.makeKeyAndOrderFront(nil); parent.beginSheet(window)
        defer { if window.sheetParent != nil { parent.endSheet(window) }; controller.close(); parent.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views($0) } }
        func until(_ label: String, _ condition: @escaping () -> Bool) {
            let done = expectation(description: label), deadline = Date().addingTimeInterval(15)
            func poll() {
                if condition() { done.fulfill() }
                else if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() } }
            }
            poll(); wait(for: [done], timeout: 16)
        }
        let run = try XCTUnwrap(views(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "RenameExecute" })
        until("rename preview ready") { run.isEnabled }
        var result: RenameOutcome?
        controller.onComplete = { result = $0 }
        let volume = try RenameFilesystem.Volume.read(root)
        let needsConsent = volume.format == "exfat" || volume.persistentIDs == false
        run.performClick(nil)
        if needsConsent {
            until("compatibility warning shown") { window.attachedSheet != nil }
            var sheet = try XCTUnwrap(window.attachedSheet)
            let warning = views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextField }.map(\.stringValue).joined()
            XCTAssertTrue(warning.contains("원자적으로"))
            let cancel = try XCTUnwrap(views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "취소" })
            cancel.performClick(nil)
            until("cancel leaves originals unchanged") { window.attachedSheet == nil }
            XCTAssertNil(result); XCTAssertFalse(engine.allowCoordinatedCompatibility)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            run.performClick(nil)
            until("compatibility warning shown again") { window.attachedSheet != nil }
            sheet = try XCTUnwrap(window.attachedSheet)
            let proceed = try XCTUnwrap(views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("동시 작업을") })
            proceed.performClick(nil)
        }
        until("rename completes") { result != nil }
        XCTAssertTrue(try XCTUnwrap(result).completed, result?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Photo_0001.ARW")), bytes)
        XCTAssertEqual(engine.allowCoordinatedCompatibility, needsConsent)
    }
    private func folder(onVolume: Bool = true, preserveForRemount: Bool = false) throws -> URL {
        let base = onVolume ? ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_VOLUME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory : FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("J-S-filesystem-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        if !preserveForRemount || ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_IMAGE"] == nil {
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        }
        return root
    }
    private func support(_ root: URL) throws -> RenameFilesystem.Prepared? {
        // This suite now requires actual successful renames on exFAT too.
        try RenameFilesystem.prepare(in: root, allowCompatibility: true)
    }
    private func store() throws -> TagStore { TagStore(fileURL: try folder(onVolume: false).appendingPathComponent("tags.json")) }
    private func engine(move: BatchRenameEngine.Move? = nil) throws -> BatchRenameEngine {
        let value = BatchRenameEngine(journalDirectory: try folder(onVolume: false), move: move)
        value.allowCoordinatedCompatibility = true
        return value
    }
    private func plan(_ root: URL, selected: Set<String>? = nil) throws -> RenamePlan {
        let entries = try BrowserEntry.read(root, showHidden: true).filter { selected?.contains($0.url.lastPathComponent) ?? true }
        return try RenamePlan.make(folder: root, photos: PhotoSortOrder().photos(entries), orderTitle: "파일 이름순 ↑", settings: RenameSettings(base: "Wedding", separator: "_", start: 1, digits: 3), existingNames: Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), selectedOnly: selected != nil)
    }
    private func execute(_ engine: BatchRenameEngine, _ plan: RenamePlan, _ tags: TagStore) throws -> RenameOutcome {
        let done = expectation(description: "volume rename transaction")
        var output: RenameOutcome?
        engine.execute(plan, tagStore: tags, lease: FolderLease(plan.folder), progress: { _, _, _ in }) { output = $0; done.fulfill() }
        wait(for: [done], timeout: 300); return try XCTUnwrap(output)
    }
    private func tag(_ url: URL, _ tags: TagStore) {
        let done = expectation(description: "volume tag")
        tags.toggle(url) { result in XCTAssertEqual(try? result.get(), true); done.fulfill() }
        wait(for: [done], timeout: 5)
    }
    func testVolume14RealSonyFilesRenameWithoutChangingBytesOrUnselectedFiles() throws {
        guard let samples = ProcessInfo.processInfo.environment["PHOTOSELECT_ARW_SAMPLE_DIRECTORY"] else {
            throw XCTSkip("Checksum-pinned Sony samples required")
        }
        let payload = try Data(contentsOf: URL(fileURLWithPath: samples).appendingPathComponent("Sony-A7M4.ARW"))
        let root = try folder(), tags = try store(), engine = try engine()
        var selected: Set<String> = []
        for index in 0..<14 {
            let name = String(format: "DSC%04d.ARW", index)
            selected.insert(name)
            try payload.write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
        }
        let bystander = root.appendingPathComponent("unselected.JPG")
        try Data("unselected original".utf8).write(to: bystander)
        tag(root.appendingPathComponent("DSC0000.ARW"), tags); tag(bystander, tags)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try execute(engine, plan(root, selected: selected), tags)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertTrue(result.completed, result.message)
        XCTAssertEqual(result.files.filter { $0.state == .renamed }.count, 14)
        for index in 0..<14 {
            try autoreleasepool {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(String(format: "Wedding_%03d.ARW", index + 1))), payload)
            }
        }
        XCTAssertEqual(try Data(contentsOf: bystander), Data("unselected original".utf8))
        XCTAssertEqual(result.taggedPaths, [TagStore.key(bystander), TagStore.key(root.appendingPathComponent("Wedding_001.ARW"))])
        XCTAssertTrue(try engine.pending(in: root).isEmpty)
        if let output = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_REPORT"] {
            let report: [String: Any] = ["files": 14, "bytesPerFile": payload.count, "elapsedMilliseconds": elapsed,
                "allRenamed": result.completed, "allBytesAndTagsPreserved": true, "unselectedUnchanged": true,
                "fixture": "14 full-size copies of one checksum-pinned Sony A7M4 sample", "physicalDevice": false]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to:
                URL(fileURLWithPath: output.replacingOccurrences(of: "filesystem-integration-", with: "filesystem-real14-")))
        }
    }
    func testVolumeRenameCountsTimingAndModificationDates() throws {
        var rows: [[String: Any]] = []
        for count in [1, 14, 100, 1200] {
            let root = try folder(), tags = try store(), engine = try engine()
            var snapshots: [RenameSourceSnapshot] = []
            func original(_ index: Int) -> String {
                String(format: "source_%04d.", index) + (index % 2 == 0 ? "ARW" : "JPG")
            }
            for index in 0..<count {
                let file = root.appendingPathComponent(original(index))
                try Data("small synthetic image payload \(index)".utf8).write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
                snapshots.append(try RenameSourceSnapshot.read(file))
            }
            let excluded = ["notes.txt", "._shadow.ARW"]
            for name in excluded { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
            tag(root.appendingPathComponent(original(0)), tags)
            let supported = try support(root) != nil
            let preview = try plan(root)
            let start = ProcessInfo.processInfo.systemUptime
            let outcome = try execute(engine, preview, tags)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertEqual(outcome.completed, supported, outcome.message)
            XCTAssertEqual(outcome.files.filter { $0.state == .renamed }.count, supported ? count : 0)
            for index in 0..<count {
                let name = supported ? String(format: "Wedding_%03d.", index + 1) + (index % 2 == 0 ? "ARW" : "JPG") : original(index)
                let file = root.appendingPathComponent(name)
                XCTAssertEqual(try Data(contentsOf: file), Data("small synthetic image payload \(index)".utf8))
                let after = try RenameSourceSnapshot.read(file)
                XCTAssertEqual(after.modifiedSeconds, snapshots[index].modifiedSeconds)
                XCTAssertEqual(after.modifiedNanos, snapshots[index].modifiedNanos)
            }
            for name in excluded { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8)) }
            XCTAssertTrue(try engine.pending(in: root).isEmpty)
            let format = try RenameFilesystem.Volume.read(root).format
            rows.append(["format": format, "requestedFiles": count, "renamedFiles": supported ? count : 0,
                         "elapsedMilliseconds": elapsed, "status": supported ? "renamed" : "blocked-not-renamed",
                         "fixture": "small synthetic files, not full-size RAW", "physicalDevice": false])
            print("Rename timing \(format): \(count) requested, \(supported ? count : 0) renamed, \(elapsed) ms")
        }
        if let output = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_REPORT"] {
            let target = URL(fileURLWithPath: output.replacingOccurrences(of: "filesystem-integration-", with: "filesystem-timing-"))
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: target)
        }
    }
    func testVolumeCapabilityNoOverwriteAnd368ARWNamesPreserveBytesAndTags() throws {
        let root = try folder(), tags = try store(), engine = try engine()
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
        let support = try self.support(root)
        let result = try execute(engine, plan(root), tags)
        if support == nil {
            XCTAssertFalse(result.completed); XCTAssertFalse(result.restored)
            XCTAssertTrue(result.files.isEmpty); XCTAssertTrue(result.mapping.isEmpty); XCTAssertNil(result.journalURL)
            XCTAssertTrue(result.message.contains("exfat"))
            for index in 0..<368 { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(String(format: "DSC%04d.ARW", index))), bytes(index)) }
            XCTAssertTrue(try engine.pending(in: root).isEmpty)
            let loaded = expectation(description: "unsupported volume keeps original tags")
            tags.load { value in XCTAssertEqual(try? value.get(), [TagStore.key(root.appendingPathComponent("DSC0000.ARW"))]); loaded.fulfill() }
            wait(for: [loaded], timeout: 5)
            if let output = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_REPORT"] {
                let report: [String: Any] = ["format": "exfat", "status": "blocked-no-safe-atomic-rename", "files": 368, "allRenamed": false,
                    "originalNamesBytesAndTagsUnchanged": true, "realSonySourceChecked": realSony != nil, "physicalDevice": false]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            }
            return
        }
        let verified = try XCTUnwrap(support)
        print("Verified volume: \(verified.description)")
        XCTAssertTrue(result.completed, result.message)
        XCTAssertEqual(result.files.count, 368)
        XCTAssertEqual(result.files.filter { $0.state == .renamed }.count, 368)
        for index in 0..<368 {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(String(format: "Wedding_%03d.ARW", index + 1))), bytes(index))
        }
        XCTAssertEqual(result.taggedPaths, [TagStore.key(root.appendingPathComponent("Wedding_001.ARW"))])
        XCTAssertTrue(try engine.pending(in: root).isEmpty)
        let report: [String: Any] = ["format": verified.volume.format, "method": verified.method.rawValue, "files": 368, "allRenamed": result.completed, "bytesAndTagsPreserved": true, "physicalDevice": false, "realSonySamplePreserved": realSony != nil]
        if let output = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
    }
    func testVolumeSelectedMixedFilesCollisionAndLateCollisionDoNotOverwrite() throws {
        let root = try folder(), tags = try store(), data = Data("unchanged original".utf8)
        for name in ["A.ARW", "A.JPG", "B.ARW", "notes.txt"] { try data.write(to: root.appendingPathComponent(name)) }
        let support = try self.support(root)
        let result = try execute(engine(), plan(root, selected: ["A.ARW", "A.JPG"]), tags)
        if support == nil {
            XCTAssertFalse(result.completed); XCTAssertFalse(result.restored); XCTAssertNil(result.journalURL)
            for name in ["A.ARW", "A.JPG", "B.ARW", "notes.txt"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data) }
            return
        }
        XCTAssertTrue(result.completed, result.message)
        for name in ["Wedding_001.ARW", "Wedding_002.JPG", "B.ARW", "notes.txt"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data) }
        let conflict = try plan(root, selected: ["B.ARW"])
        XCTAssertFalse(conflict.valid)
        let a = root.appendingPathComponent("B.ARW"), b = root.appendingPathComponent("Wedding_001.ARW")
        XCTAssertThrowsError(try RenameFilesystem.move(a, b, allowCompatibility: true))
        XCTAssertEqual(try Data(contentsOf: a), data); XCTAssertEqual(try Data(contentsOf: b), data)
        let lateRoot = try folder(), marker = Data("foreign race winner".utf8)
        try data.write(to: lateRoot.appendingPathComponent("A.ARW"))
        var collision: URL?
        let lateEngine = try engine(move: { source, destination in
            if collision == nil { collision = destination; try marker.write(to: destination, options: .withoutOverwriting) }
            try RenameFilesystem.move(source, destination, allowCompatibility: true)
        })
        let late = try execute(lateEngine, plan(lateRoot), tags)
        XCTAssertFalse(late.completed); XCTAssertTrue(late.restored, late.message)
        XCTAssertEqual(try Data(contentsOf: lateRoot.appendingPathComponent("A.ARW")), data)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(collision)), marker)
    }
    func testVolumeConcurrentRenamesHaveExactlyOneWinner() throws {
        let root = try folder(), support = try self.support(root)
        let operation = try XCTUnwrap(support).operation
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
            if support == nil {
                XCTAssertEqual(results.filter { $0.1 }.count, 0, "Unsupported atomic rename must never move either original")
                XCTAssertEqual(try Data(contentsOf: a), first); XCTAssertEqual(try Data(contentsOf: b), second)
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)); continue
            }
            XCTAssertEqual(results.filter { $0.1 }.count, 1, "No-replace must have exactly one winner")
            let winner = try XCTUnwrap(results.first { $0.1 }?.0), loser = try XCTUnwrap(results.first { !$0.1 }?.0)
            XCTAssertEqual(try Data(contentsOf: target), winner == a ? first : second)
            XCTAssertEqual(try Data(contentsOf: loser), loser == a ? first : second)
            XCTAssertFalse(FileManager.default.fileExists(atPath: winner.path))
        }
    }
    private func recover(_ engine: BatchRenameEngine, _ journal: URL, _ root: URL, _ tags: TagStore) throws -> RenameOutcome {
        let done = expectation(description: "recover original names and tags")
        var result: RenameOutcome?
        engine.recover(journal, folder: root, tagStore: tags, lease: FolderLease(root), progress: { _, _, _ in }) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 90)
        return try XCTUnwrap(result)
    }
    func testVolumeContentIdentityRecovery() throws {
        if let receiptPath = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_RECOVERY_RECEIPT"] {
            let receiptURL = URL(fileURLWithPath: receiptPath)
            var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
            let root = URL(fileURLWithPath: try XCTUnwrap(receipt["folder"] as? String))
            let metadata = URL(fileURLWithPath: try XCTUnwrap(receipt["metadata"] as? String))
            let mount = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_VOLUME"]))
            guard root.deletingLastPathComponent().resolvingSymlinksInPath() == mount.resolvingSymlinksInPath(),
                  root.lastPathComponent.hasPrefix("J-S-filesystem-test-"), metadata.lastPathComponent.hasPrefix("J-S-filesystem-test-") else {
                throw RenameProblem(message: "Recovery receipt provenance missing")
            }
            let engine = BatchRenameEngine(journalDirectory: metadata.appendingPathComponent("journals"))
            engine.allowCoordinatedCompatibility = true
            let journal = URL(fileURLWithPath: try XCTUnwrap(receipt["journal"] as? String))
            let tags = TagStore(fileURL: metadata.appendingPathComponent("tags.json"))
            XCTAssertEqual(try engine.readJournal(journal, folder: root).version, 2)
            let result = try recover(engine, journal, root, tags)
            XCTAssertTrue(result.restored, result.message)
            XCTAssertFalse(result.completed)
            for name in ["A.ARW", "B.JPG"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8)) }
            XCTAssertEqual(result.taggedPaths, [TagStore.key(root.appendingPathComponent("A.ARW"))])
            XCTAssertTrue(try engine.pending(in: root).isEmpty)
            receipt["recoveredAfterReconnect"] = true
            receipt["originalNamesBytesAndTagsPreserved"] = true
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: receiptURL)
            addTeardownBlock { try? FileManager.default.removeItem(at: metadata) }
            return
        }
        // A separate, deterministic check changes stored inode numbers, so
        // recovery cannot accidentally pass by relying on persistent IDs.
        let root = try folder(), tags = try store(), engine = try engine(), id = UUID()
        let source = root.appendingPathComponent("A.ARW")
        try Data("content identity across changed inodes".utf8).write(to: source)
        tag(source, tags)
        let fingerprint = try RenameFingerprint.read(source)
        let identity = try RenameIdentity.read(source)
        let temporary = ".J-S-rename-" + id.uuidString + "-0.ARW"
        try RenameFilesystem.move(source, root.appendingPathComponent(temporary), allowCompatibility: true)
        var item = RenameJournal.Item(original: "A.ARW", destination: "Wedding_001.ARW", temporary: temporary,
            identity: RenameIdentity(device: identity.device, inode: identity.inode &+ 10_000))
        item.fingerprint = fingerprint
        let volume = BatchRenameEngine.volume(root)
        let journal = RenameJournal(version: 2, id: id, folderPath: root.path, volumeUUID: volume.0,
            relativeFolder: volume.1, orderTitle: "test", items: [item], tagSnapshot: [TagStore.key(source)], phase: "staged")
        let journalURL = engine.journalDirectory.appendingPathComponent(id.uuidString + ".json")
        try JSONEncoder().encode(journal).write(to: journalURL)
        let result = try recover(engine, journalURL, root, tags)
        XCTAssertTrue(result.restored, result.message)
        XCTAssertEqual(try Data(contentsOf: source), Data("content identity across changed inodes".utf8))
    }
    func testVolumeRollbackInterruptedRecoveryAndRemount() throws {
        let root = try folder(preserveForRemount: true)
        let prepared = try XCTUnwrap(try support(root))
        let externalRecovery = prepared.requiresContentIdentity && ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_IMAGE"] != nil
        let metadata = try folder(onVolume: false, preserveForRemount: externalRecovery)
        let tags = TagStore(fileURL: metadata.appendingPathComponent("tags.json"))
        for name in ["A.ARW", "B.JPG"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        tag(root.appendingPathComponent("A.ARW"), tags)
        var failed = false
        let broken = BatchRenameEngine(journalDirectory: metadata.appendingPathComponent("journals"), move: { source, destination in
            if destination.lastPathComponent == "Wedding_002.JPG" { failed = true; throw POSIXError(.EIO) }
            if failed && destination.lastPathComponent == "A.ARW" { throw POSIXError(.EACCES) }
            try RenameFilesystem.move(source, destination, allowCompatibility: true)
        })
        broken.allowCoordinatedCompatibility = true
        let result = try execute(broken, plan(root), tags)
        XCTAssertFalse(result.completed); XCTAssertFalse(result.restored)
        XCTAssertTrue(result.files.contains { $0.state == .temporary || $0.state == .renamed })
        let journal = try XCTUnwrap(result.journalURL)
        if externalRecovery, let output = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_REPORT"] {
            let receipt: [String: Any] = ["folder": root.path, "metadata": metadata.path, "journal": journal.path,
                "recoveredAfterReconnect": false, "physicalDevice": false]
            let url = URL(fileURLWithPath: output.replacingOccurrences(of: "filesystem-integration-", with: "filesystem-recovery-"))
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            return // The script reconnects, then runs testVolumeContentIdentityRecovery in a fresh process.
        }
        try remountDisposableImageIfRequested()
        let available = BatchRenameEngine(journalDirectory: broken.journalDirectory)
        available.allowCoordinatedCompatibility = true
        let restored = try recover(available, journal, root, tags)
        XCTAssertFalse(restored.completed); XCTAssertTrue(restored.restored, restored.message)
        for name in ["A.ARW", "B.JPG"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8)) }
        XCTAssertEqual(restored.taggedPaths, [TagStore.key(root.appendingPathComponent("A.ARW"))])
        XCTAssertTrue(try available.pending(in: root).isEmpty)
    }
    private func remountDisposableImageIfRequested() throws {
        if let image = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_IMAGE"],
           let mount = ProcessInfo.processInfo.environment["PHOTOSELECT_RENAME_TEST_VOLUME"] {
            // Both paths are disposable image paths supplied by the test script;
            // never detach a user-selected or physical volume.
            let imageURL = URL(fileURLWithPath: image), mountURL = URL(fileURLWithPath: mount)
            guard imageURL.pathExtension == "sparseimage", imageURL.deletingLastPathComponent() == mountURL.deletingLastPathComponent(),
                  mountURL.lastPathComponent.hasPrefix("mount-"),
                  try imageURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw RenameProblem(message: "Disposable image provenance missing") }
            guard let device = try disposableImageDevice(imageURL) else {
                throw RenameProblem(message: "Disposable image attachment missing before remount test")
            }
            do { try runHdiutil(["detach", device]) }
            catch {
                // A busy detach can unmount the volume but leave its disk image
                // attached. The old mount path then no longer identifies it.
                // Re-resolve only the proven test image before forcing a detach.
                if let remaining = try disposableImageDevice(imageURL) {
                    try runHdiutil(["detach", "-force", remaining])
                }
            }
            guard try disposableImageDevice(imageURL) == nil else {
                throw RenameProblem(message: "Disposable image remains attached")
            }
            try runHdiutil(["attach", "-nobrowse", "-mountpoint", mount, image])
            print("Verified disposable-image detach/reattach: \(mountURL.lastPathComponent)")
        }
    }
    private func disposableImageDevice(_ image: URL) throws -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]; process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw RenameProblem(message: "Cannot inspect disposable image attachments")
        }
        let matches = images.filter { entry in
            guard let path = entry["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath() == image.resolvingSymlinksInPath()
        }
        guard matches.count <= 1 else { throw RenameProblem(message: "Ambiguous disposable image attachment") }
        guard let match = matches.first else { return nil }
        guard let entities = match["system-entities"] as? [[String: Any]],
              let device = entities.first?["dev-entry"] as? String,
              device.hasPrefix("/dev/disk"),
              !device.dropFirst("/dev/disk".count).isEmpty,
              device.dropFirst("/dev/disk".count).allSatisfy(\.isNumber) else {
            throw RenameProblem(message: "Disposable image device provenance missing")
        }
        return device
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

        if try self.support(root) == nil { return }
        let hiddenRoot = try folder(), metadata = try folder(onVolume: false)
        let tagFile = metadata.appendingPathComponent("tags.json"), durableTags = TagStore(fileURL: tagFile)
        for name in ["A.ARW", "B.JPG"] { try Data(name.utf8).write(to: hiddenRoot.appendingPathComponent(name)) }
        tag(hiddenRoot.appendingPathComponent("A.ARW"), durableTags)
        let tagBytes = try Data(contentsOf: tagFile)
        let away = hiddenRoot.deletingLastPathComponent().appendingPathComponent(".J-S-unavailable-" + UUID().uuidString)
        var disconnected = false
        let disappearing = try engine(move: { source, destination in
            try RenameFilesystem.move(source, destination, allowCompatibility: true)
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
        recovery.allowCoordinatedCompatibility = true
        recovery.recover(pending, folder: hiddenRoot, tagStore: durableTags, lease: FolderLease(hiddenRoot), progress: { _, _, _ in }) { recovered = $0; restored.fulfill() }
        wait(for: [restored], timeout: 30)
        XCTAssertTrue(try XCTUnwrap(recovered).restored, recovered?.message ?? "")
        for name in ["A.ARW", "B.JPG"] { XCTAssertEqual(try Data(contentsOf: hiddenRoot.appendingPathComponent(name)), Data(name.utf8)) }
    }
    func testVolumeUnsafeOrUnsupportedFallbackIsRejectedBeforePhotosChange() throws {
        let root = try folder(), photo = root.appendingPathComponent("original.ARW")
        try Data([1, 2, 3]).write(to: photo)
        var fallbackCalls = 0
        XCTAssertThrowsError(try RenameFilesystem.prepare(in: root, nativeMove: { _, _ in throw POSIXError(.EPERM) }, relativeMove: { _, _ in fallbackCalls += 1 }))
        XCTAssertEqual(fallbackCalls, 0, "Permission errors must not switch backends")
        if try RenameFilesystem.Volume.read(root).format != "exfat" {
            let alternate = try RenameFilesystem.prepare(in: root, nativeMove: { _, _ in throw POSIXError(.ENOTSUP) })
            XCTAssertEqual(alternate.method.rawValue, "renameatx_np(RENAME_EXCL)")
        }
        XCTAssertThrowsError(try RenameFilesystem.prepare(in: root, nativeMove: { _, _ in throw POSIXError(.ENOTSUP) }, relativeMove: { _, _ in throw POSIXError(.ENOTSUP) }))
        XCTAssertThrowsError(try RenameFilesystem.prepare(in: root, nativeMove: { _, _ in throw POSIXError(.ENOTSUP) }, relativeMove: { source, target in
            // Simulate a broken backend that silently overwrites the disposable probe.
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: source, to: target)
        }))
        XCTAssertEqual(try Data(contentsOf: photo), Data([1, 2, 3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["original.ARW"])
    }
}
