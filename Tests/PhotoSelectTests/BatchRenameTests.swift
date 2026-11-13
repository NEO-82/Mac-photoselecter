import XCTest
@testable import PhotoSelect

final class BatchRenameTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func entries(_ root: URL) throws -> [BrowserEntry] { try BrowserEntry.read(root, showHidden: true) }
    private func execute(_ engine: BatchRenameEngine, _ plan: RenamePlan, _ store: TagStore) throws -> RenameOutcome {
        let done = expectation(description: "batch transaction")
        var output: RenameOutcome?
        engine.execute(plan, tagStore: store, lease: FolderLease(plan.folder), progress: { _, _, _ in }) { result in output = result; done.fulfill() }
        wait(for: [done], timeout: 30); return try XCTUnwrap(output)
    }
    private func tag(_ url: URL, store: TagStore) {
        let done = expectation(description: "seed tag")
        store.toggle(url) { result in XCTAssertEqual(try? result.get(), true); done.fulfill() }
        wait(for: [done], timeout: 5)
    }
    private func makePlan(_ root: URL, base: String = "Wedding") throws -> RenamePlan {
        try RenamePlan.make(folder: root, photos: entries(root), orderTitle: "파일 이름순 ↑",
            settings: RenameSettings(base: base, separator: "_", start: 1, digits: 3), existingNames: Set(try FileManager.default.contentsOfDirectory(atPath: root.path)))
    }
    func testThreeThousandPreviewUsesSortedOrderIndependentExtensionsAndContinuousNumbers() throws {
        let root = try folder()
        let photos = (0..<3000).map { index in BrowserEntry(url: root.appendingPathComponent("DSC\(index / 2)." + (index.isMultiple(of: 2) ? "ARW" : "JPG")), isDirectory: false, fileBytes: Int64(index), capturedAt: Date(timeIntervalSince1970: Double(index))) }
        for criterion in PhotoSortCriterion.allCases {
            for ascending in [true, false] {
                let order = PhotoSortOrder(criterion: criterion, ascending: ascending), sorted = PhotoSortOrder(criterion: criterion, ascending: ascending).photos(photos)
                let plan = try RenamePlan.make(folder: root, photos: sorted, orderTitle: order.title, settings: RenameSettings(base: "Wedding", separator: "_", start: 1, digits: 4), existingNames: Set(photos.map { $0.url.lastPathComponent }))
                XCTAssertTrue(plan.valid); XCTAssertEqual(plan.rows.count, 3000)
                XCTAssertEqual(plan.rows.first?.original, sorted.first?.url.lastPathComponent)
                XCTAssertEqual(plan.rows.first?.proposed, "Wedding_0001." + sorted[0].url.pathExtension)
                XCTAssertEqual(plan.rows.last?.proposed, "Wedding_3000." + sorted[2999].url.pathExtension)
                XCTAssertEqual(Set(plan.rows.map(\.proposed)).count, 3000)
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "Preview must not write files")
    }
    func testCommitUpdatesOnlyTargetsAndTagsWithoutChangingPhotoBytes() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        let raw = root.appendingPathComponent("DSC.ARW"), jpg = root.appendingPathComponent("DSC.JPG")
        let rawData = Data("raw original bytes".utf8), jpgData = Data("jpeg original bytes".utf8)
        try rawData.write(to: raw); try jpgData.write(to: jpg)
        let document = root.appendingPathComponent("notes.txt"); try Data("notes".utf8).write(to: document)
        let child = root.appendingPathComponent("child"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try rawData.write(to: child.appendingPathComponent("inside.ARW"))
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json")); tag(raw, store: store)
        let plan = try makePlan(root)
        let engine = BatchRenameEngine(journalDirectory: journals)
        let result = try execute(engine, plan, store)
        XCTAssertTrue(result.completed, result.message)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Wedding_001.ARW")), rawData)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Wedding_002.JPG")), jpgData)
        XCTAssertEqual(try Data(contentsOf: document), Data("notes".utf8))
        XCTAssertEqual(try Data(contentsOf: child.appendingPathComponent("inside.ARW")), rawData)
        let restored = expectation(description: "renamed tag survives restart")
        TagStore(fileURL: metadata.appendingPathComponent("tags.json")).load { result in
            XCTAssertEqual(try? result.get(), Set([TagStore.key(root.appendingPathComponent("Wedding_001.ARW")))])); restored.fulfill()
        }
        wait(for: [restored], timeout: 5); XCTAssertTrue(try engine.pending(in: root).isEmpty)
    }
    func testCycleUsesTemporaryNamesAndTagMappingIsSimultaneous() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        let one = root.appendingPathComponent("Photo_001.JPG"), two = root.appendingPathComponent("Photo_002.JPG")
        try Data([1]).write(to: one); try Data([2]).write(to: two)
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json")); tag(one, store: store)
        let reversed = PhotoSortOrder(criterion: .name, ascending: false).photos(try entries(root))
        let plan = try RenamePlan.make(folder: root, photos: reversed, orderTitle: "파일 이름순 ↓", settings: RenameSettings(base: "Photo", separator: "_", start: 1, digits: 3), existingNames: Set(["Photo_001.JPG", "Photo_002.JPG"]))
        let result = try execute(BatchRenameEngine(journalDirectory: journals), plan, store)
        XCTAssertTrue(result.completed, result.message)
        XCTAssertEqual(try Data(contentsOf: one), Data([2])); XCTAssertEqual(try Data(contentsOf: two), Data([1]))
        XCTAssertEqual(result.taggedPaths, [TagStore.key(two)])
    }
    func testConflictPermissionErrorAndChangedFolderNeverOverwrite() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        let original = root.appendingPathComponent("old.JPG"); try Data([1]).write(to: original)
        let conflict = root.appendingPathComponent("Wedding_001.JPG"); try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: true)
        XCTAssertFalse(try makePlan(root).valid)
        try FileManager.default.removeItem(at: conflict)
        let plan = try makePlan(root)
        try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: true)
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json"))
        let result = try execute(BatchRenameEngine(journalDirectory: journals), plan, store)
        XCTAssertFalse(result.completed); XCTAssertEqual(try Data(contentsOf: original), Data([1]))
        try FileManager.default.removeItem(at: conflict)
        var failed = false
        let denied = BatchRenameEngine(journalDirectory: journals, move: { source, destination in
            if !failed { failed = true; throw CocoaError(.fileWriteNoPermission) }
            try BatchRenameEngine.exclusiveMove(source, destination)
        })
        let permission = try execute(denied, plan, store)
        XCTAssertFalse(permission.completed); XCTAssertTrue(permission.restored, permission.message)
        XCTAssertEqual(try Data(contentsOf: original), Data([1]))
    }
    func testMiddleCommitFailureRollsBackOriginalNamesAndTags() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        for number in 1...3 { try Data([UInt8(number)]).write(to: root.appendingPathComponent("\(number).JPG")) }
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json")); tag(root.appendingPathComponent("1.JPG"), store: store)
        var calls = 0
        let engine = BatchRenameEngine(journalDirectory: journals, move: { a, b in
            calls += 1; if calls == 5 { throw CocoaError(.fileWriteNoPermission) }
            try BatchRenameEngine.exclusiveMove(a, b)
        })
        let outcome = try execute(engine, makePlan(root), store)
        XCTAssertFalse(outcome.completed); XCTAssertTrue(outcome.restored, outcome.message)
        for number in 1...3 { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(number).JPG")), Data([UInt8(number)])) }
        XCTAssertEqual(outcome.taggedPaths, [TagStore.key(root.appendingPathComponent("1.JPG"))])
        XCTAssertTrue(try engine.pending(in: root).isEmpty)
    }
    func testInterruptedDriveOperationKeepsJournalAndCanRecoverLater() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        for number in 1...2 { try Data([UInt8(number)]).write(to: root.appendingPathComponent("\(number).JPG")) }
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json")); tag(root.appendingPathComponent("1.JPG"), store: store)
        var calls = 0
        let disconnected = BatchRenameEngine(journalDirectory: journals, move: { a, b in
            calls += 1; if calls >= 2 { throw CocoaError(.fileNoSuchFile) }
            try BatchRenameEngine.exclusiveMove(a, b)
        })
        let failure = try execute(disconnected, makePlan(root), store)
        XCTAssertFalse(failure.completed); XCTAssertFalse(failure.restored)
        let journal = try XCTUnwrap(try disconnected.pending(in: root).first)
        let available = BatchRenameEngine(journalDirectory: journals)
        let done = expectation(description: "reconnect recovery")
        var output: RenameOutcome?
        available.recover(journal, folder: root, tagStore: store, lease: FolderLease(root), progress: { _, _, _ in }) { output = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(output).restored)
        for number in 1...2 { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(number).JPG")), Data([UInt8(number)])) }
        XCTAssertEqual(output?.taggedPaths, [TagStore.key(root.appendingPathComponent("1.JPG"))])
        XCTAssertTrue(try available.pending(in: root).isEmpty)
    }
    func testExclusiveMoveAndTraversalValidationProtectForeignFiles() throws {
        let root = try folder()
        let from = root.appendingPathComponent("a.JPG"), to = root.appendingPathComponent("b.JPG")
        try Data([1]).write(to: from); try Data([2]).write(to: to)
        XCTAssertThrowsError(try BatchRenameEngine.exclusiveMove(from, to))
        XCTAssertEqual(try Data(contentsOf: from), Data([1])); XCTAssertEqual(try Data(contentsOf: to), Data([2]))
        let bad = RenamePlan(folder: root, orderTitle: "", rows: [RenamePreview(original: "a.JPG", proposed: "../escape.JPG")])
        XCTAssertFalse(bad.valid)
        XCTAssertThrowsError(try RenamePlan.make(folder: root, photos: entries(root), orderTitle: "", settings: RenameSettings(base: "../bad", separator: "", start: 1, digits: 3), existingNames: []))
        XCTAssertThrowsError(try RenamePlan.make(folder: root, photos: entries(root), orderTitle: "", settings: RenameSettings(base: "X", separator: "", start: Int.max, digits: 3), existingNames: []))
    }
}
