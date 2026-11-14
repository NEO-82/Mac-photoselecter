import XCTest
@testable import PhotoSelect

final class BatchRenameTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func entries(_ root: URL) throws -> [BrowserEntry] { try BrowserEntry.read(root, showHidden: true) }
    private func execute(_ engine: BatchRenameEngine, _ plan: RenamePlan, _ store: TagStore, timeout: TimeInterval = 30) throws -> RenameOutcome {
        let done = expectation(description: "batch transaction")
        var output: RenameOutcome?
        engine.execute(plan, tagStore: store, lease: FolderLease(plan.folder), progress: { _, _, _ in }) { result in output = result; done.fulfill() }
        wait(for: [done], timeout: timeout); return try XCTUnwrap(output)
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
            XCTAssertEqual(try? result.get(), Set([TagStore.key(root.appendingPathComponent("Wedding_001.ARW"))])); restored.fulfill()
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
        XCTAssertThrowsError(try RenamePlan.make(folder: root, photos: entries(root), orderTitle: "", settings: RenameSettings(base: String(repeating: "X", count: 100_000), separator: "", start: 1, digits: 3), existingNames: []))
    }
    func testCommittedRecoveryReplaysTagsIdempotentlyAcrossNameSwap() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        let a = root.appendingPathComponent("A.JPG"), b = root.appendingPathComponent("B.JPG")
        try Data([1]).write(to: a); try Data([2]).write(to: b)
        let id = UUID(), tempA = ".J-S-rename-" + id.uuidString + "-0.JPG", tempB = ".J-S-rename-" + id.uuidString + "-1.JPG"
        let items = [RenameJournal.Item(original: "A.JPG", destination: "B.JPG", temporary: tempA, identity: try RenameIdentity.read(a)),
                     RenameJournal.Item(original: "B.JPG", destination: "A.JPG", temporary: tempB, identity: try RenameIdentity.read(b))]
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json")); tag(a, store: store)
        try BatchRenameEngine.exclusiveMove(a, root.appendingPathComponent(tempA)); try BatchRenameEngine.exclusiveMove(b, root.appendingPathComponent(tempB))
        try BatchRenameEngine.exclusiveMove(root.appendingPathComponent(tempA), b); try BatchRenameEngine.exclusiveMove(root.appendingPathComponent(tempB), a)
        let volume = BatchRenameEngine.volume(root)
        let journal = RenameJournal(version: 1, id: id, folderPath: root.path, volumeUUID: volume.0, relativeFolder: volume.1,
            orderTitle: "파일 이름순 ↓", items: items, tagSnapshot: [TagStore.key(a)], phase: "committed")
        let file = journals.appendingPathComponent(id.uuidString + ".json")
        for _ in 0..<2 {
            try JSONEncoder().encode(journal).write(to: file)
            let engine = BatchRenameEngine(journalDirectory: journals, move: { _, _ in XCTFail("A committed recovery must not move files again") })
            let done = expectation(description: "idempotent replay")
            var result: RenameOutcome?
            engine.recover(file, folder: root, tagStore: store, lease: FolderLease(root), progress: { _, _, _ in }) { result = $0; done.fulfill() }
            wait(for: [done], timeout: 10)
            XCTAssertTrue(try XCTUnwrap(result).completed)
            XCTAssertEqual(result?.taggedPaths, Set([TagStore.key(b)]))
        }
        XCTAssertEqual(try Data(contentsOf: a), Data([2])); XCTAssertEqual(try Data(contentsOf: b), Data([1]))
    }
    func testTagWriteFailureRestoresFilesAndRetainsJournalUntilTagsAreWritable() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        let original = root.appendingPathComponent("old.JPG"); try Data([7]).write(to: original)
        var fail = false
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json"), writeData: { data, url in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        tag(original, store: store); fail = true
        let engine = BatchRenameEngine(journalDirectory: journals)
        let result = try execute(engine, makePlan(root), store)
        XCTAssertFalse(result.completed); XCTAssertTrue(result.restored)
        XCTAssertEqual(try Data(contentsOf: original), Data([7]))
        let journal = try XCTUnwrap(try engine.pending(in: root).first)
        fail = false
        let done = expectation(description: "tags become writable")
        var recovered: RenameOutcome?
        engine.recover(journal, folder: root, tagStore: store, lease: FolderLease(root), progress: { _, _, _ in }) { recovered = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(recovered).restored)
        XCTAssertEqual(recovered?.taggedPaths, Set([TagStore.key(original)]))
        XCTAssertTrue(try engine.pending(in: root).isEmpty)
    }
    func testForeignFileCreatedDuringFailureIsNeverOverwrittenOnRollback() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        for i in 1...3 { try Data([UInt8(i)]).write(to: root.appendingPathComponent("\(i).JPG")) }
        var calls = 0
        let engine = BatchRenameEngine(journalDirectory: journals, move: { a, b in
            calls += 1
            if calls == 5 {
                try Data([99]).write(to: root.appendingPathComponent("1.JPG"))
                throw CocoaError(.fileWriteNoPermission)
            }
            try BatchRenameEngine.exclusiveMove(a, b)
        })
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json"))
        let result = try execute(engine, makePlan(root), store)
        XCTAssertFalse(result.restored); XCTAssertNotNil(result.journalURL)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("1.JPG")), Data([99]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("2.JPG")), Data([2]))
        let journal = try XCTUnwrap(result.journalURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("1.JPG"))
        let done = expectation(description: "foreign conflict removed")
        var restored: RenameOutcome?
        BatchRenameEngine(journalDirectory: journals).recover(journal, folder: root, tagStore: store, lease: FolderLease(root), progress: { _, _, _ in }) { restored = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(restored).restored)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("1.JPG")), Data([1]))
    }
    func testHardLinkAliasesAndCorruptTagStoreRefuseBeforeFileChanges() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        let a = root.appendingPathComponent("1.JPG"), b = root.appendingPathComponent("2.JPG")
        try Data([8]).write(to: a); try FileManager.default.linkItem(at: a, to: b)
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json"))
        let engine = BatchRenameEngine(journalDirectory: journals)
        XCTAssertFalse(try execute(engine, makePlan(root), store).completed)
        XCTAssertEqual(try Data(contentsOf: a), Data([8])); XCTAssertEqual(try Data(contentsOf: b), Data([8]))
        try FileManager.default.removeItem(at: b)
        let tags = metadata.appendingPathComponent("broken-tags.json"), bytes = Data("corrupt metadata".utf8)
        try bytes.write(to: tags)
        XCTAssertFalse(try execute(engine, makePlan(root), TagStore(fileURL: tags)).completed)
        XCTAssertEqual(try Data(contentsOf: tags), bytes); XCTAssertEqual(try Data(contentsOf: a), Data([8]))
    }

    func testThreeThousandActualRenamesWithOneThousandTagsPreserveEveryFile() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        var oldTags: [String] = []
        for i in 0..<3000 {
            let ext = i.isMultiple(of: 2) ? "ARW" : "JPG"
            let url = root.appendingPathComponent(String(format: "%04d.%@", i, ext))
            try Data([UInt8(i % 251), UInt8((i / 251) % 251)]).write(to: url)
            if i.isMultiple(of: 3) { oldTags.append(TagStore.key(url)) }
        }
        let file = metadata.appendingPathComponent("tags.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "taggedPaths": oldTags]).write(to: file)
        let plan = try RenamePlan.make(folder: root, photos: entries(root), orderTitle: "파일 이름순 ↑",
            settings: RenameSettings(base: "Wedding", separator: "_", start: 1, digits: 4), existingNames: Set(try FileManager.default.contentsOfDirectory(atPath: root.path)))
        let engine = BatchRenameEngine(journalDirectory: journals)
        let started = ProcessInfo.processInfo.systemUptime
        let result = try execute(engine, plan, TagStore(fileURL: file), timeout: 120)
        XCTAssertTrue(result.completed, result.message)
        XCTAssertEqual(result.mapping.count, 3000); XCTAssertEqual(result.taggedPaths?.count, 1000)
        for i in 0..<3000 {
            let ext = i.isMultiple(of: 2) ? "ARW" : "JPG"
            let url = root.appendingPathComponent(String(format: "Wedding_%04d.%@", i + 1, ext))
            XCTAssertEqual(try Data(contentsOf: url), Data([UInt8(i % 251), UInt8((i / 251) % 251)]))
            XCTAssertEqual(result.taggedPaths?.contains(TagStore.key(url)), i.isMultiple(of: 3))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3000)
        XCTAssertTrue(try engine.pending(in: root).isEmpty)
        print("BATCH_RENAME_3000 synthetic tiny regular files elapsedMs=\((ProcessInfo.processInfo.systemUptime - started) * 1000)")
    }

    func testAppleDoubleMetadataIsNotTreatedAsARWPhoto() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        try Data([1]).write(to: root.appendingPathComponent("photo.ARW"))
        let sidecar = root.appendingPathComponent("._photo.ARW"), bytes = Data([0, 5, 22, 7])
        try bytes.write(to: sidecar)
        let plan = try makePlan(root)
        XCTAssertEqual(plan.rows.count, 1)
        let result = try execute(BatchRenameEngine(journalDirectory: journals), plan, TagStore(fileURL: metadata.appendingPathComponent("tags.json")))
        XCTAssertTrue(result.completed, result.message)
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
    }

    func testChangedVolumeRefusesBeforeAnyRename() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        let file = root.appendingPathComponent("photo.JPG"); try Data([4]).write(to: file)
        var plan = try makePlan(root); plan.volumeUUID = "different-volume-identifier"
        let result = try execute(BatchRenameEngine(journalDirectory: journals), plan, TagStore(fileURL: metadata.appendingPathComponent("tags.json")))
        XCTAssertFalse(result.completed); XCTAssertEqual(try Data(contentsOf: file), Data([4]))
    }

    func testSelectedOnlyOneAndMixedFilesLeaveUnselectedPhotosUnchanged() throws {
        for count in [1, 3] {
            let root = try folder(), journals = try folder(), metadata = try folder()
            let names = ["DSC0012.ARW", "DSC0035.ARW", "DSC0090.JPG", "unselected.ARW", "unselected.JPG"]
            for (index, name) in names.enumerated() { try Data([UInt8(index), 42]).write(to: root.appendingPathComponent(name)) }
            let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json")); tag(root.appendingPathComponent(names[0]), store: store)
            let targets = try entries(root).filter { names.prefix(count).contains($0.url.lastPathComponent) }
            let plan = try RenamePlan.make(folder: root, photos: targets, orderTitle: "파일 이름순 ↑", settings: RenameSettings(base: "Wedding", separator: "_", start: 1, digits: 3), existingNames: Set(names), selectedOnly: true)
            let result = try execute(BatchRenameEngine(journalDirectory: journals), plan, store)
            XCTAssertTrue(result.completed, result.message)
            for index in 0..<count {
                let ext = root.appendingPathComponent(names[index]).pathExtension
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(String(format: "Wedding_%03d.", index + 1) + ext)), Data([UInt8(index), 42]))
            }
            for index in count..<names.count { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(names[index])), Data([UInt8(index), 42])) }
            XCTAssertEqual(result.taggedPaths, [TagStore.key(root.appendingPathComponent("Wedding_001.ARW"))])
        }
    }

    func testSelectedOnlyConflictWithUnselectedCaseAndUnicodeNames() throws {
        let root = try folder()
        try Data([1]).write(to: root.appendingPathComponent("old.ARW"))
        try Data([2]).write(to: root.appendingPathComponent("WÉDDING_001.arw"))
        let photos = try entries(root).filter { $0.url.lastPathComponent == "old.ARW" }
        let plan = try RenamePlan.make(folder: root, photos: photos, orderTitle: "", settings: RenameSettings(base: "We\u{301}dding", separator: "_", start: 1, digits: 3), existingNames: Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), selectedOnly: true)
        XCTAssertFalse(plan.valid)
        XCTAssertTrue(plan.rows[0].issue?.contains("충돌") == true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("old.ARW")), Data([1]))
    }

    func testSelectedPreviewRejectsReplacedAndModifiedFilesBeforeAnyMove() throws {
        for replace in [false, true] {
            let root = try folder(), journals = try folder(), metadata = try folder()
            let original = root.appendingPathComponent("source.JPG")
            try Data([1]).write(to: original)
            let plan = try RenamePlan.make(folder: root, photos: entries(root), orderTitle: "", settings: RenameSettings(), existingNames: ["source.JPG"], selectedOnly: true)
            if replace { try FileManager.default.removeItem(at: original) }
            try Data([2, 3, 4]).write(to: original)
            var moved = false
            let engine = BatchRenameEngine(journalDirectory: journals, move: { _, _ in moved = true })
            let result = try execute(engine, plan, TagStore(fileURL: metadata.appendingPathComponent("tags.json")))
            XCTAssertFalse(result.completed); XCTAssertFalse(moved)
            XCTAssertEqual(try Data(contentsOf: original), Data([2, 3, 4]))
            XCTAssertTrue(result.message.contains("변경"))
        }
    }

    func testSelectedRenameRollbackRestoresTargetsTagsAndNeverTouchesUnselected() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        for (index, name) in ["a.ARW", "b.JPG", "unselected.ARW"].enumerated() { try Data([UInt8(index)]).write(to: root.appendingPathComponent(name)) }
        let store = TagStore(fileURL: metadata.appendingPathComponent("tags.json")); tag(root.appendingPathComponent("a.ARW"), store: store)
        let selected = try entries(root).filter { $0.url.lastPathComponent != "unselected.ARW" }
        let plan = try RenamePlan.make(folder: root, photos: selected, orderTitle: "", settings: RenameSettings(), existingNames: ["a.ARW", "b.JPG", "unselected.ARW"], selectedOnly: true)
        var injected = false
        let engine = BatchRenameEngine(journalDirectory: journals, move: { source, destination in
            if !injected && destination.lastPathComponent == "Photo_0002.JPG" { injected = true; throw CocoaError(.fileWriteNoPermission) }
            try BatchRenameEngine.exclusiveMove(source, destination)
        })
        let result = try execute(engine, plan, store)
        XCTAssertFalse(result.completed); XCTAssertTrue(result.restored, result.message)
        for (index, name) in ["a.ARW", "b.JPG", "unselected.ARW"].enumerated() { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data([UInt8(index)])) }
        XCTAssertEqual(result.taggedPaths, [TagStore.key(root.appendingPathComponent("a.ARW"))])
        XCTAssertTrue(try engine.pending(in: root).isEmpty)
    }

    func testSelectedRenameDetectsExternalChangeBetweenStagingMoves() throws {
        let root = try folder(), journals = try folder(), metadata = try folder()
        for name in ["a.JPG", "b.JPG"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
        let plan = try RenamePlan.make(folder: root, photos: entries(root), orderTitle: "", settings: RenameSettings(), existingNames: ["a.JPG", "b.JPG"], selectedOnly: true)
        var staged = false
        let engine = BatchRenameEngine(journalDirectory: journals, move: { source, destination in
            try BatchRenameEngine.exclusiveMove(source, destination)
            if !staged {
                staged = true
                try Data([7, 8, 9]).write(to: root.appendingPathComponent("b.JPG"))
            }
        })
        let result = try execute(engine, plan, TagStore(fileURL: metadata.appendingPathComponent("tags.json")))
        XCTAssertFalse(result.completed); XCTAssertTrue(result.restored, result.message)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a.JPG")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("b.JPG")), Data([7, 8, 9]))
        XCTAssertTrue(result.message.contains("상태가 변경"))
    }

}
