import XCTest
@testable import PhotoSelect

final class PhotoActionsTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDeletingSelectedMiddleLastAndOnlyPhotoChoosesNeighbor() {
        let photos = ["1.jpg", "2.arw", "3.jpg"].map { Photo(url: URL(fileURLWithPath: "/photos/" + $0)) }
        var list = PhotoList(); list.replace(with: photos); list.select(1)
        XCTAssertTrue(list.remove(photos[1].url))
        XCTAssertEqual(list.selectedPhoto, photos[2])
        XCTAssertTrue(list.remove(photos[2].url))
        XCTAssertEqual(list.selectedPhoto, photos[0])
        XCTAssertTrue(list.remove(photos[0].url))
        XCTAssertNil(list.selectedPhoto); XCTAssertNil(list.selectedIndex)
        XCTAssertFalse(list.remove(photos[0].url))
    }
    func testDeletingAnotherPhotoPreservesSelectionAndIndependentPair() {
        let photos = ["DSC.ARW", "DSC.JPG", "next.jpg"].map { Photo(url: URL(fileURLWithPath: "/photos/" + $0)) }
        var list = PhotoList(); list.replace(with: photos); list.select(2)
        list.remove(photos[0].url)
        XCTAssertEqual(list.selectedPhoto, photos[2]); XCTAssertEqual(list.selectedIndex, 1)
        XCTAssertTrue(list.photos.contains(photos[1]))
        XCTAssertFalse(list.select(99)); XCTAssertEqual(list.selectedPhoto, photos[2])
    }
    func testTagSurvivesReloadAndDoesNotChangeRawOrJpeg() throws {
        let root = try folder()
        let raw = root.appendingPathComponent("DSC.ARW"), jpg = root.appendingPathComponent("DSC.JPG")
        let bytes = Data("source photo bytes".utf8)
        try bytes.write(to: raw); try bytes.write(to: jpg)
        let file = root.appendingPathComponent("metadata/tags.json")
        let store = TagStore(fileURL: file)
        let saved = expectation(description: "tag saved")
        store.toggle(raw) { result in
            XCTAssertEqual(try? result.get(), true); saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        let reloaded = expectation(description: "tag reloaded")
        TagStore(fileURL: file).load { result in
            XCTAssertEqual(try? result.get(), Set([TagStore.key(raw)])); reloaded.fulfill()
        }
        wait(for: [reloaded], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: raw), bytes); XCTAssertEqual(try Data(contentsOf: jpg), bytes)
    }
    func testRapidTagTogglesSerializeAndEndUntagged() throws {
        let file = try folder().appendingPathComponent("tags.json")
        let store = TagStore(fileURL: file)
        let url = URL(fileURLWithPath: "/photos/1.jpg")
        let saved = expectation(description: "two toggles"); saved.expectedFulfillmentCount = 2
        var states: [Bool] = []
        for _ in 0..<2 {
            store.toggle(url) { result in
                if let state = try? result.get() { states.append(state) } else { XCTFail("Tag save failed") }
                saved.fulfill()
            }
        }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(states, [true, false])
        let loaded = expectation(description: "empty after reload")
        TagStore(fileURL: file).load { result in XCTAssertEqual(try? result.get(), []); loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
    }
    func testCorruptTagMetadataIsPreserved() throws {
        let file = try folder().appendingPathComponent("tags.json")
        let bytes = Data("invalid existing metadata".utf8); try bytes.write(to: file)
        let done = expectation(description: "corrupt tag metadata rejected")
        TagStore(fileURL: file).toggle(URL(fileURLWithPath: "/photos/1.jpg")) { result in
            if case .success = result { XCTFail("Must preserve corrupt metadata") }; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testTagWriteFailureIsReported() throws {
        let root = try folder(); let blocker = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocker)
        let done = expectation(description: "write failure")
        TagStore(fileURL: blocker.appendingPathComponent("tags.json")).toggle(URL(fileURLWithPath: "/1.jpg")) { result in
            if case .success = result { XCTFail("Must report metadata failure") }; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: blocker), Data("keep".utf8))
    }
    func testTrashMovesOnlyRequestedFileAndKeepsPair() throws {
        let root = try folder(), trash = try folder()
        let raw = root.appendingPathComponent("DSC.ARW"), jpg = root.appendingPathComponent("DSC.JPG")
        try Data("raw".utf8).write(to: raw); try Data("jpg".utf8).write(to: jpg)
        let service = PhotoTrash { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent)) }
        let done = expectation(description: "moved")
        service.trash(Photo(url: raw), lease: FolderLease(root)) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("DSC.ARW")), Data("raw".utf8))
        XCTAssertEqual(try Data(contentsOf: jpg), Data("jpg".utf8))
    }
    func testTrashFailureKeepsSourceAndHasNoDeleteFallback() throws {
        let root = try folder(), photo = root.appendingPathComponent("keep.jpg")
        let bytes = Data("keep photo".utf8); try bytes.write(to: photo)
        let service = PhotoTrash { _ in throw CocoaError(.fileWriteNoPermission) }
        let done = expectation(description: "trash denied")
        service.trash(Photo(url: photo), lease: FolderLease(root)) { result in
            if case .success = result { XCTFail("Must report failed trash operation") }; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: photo), bytes)
    }
}
