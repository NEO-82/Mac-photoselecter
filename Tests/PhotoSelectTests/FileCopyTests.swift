import AppKit
import CryptoKit
import Darwin
import XCTest
@testable import PhotoSelect

final class FileCopyTests: XCTestCase {
    private let folderAttribute = "dev.photoselect.folder-copy-test"

    private func folders() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let target = ProcessInfo.processInfo.environment["PHOTOSELECT_COPY_TEST_VOLUME"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("J-S-copy-test-" + UUID().uuidString)
        } ?? root.appendingPathComponent("target")
        for url in [source, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        if !target.path.hasPrefix(root.path + "/") { addTeardownBlock { try? FileManager.default.removeItem(at: target) } }
        return (source, target)
    }
    private func file(_ parent: URL, _ name: String, data: Data = Data("original bytes".utf8)) throws -> URL {
        let url = parent.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func unsupportedPublisher() -> FileCopyEngine {
        FileCopyEngine(publish: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)) })
    }
    private func usesExFAT(_ volume: URL) throws -> Bool {
        var filesystem = statfs()
        guard statfs(volume.path, &filesystem) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let format = withUnsafeBytes(of: &filesystem.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return format.lowercased() == "exfat"
    }
    private func setFolderMetadata(_ marker: Data, on folder: URL) throws {
        let result = marker.withUnsafeBytes {
            setxattr(folder.path, folderAttribute, $0.baseAddress, $0.count, 0, 0)
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func folderMetadata(_ folder: URL) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        let size = getxattr(folder.path, folderAttribute, &bytes, bytes.count, 0, 0)
        guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Data(bytes.prefix(size))
    }
    func testSingleRawPreservesSourceAndVerifiesCopyBytesAndDate() throws {
        let (source, target) = try folders()
        let data = Data((0..<3000000).map { UInt8($0 % 251) })
        let raw = try file(source, "DSC.ARW", data: data)
        let date = Date(timeIntervalSince1970: 1600000000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: raw.path)
        let report = FileCopyEngine().run([raw], to: target)
        XCTAssertEqual(report.failures.count, 0); XCTAssertEqual(report.copied.count, 1)
        XCTAssertEqual(try Data(contentsOf: raw), data)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("DSC.ARW")), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: report.copied[0].path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 2)
    }
    func testMixedRawJpegAndDocumentRemainSeparateFiles() throws {
        let (source, target) = try folders()
        let urls = try ["DSC.ARW", "DSC.JPG", "notes.txt"].map { try file(source, $0) }
        let report = FileCopyEngine().run(urls, to: target)
        XCTAssertEqual(report.copied.count, 3); XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        for url in urls { XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: target.appendingPathComponent(url.lastPathComponent))) }
    }
    func testExtendedAttributesAndResourceForkPreserved() throws {
        let (source, target) = try folders(), raw = try file(source, "metadata.ARW")
        let copied = target.appendingPathComponent("metadata.ARW")
        let isExFAT = try usesExFAT(target)
        let marker = Data("metadata bytes".utf8)
        var attributes = ["dev.photoselect.copy-test": marker, "com.apple.ResourceFork": marker]
        if isExFAT {
            attributes["com.apple.quarantine"] = Data("0081;5f5e1000;PhotoSelect;".utf8)
        }
        for (name, marker) in attributes {
            let result = marker.withUnsafeBytes { setxattr(raw.path, name, $0.baseAddress, $0.count, 0, 0) }
            XCTAssertEqual(result, 0)
        }
        var competingCreateError: Int32?
        let engine: FileCopyEngine
        if isExFAT {
            let sidecar = target.appendingPathComponent("._metadata.ARW")
            engine = FileCopyEngine(publish: { _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
            }, write: { descriptor, buffer, count in
                if competingCreateError == nil, access(copied.path, F_OK) == 0 {
                    // Model another service creating a sidecar as soon as the photo is visible.
                    let competing = open(sidecar.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    competingCreateError = competing < 0 ? errno : 0
                    if competing >= 0 { close(competing) }
                }
                return Darwin.write(descriptor, buffer, count)
            })
        } else {
            engine = FileCopyEngine()
        }
        let report = engine.run([raw], to: target)
        XCTAssertEqual(report.copied, [copied])
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        if isExFAT {
            XCTAssertEqual(competingCreateError, EEXIST, "The AppleDouble name must be reserved before writing the photo.")
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.path).contains {
            $0.hasPrefix(".photoselect-copy-")
        })
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: raw)), SHA256.hash(data: try Data(contentsOf: copied)))
        for url in [raw, copied] {
            for (name, marker) in attributes {
                var bytes = [UInt8](repeating: 0, count: 128)
                let count = getxattr(url.path, name, &bytes, bytes.count, 0, 0)
                guard count >= 0 else { XCTFail("Missing \(name) on \(url.path)"); continue }
                let value = Data(bytes.prefix(count))
                if name == "com.apple.quarantine", value != marker {
                    XCTAssertEqual(value, Data("q/".utf8) + marker + Data([0]))
                } else {
                    XCTAssertEqual(value, marker)
                }
            }
        }
    }
    func testRealSonySamplesCopyInBothDirectionsWithoutContentChanges() throws {
        guard let samples = ProcessInfo.processInfo.environment["PHOTOSELECT_ARW_SAMPLE_DIRECTORY"] else {
            throw XCTSkip("실제 Sony ARW fixture 경로가 지정되지 않았습니다.")
        }
        func digest(_ url: URL) throws -> Data {
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            var hash = SHA256()
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            return Data(hash.finalize())
        }
        let (internalFolder, volume) = try folders()
        let urls = ["Sony-A7M3.arw", "Sony-A7M4.ARW"].map { URL(fileURLWithPath: samples).appendingPathComponent($0) }
        let before = try urls.map(digest)
        let outbound = FileCopyEngine().run(urls, to: volume)
        XCTAssertEqual(outbound.copied.count, 2); XCTAssertTrue(outbound.failures.isEmpty)
        let copied = urls.map { volume.appendingPathComponent($0.lastPathComponent) }
        XCTAssertEqual(try copied.map(digest), before)
        let inbound = FileCopyEngine().run(copied, to: internalFolder)
        XCTAssertEqual(inbound.copied.count, 2); XCTAssertTrue(inbound.failures.isEmpty)
        XCTAssertEqual(try urls.map(digest), before)
        XCTAssertEqual(try urls.map { try digest(internalFolder.appendingPathComponent($0.lastPathComponent)) }, before)
    }
    func testNestedFolderAndPackageContentsCopied() throws {
        let (source, target) = try folders()
        let package = source.appendingPathComponent("Album.bundle")
        let nested = package.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try file(nested, "image.JPG")
        let report = FileCopyEngine().run([package], to: target)
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n")); XCTAssertEqual(report.copied.count, 1)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("image.JPG")),
                       try Data(contentsOf: target.appendingPathComponent("Album.bundle/a/b/image.JPG")))
    }
    func testEmptyPhotoAndNestedFoldersPreserveMetadataAndContent() throws {
        let (source, target) = try folders()
        let empty = source.appendingPathComponent("빈 폴더")
        let album = source.appendingPathComponent("무제 폴더")
        let collection = source.appendingPathComponent("앨범 모음")
        let nested = collection.appendingPathComponent("중첩 폴더")
        let sourceFolders = [empty, album, collection, nested]
        for folder in sourceFolders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try setFolderMetadata(Data(folder.lastPathComponent.utf8), on: folder)
        }
        let raw = try file(album, "image.ARW", data: Data(repeating: 41, count: 2 * 1024 * 1024))
        let jpg = try file(album, "image.JPG")
        let nestedPhoto = try file(nested, "nested.ARW")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        for folder in sourceFolders {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
        }
        let expectedDigests = try [raw, jpg, nestedPhoto].map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let report = FileCopyEngine().run([empty, album, collection], to: target)

        let copiedEmpty = target.appendingPathComponent(empty.lastPathComponent)
        let copiedAlbum = target.appendingPathComponent(album.lastPathComponent)
        let copiedCollection = target.appendingPathComponent(collection.lastPathComponent)
        let copiedNested = copiedCollection.appendingPathComponent(nested.lastPathComponent)
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(report.copied.map(\.path), [copiedEmpty.path, copiedAlbum.path, copiedCollection.path])
        for (original, copy) in zip(sourceFolders, [copiedEmpty, copiedAlbum, copiedCollection, copiedNested]) {
            let marker = Data(original.lastPathComponent.utf8)
            XCTAssertEqual(try folderMetadata(original), marker)
            XCTAssertEqual(try folderMetadata(copy), marker)
            for folder in [original, copy] {
                let info = try FileManager.default.attributesOfItem(atPath: folder.path)
                let modificationDate = try XCTUnwrap(info[.modificationDate] as? Date)
                XCTAssertEqual(modificationDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 2)
            }
        }
        let photos = [(raw, copiedAlbum), (jpg, copiedAlbum), (nestedPhoto, copiedNested)]
        for ((original, parent), expected) in zip(photos, expectedDigests) {
            let copy = parent.appendingPathComponent(original.lastPathComponent)
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: original)), expected)
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: copy)), expected)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: copiedEmpty.path).isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.path).contains {
            $0.hasPrefix(".photoselect-copy-")
        })
    }
    func testFolderAppleDoubleReservedDuringChildCopy() throws {
        let (source, target) = try folders()
        let album = source.appendingPathComponent("무제 폴더")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: false)
        let marker = Data("album metadata".utf8)
        try setFolderMetadata(marker, on: album)
        let raw = try file(album, "image.ARW")
        let isExFAT = try usesExFAT(target)

        var competingCreateError: Int32?
        let engine = FileCopyEngine(write: { descriptor, buffer, count in
            if isExFAT, competingCreateError == nil,
               let names = try? FileManager.default.contentsOfDirectory(atPath: target.path),
               let scratch = names.first(where: { $0.hasPrefix(".photoselect-copy-") }) {
                let stage = target.appendingPathComponent(scratch)
                let stagedAlbum = stage.appendingPathComponent(album.lastPathComponent)
                let stagedPhoto = stagedAlbum.appendingPathComponent(raw.lastPathComponent)
                if access(stagedPhoto.path, F_OK) == 0 {
                    // A metadata service sees the temporary folder while a child is being written.
                    let sidecar = stage.appendingPathComponent("._" + album.lastPathComponent)
                    let competing = open(sidecar.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    competingCreateError = competing < 0 ? errno : 0
                    if competing >= 0 { close(competing) }
                }
            }
            return Darwin.write(descriptor, buffer, count)
        })
        let report = engine.run([album], to: target)
        let copiedAlbum = target.appendingPathComponent(album.lastPathComponent)
        let copiedPhoto = copiedAlbum.appendingPathComponent(raw.lastPathComponent)

        if isExFAT {
            XCTAssertEqual(competingCreateError, EEXIST, "The directory's AppleDouble must be reserved before copying its children.")
        }
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(report.copied.map(\.path), [copiedAlbum.path])
        XCTAssertEqual(try folderMetadata(album), marker)
        XCTAssertEqual(try folderMetadata(copiedAlbum), marker)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: raw)),
                       SHA256.hash(data: try Data(contentsOf: copiedPhoto)))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.path).contains {
            $0.hasPrefix(".photoselect-copy-")
        })
    }
    func testFolderCopySkipsFinderHousekeepingButExplicitFileCopyPreservesIt() throws {
        let (source, target) = try folders()
        let album = source.appendingPathComponent("Album")
        let nested = album.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let store = try file(nested, ".DS_Store", data: Data("Finder view settings".utf8))
        let companion = try file(nested, "._.DS_Store", data: Data("Finder companion".utf8))
        let photos = try ["image.ARW", "image.JPG"].map { try file(nested, $0) }

        var lastProgress: FileCopyProgress?
        let albumReport = FileCopyEngine().run([album], to: target) { lastProgress = $0 }
        let copiedAlbum = target.appendingPathComponent("Album")
        let copiedNested = copiedAlbum.appendingPathComponent("nested")
        XCTAssertTrue(albumReport.failures.isEmpty, albumReport.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(albumReport.copied.map(\.path), [copiedAlbum.path])
        XCTAssertEqual(lastProgress?.total, 4)
        XCTAssertEqual(lastProgress?.completed, 4)
        for photo in photos {
            let copy = copiedNested.appendingPathComponent(photo.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: photo))
        }
        for file in [store, companion] {
            var info = stat()
            let result = lstat(copiedNested.appendingPathComponent(file.lastPathComponent).path, &info)
            let error = errno
            XCTAssertEqual(result, -1)
            XCTAssertEqual(error, ENOENT)
            XCTAssertEqual(lstat(file.path, &info), 0)
        }

        let explicit = try file(source, ".DS_Store", data: Data("explicit selection".utf8))
        let explicitReport = FileCopyEngine().run([explicit], to: target)
        let copiedStore = target.appendingPathComponent(".DS_Store")
        XCTAssertTrue(explicitReport.failures.isEmpty, explicitReport.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(explicitReport.copied, [copiedStore])
        XCTAssertEqual(try Data(contentsOf: copiedStore), try Data(contentsOf: explicit))
    }
    func testExistingFileNeverOverwritten() throws {
        let (source, target) = try folders(), original = Data("existing".utf8)
        let raw = try file(source, "DSC.ARW")
        let existing = try file(target, "DSC.ARW", data: original)
        let report = FileCopyEngine().run([raw], to: target)
        XCTAssertTrue(report.copied.isEmpty); XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertTrue(report.createdTargets.isEmpty)
    }
    func testExistingFolderIsNeverMerged() throws {
        let (source, target) = try folders()
        let a = source.appendingPathComponent("folder"), b = target.appendingPathComponent("folder")
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        _ = try file(a, "new.txt"); let old = try file(b, "old.txt")
        let report = FileCopyEngine().run([a], to: target)
        XCTAssertEqual(report.failures.count, 1); XCTAssertTrue(report.copied.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.appendingPathComponent("new.txt").path))
    }
    func testCaseAndUnicodeEquivalentNamesAreConservativelyRejected() throws {
        XCTAssertEqual(FileCopyEngine.nameKey("É.ARW"), FileCopyEngine.nameKey("e\u{301}.arw"))
        let (source, target) = try folders()
        let raw = try file(source, "DSC.ARW"); _ = try file(target, "dsc.arw")
        XCTAssertEqual(FileCopyEngine().run([raw], to: target).failures.count, 1)
    }
    func testAppleDoubleDestinationCompanionIsNotOverwritten() throws {
        let (source, target) = try folders()
        let raw = try file(source, "DSC.ARW"), sidecar = try file(target, "._DSC.ARW")
        let bytes = try Data(contentsOf: sidecar)
        XCTAssertEqual(FileCopyEngine().run([raw], to: target).failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        let album = source.appendingPathComponent("무제 폴더")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: false)
        try setFolderMetadata(Data("original folder metadata".utf8), on: album)
        let folderSidecar = try file(target, "._" + album.lastPathComponent, data: bytes)
        let report = FileCopyEngine().run([album], to: target)
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertTrue(report.createdTargets.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertNil(report.failures.first?.retainedTemporaryURL)
        XCTAssertEqual(try Data(contentsOf: folderSidecar), bytes)
    }
    func testSameParentAndOwnDescendantAreRejected() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let child = source.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertEqual(FileCopyEngine().run([raw], to: source).failures.count, 1)
        XCTAssertEqual(FileCopyEngine().run([source], to: child).failures.count, 1)
        XCTAssertEqual(FileCopyEngine().run([URL(fileURLWithPath: "/")], to: target).failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
    }
    func testSymlinkAndCycleDoNotTraverse() throws {
        let (source, target) = try folders()
        let link = source.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let report = FileCopyEngine().run([link], to: target)
        XCTAssertEqual(report.failures.count, 1); XCTAssertTrue(report.copied.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("cycle").path))
    }
    func testNonDirectoryAndMissingDestinationFailWithoutChangingSource() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let wrong = try file(target, "document")
        XCTAssertEqual(FileCopyEngine().run([raw], to: wrong).failures.count, 1)
        XCTAssertEqual(FileCopyEngine().run([raw], to: target.appendingPathComponent("missing")).failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: raw), Data("original bytes".utf8))
    }
    func testCancellationBeforeStartCreatesNothing() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let cancel = FileCopyCancellation(); cancel.cancel()
        let report = FileCopyEngine().run([raw], to: target, cancellation: cancel)
        XCTAssertTrue(report.cancelled); XCTAssertTrue(report.copied.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    func testInjectedDiskFullDuringWriteDoesNotPublishOrChangeSource() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let engine = FileCopyEngine(write: { _, _, _ in errno = ENOSPC; return -1 })
        let report = engine.run([raw], to: target)
        XCTAssertEqual(report.failures.count, 1); XCTAssertTrue(report.copied.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("DSC.ARW").path))
        XCTAssertEqual(try Data(contentsOf: raw), Data("original bytes".utf8))
        XCTAssertNil(report.failures[0].retainedTemporaryURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    func testInjectedReadErrorDoesNotPublishOrChangeSource() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let engine = FileCopyEngine(read: { _, _, _ in errno = EIO; return -1 })
        let report = engine.run([raw], to: target)
        XCTAssertEqual(report.failures.count, 1); XCTAssertTrue(report.copied.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("DSC.ARW").path))
        XCTAssertEqual(try Data(contentsOf: raw), Data("original bytes".utf8))
    }
    func testFallbackFolderFailureReportsVerifiedPartialFilesAndFailingChild() throws {
        let (source, target) = try folders(), album = source.appendingPathComponent("album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let files = try ["a.txt", "b.txt"].map { try file(album, $0) }
        var writes = 0
        let engine = FileCopyEngine(publish: { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        }, write: { descriptor, buffer, count in
            writes += 1
            if writes == 4 { errno = ENOSPC; return -1 }
            return Darwin.write(descriptor, buffer, count)
        })
        let report = engine.run([album], to: target)
        XCTAssertTrue(report.copied.isEmpty); XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.verifiedPartialItems.count, 1)
        XCTAssertTrue(report.failures[0].message.contains("실패한 항목:"))
        if let verified = report.verifiedPartialItems.first { XCTAssertEqual(try Data(contentsOf: verified), Data("original bytes".utf8)) }
        for url in files { XCTAssertEqual(try Data(contentsOf: url), Data("original bytes".utf8)) }
    }
    func testCancellationWithinStreamingWriteNeverPublishesPartialFile() throws {
        let (source, target) = try folders(), bytes = Data(repeating: 73, count: 3 * 1024 * 1024)
        let raw = try file(source, "DSC.ARW", data: bytes), cancellation = FileCopyCancellation()
        let engine = FileCopyEngine(write: { descriptor, buffer, count in
            let written = Darwin.write(descriptor, buffer, count); cancellation.cancel(); return written
        })
        let report = engine.run([raw], to: target, cancellation: cancellation)
        XCTAssertTrue(report.cancelled); XCTAssertEqual(report.failures.count, 1); XCTAssertTrue(report.copied.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("DSC.ARW").path))
        XCTAssertEqual(try Data(contentsOf: raw), bytes)
        XCTAssertNil(report.failures[0].retainedTemporaryURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    func testCancellationAfterFirstItemReportsRemainingSources() throws {
        let (source, target) = try folders()
        let urls = try ["a.ARW", "b.JPG", "c.txt"].map { try file(source, $0) }
        let cancellation = FileCopyCancellation()
        let report = FileCopyEngine().run(urls, to: target, cancellation: cancellation) { value in
            if value.completed == 1 { cancellation.cancel() }
        }
        XCTAssertTrue(report.cancelled); XCTAssertEqual(report.copied.count, 1)
        XCTAssertEqual(report.unprocessed, Array(urls.dropFirst()))
        for url in urls { XCTAssertEqual(try Data(contentsOf: url), Data("original bytes".utf8)) }
    }
    func testReverseDirectionFromTargetVolumeToInternalFolder() throws {
        let (internalFolder, otherVolume) = try folders()
        let raw = try file(otherVolume, "reverse.ARW")
        let report = FileCopyEngine().run([raw], to: internalFolder)
        XCTAssertEqual(report.copied.count, 1); XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(try Data(contentsOf: raw), try Data(contentsOf: internalFolder.appendingPathComponent("reverse.ARW")))
    }
    func testNestedProgressCountsFilesAndFolders() throws {
        let (source, target) = try folders()
        let child = source.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        _ = try file(child, "a.ARW"); _ = try file(child, "b.JPG")
        var last: FileCopyProgress?
        let report = FileCopyEngine().run([child], to: target) { last = $0 }
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(last?.total, 3); XCTAssertEqual(last?.completed, 3)
        XCTAssertEqual(last?.bytes, Int64(2 * Data("original bytes".utf8).count))
    }
    func testRacingExactNameCreationCannotBeOverwrittenAtPublication() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let bytes = Data("concurrent writer".utf8)
        let engine = FileCopyEngine(publish: { staged, final in
            try bytes.write(to: final, options: .withoutOverwriting)
            guard renamex_np(staged.path, final.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        })
        let report = engine.run([raw], to: target)
        XCTAssertEqual(report.failures.count, 1); XCTAssertTrue(report.copied.isEmpty)
        XCTAssertTrue(report.createdTargets.isEmpty)
        XCTAssertTrue(report.failures.first?.message.contains("renamex_np(RENAME_EXCL)") == true)
        XCTAssertTrue(report.failures.first?.message.contains("NSPOSIXErrorDomain \(EEXIST)") == true)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("DSC.ARW")), bytes)
        XCTAssertEqual(try Data(contentsOf: raw), Data("original bytes".utf8))
    }
    func testUnsupportedExclusiveRenameUsesExclusiveVerifiedCopyFallback() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let report = unsupportedPublisher().run([raw], to: target)
        XCTAssertEqual(report.copied.count, 1); XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(try Data(contentsOf: raw), try Data(contentsOf: target.appendingPathComponent("DSC.ARW")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["DSC.ARW"])
    }
    func testFallbackRacingExistingFileFailsExclusively() throws {
        for name in ["DSC.ARW", "._DSC.ARW"] {
            let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
            let bytes = Data("concurrent writer".utf8)
            let collision = target.appendingPathComponent(name)
            let engine = FileCopyEngine(publish: { _, _ in
                try bytes.write(to: collision, options: .withoutOverwriting)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
            })
            let report = engine.run([raw], to: target)
            XCTAssertTrue(report.copied.isEmpty); XCTAssertEqual(report.failures.count, 1)
            XCTAssertTrue(report.createdTargets.isEmpty)
            XCTAssertEqual(try Data(contentsOf: collision), bytes)
            if name.hasPrefix("._") {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("DSC.ARW").path))
            }
        }
    }
    func testMissingSourceDoesNotPreventLaterSuccessfulCopies() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let report = FileCopyEngine().run([source.appendingPathComponent("missing"), raw], to: target)
        XCTAssertEqual(report.copied.count, 1); XCTAssertEqual(report.failures.count, 1)
    }
    func testBatchesOfFourteenOneHundredAndOneThousandFiles() throws {
        for count in [14, 100, 1000] {
            let (source, target) = try folders()
            let urls = try (0..<count).map { try file(source, "\($0).JPG") }
            let start = ProcessInfo.processInfo.systemUptime
            let report = FileCopyEngine().run(urls, to: target)
            XCTAssertEqual(report.copied.count, count); XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
            for url in urls { XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: target.appendingPathComponent(url.lastPathComponent))) }
            print("COPY_COUNT=\(count) ELAPSED_SECONDS=\(ProcessInfo.processInfo.systemUptime - start) synthetic small files, not RAW throughput")
        }
    }
    @MainActor func testStandardFileURLClipboardRoundTrip() throws {
        let (source, _) = try folders(), raw = try file(source, "DSC.ARW"), text = try file(source, "notes.txt")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(FileClipboard.write([raw, text], to: board))
        XCTAssertTrue(FileClipboard.containsFiles(board))
        XCTAssertEqual(FileClipboard.read(board), [raw, text])
        XCTAssertTrue(FileClipboard.read(NSPasteboard.withUniqueName()).isEmpty)
        // Actual Finder paste and modifier-key drag behavior still requires GUI validation.
    }
    @MainActor func testCopyDoesNotTransferAppTagsOrChangeSourceTagDocument() throws {
        let (source, target) = try folders(), raw = try file(source, "DSC.ARW")
        let tagFile = source.deletingLastPathComponent().appendingPathComponent("tags.json")
        let store = TagStore(fileURL: tagFile), done = expectation(description: "tagged")
        store.toggle(raw) { _ in done.fulfill() }; wait(for: [done], timeout: 5)
        let before = try Data(contentsOf: tagFile)
        XCTAssertEqual(FileCopyEngine().run([raw], to: target).copied.count, 1)
        XCTAssertEqual(try Data(contentsOf: tagFile), before)
        let loaded = expectation(description: "tags unchanged")
        store.load { result in
            XCTAssertEqual(try? result.get(), [TagStore.key(raw)])
            XCTAssertFalse((try? result.get().contains(TagStore.key(target.appendingPathComponent("DSC.ARW")))) ?? true)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }
    @MainActor func testStaleDestinationTagsClearedWithoutChangingSourceOrSiblingTags() throws {
        let (source, target) = try folders()
        let raw = try file(source, "DSC.ARW")
        let copiedFolder = target.appendingPathComponent("copied-folder")
        let stale = copiedFolder.appendingPathComponent("DSC.ARW")
        let sibling = target.appendingPathComponent("copied-folder-other/keep.JPG")
        let store = TagStore(fileURL: source.deletingLastPathComponent().appendingPathComponent("tags.json"))
        let tagged = expectation(description: "prepare tags"); tagged.expectedFulfillmentCount = 3
        for url in [raw, stale, sibling] { store.toggle(url) { _ in tagged.fulfill() } }
        wait(for: [tagged], timeout: 5)
        let cleared = expectation(description: "clear stale destination subtree")
        store.clearTagsForCopiedRoots([copiedFolder]) { result in
            XCTAssertEqual(try? result.get(), Set([TagStore.key(raw), TagStore.key(sibling)])); cleared.fulfill()
        }
        wait(for: [cleared], timeout: 5)
        let reloaded = expectation(description: "persisted without original tag loss")
        TagStore(fileURL: source.deletingLastPathComponent().appendingPathComponent("tags.json")).load { result in
            XCTAssertEqual(try? result.get(), Set([TagStore.key(raw), TagStore.key(sibling)])); reloaded.fulfill()
        }
        wait(for: [reloaded], timeout: 5)
    }
}
