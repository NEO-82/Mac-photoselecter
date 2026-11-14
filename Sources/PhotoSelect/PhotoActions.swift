import Foundation

// Serialized, atomic metadata writes. Photo files are never opened for writing.
final class TagStore {
    private struct Document: Codable {
        let version: Int
        let taggedPaths: [String]
    }
    private let fileURL: URL
    private let writeData: (Data, URL) throws -> Void
    private let queue = DispatchQueue(label: "dev.photoselect.tags", qos: .utility)
    private var paths: Set<String> = []
    private var loaded = false
    private var loadError: Error?

    init(fileURL: URL? = nil, writeData: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }) {
        self.writeData = writeData
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = fileURL ?? support.appendingPathComponent("dev.photoselect.app/tags.json")
    }
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
    private func ensureLoaded() throws {
        if let loadError { throw loadError }
        guard !loaded else { return }
        do {
            let data: Data
            do { data = try Data(contentsOf: fileURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                loaded = true; return
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw NSError(domain: "PhotoSelect.Tags", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "지원하지 않는 태그 저장 형식입니다. 기존 파일을 보존합니다."])
            }
            paths = Set(document.taggedPaths)
            loaded = true
        } catch {
            loadError = error
            throw error
        }
    }
    func load(completion: @escaping (Result<Set<String>, Error>) -> Void) {
        queue.async {
            let result = Result { try self.ensureLoaded(); return self.paths }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func toggle(_ url: URL, completion: @escaping (Result<Bool, Error>) -> Void) {
        queue.async {
            let result = Result { () -> Bool in
                try self.ensureLoaded()
                let key = Self.key(url)
                var updated = self.paths
                let tagged: Bool
                if updated.remove(key) != nil { tagged = false }
                else { updated.insert(key); tagged = true }
                let data = try JSONEncoder().encode(Document(version: 1, taggedPaths: updated.sorted()))
                try FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try self.writeData(data, self.fileURL)
                self.paths = updated
                return tagged
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    // Rename commits use one atomic set update so swaps/cycles are safe and replay is idempotent.
    func updatePaths(removing: Set<String>, adding: Set<String>, force: Bool = false, completion: @escaping (Result<Set<String>, Error>) -> Void) {
        queue.async {
            let result = Result { () -> Set<String> in
                try self.ensureLoaded()
                let updated = self.paths.subtracting(removing).union(adding)
                if force || updated != self.paths {
                    let data = try JSONEncoder().encode(Document(version: 1, taggedPaths: updated.sorted()))
                    try FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try self.writeData(data, self.fileURL)
                    self.paths = updated
                }
                return self.paths
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    // Complete after already queued writes and their main-queue callbacks.
    // The caller stops accepting new tags before requesting normal app exit.
    func finishPendingWrites(completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }
}

struct TrashReceipt {
    let originalURL: URL
    let trashURL: URL?
    let volumeName: String?
    let isExternalVolume: Bool

    var storageNotice: String? {
        guard isExternalVolume else { return nil }
        let name = volumeName.map { "‘\($0)’ " } ?? "외장 "
        return name + "저장장치의 휴지통으로 이동했습니다. 복원하려면 장치를 연결해 두세요. 휴지통을 비우기 전까지 저장 공간을 차지할 수 있습니다."
    }
}

struct PhotoTrashFailure: LocalizedError {
    let sourceURL: URL
    let underlyingError: Error

    var errorDescription: String? {
        let error = underlyingError as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case CocoaError.Code.fileWriteVolumeReadOnly.rawValue:
                return "읽기 전용 저장장치에서는 휴지통으로 이동할 수 없습니다."
            case CocoaError.Code.fileWriteNoPermission.rawValue, CocoaError.Code.fileReadNoPermission.rawValue:
                return "파일 또는 저장장치의 쓰기 권한이 없어 휴지통으로 이동하지 못했습니다."
            case CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue:
                return "파일을 찾을 수 없습니다. 저장장치가 분리되었거나 파일 위치가 변경되었을 수 있습니다."
            case CocoaError.Code.featureUnsupported.rawValue:
                return "이 저장장치는 macOS 휴지통 이동을 지원하지 않습니다."
            default: break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch error.code {
            case Int(POSIXErrorCode.EROFS.rawValue):
                return "읽기 전용 저장장치에서는 휴지통으로 이동할 수 없습니다."
            case Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue):
                return "파일 또는 저장장치의 쓰기 권한이 없어 휴지통으로 이동하지 못했습니다."
            case Int(POSIXErrorCode.ENOENT.rawValue), Int(POSIXErrorCode.ENODEV.rawValue), Int(POSIXErrorCode.ENXIO.rawValue):
                return "파일 또는 저장장치를 찾을 수 없습니다. 연결 상태를 확인해 주세요."
            case Int(POSIXErrorCode.ENOTSUP.rawValue):
                return "이 저장장치는 macOS 휴지통 이동을 지원하지 않습니다."
            default: break
            }
        }
        return "휴지통으로 이동하지 못했습니다: " + error.localizedDescription
    }
    var failureReason: String? { underlyingError.localizedDescription }
    var recoverySuggestion: String? {
        "파일을 영구 삭제하지 않았습니다. 저장장치 연결, 쓰기 권한과 휴지통 지원 여부를 확인한 뒤 다시 시도해 주세요."
    }
    var message: String {
        (errorDescription ?? "휴지통 이동 실패") + "\n" + (recoverySuggestion ?? "")
    }
}

final class PhotoTrash {
    private let queue = DispatchQueue(label: "dev.photoselect.trash", qos: .userInitiated)
    private let move: (URL) throws -> URL?

    // Existing injected movers remain useful for deterministic tests. Production
    // always uses the OS Trash API and records its resulting location.
    init(move: ((URL) throws -> Void)? = nil) {
        if let move { self.move = { try move($0); return nil } }
        else {
            self.move = { url in
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                return resultingURL.map { $0 as URL }
            }
        }
    }
    private init(operation: @escaping (URL) throws -> URL?) { self.move = operation }
    static func recordingMove(_ move: @escaping (URL) throws -> URL?) -> PhotoTrash { PhotoTrash(operation: move) }

    private func perform(_ photo: Photo) -> Result<TrashReceipt, Error> {
        Result {
            do {
                let volume = try? photo.url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsInternalKey,
                    .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey])
                if volume?.volumeIsReadOnly == true { throw CocoaError(.fileWriteVolumeReadOnly) }
                let destination = try move(photo.url)
                return TrashReceipt(originalURL: photo.url, trashURL: destination, volumeName: volume?.volumeName,
                    isExternalVolume: volume?.volumeIsInternal == false || volume?.volumeIsRemovable == true || volume?.volumeIsEjectable == true)
            } catch { throw PhotoTrashFailure(sourceURL: photo.url, underlyingError: error) }
        }
    }
    func trash(_ photo: Photo, lease: FolderLease, completion: @escaping (Result<TrashReceipt, Error>) -> Void) {
        queue.async {
            let result = withExtendedLifetime(lease) { self.perform(photo) }
            // Always use OS Trash; no permanent-delete fallback.
            DispatchQueue.main.async { completion(result) }
        }
    }
    func trashSelection(_ entries: [BrowserEntry], lease: FolderLease,
                        completion: @escaping ([(URL, Result<TrashReceipt, Error>)]) -> Void) {
        queue.async {
            let results = withExtendedLifetime(lease) {
                entries.map { entry -> (URL, Result<TrashReceipt, Error>) in
                    do {
                        guard let expected = entry.snapshot, try RenameSourceSnapshot.read(entry.url) == expected else {
                            throw RenameProblem(message: "선택 이후 파일이 변경됐습니다. 새로고침하여 다시 확인하세요.")
                        }
                        return (entry.url, self.perform(Photo(url: entry.url)))
                    } catch { return (entry.url, .failure(error)) }
                }
            }
            DispatchQueue.main.async { completion(results) }
        }
    }

    static func errorMessage(for error: Error) -> String {
        (error as? PhotoTrashFailure)?.message ?? (error.localizedDescription + "\n파일을 영구 삭제하지 않았습니다.")
    }
}
