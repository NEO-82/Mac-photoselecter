import Foundation

// Serialized, atomic metadata writes. Photo files are never opened for writing.
final class TagStore {
    private struct Document: Codable {
        let version: Int
        let taggedPaths: [String]
    }
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.photoselect.tags", qos: .utility)
    private var paths: Set<String> = []
    private var loaded = false
    private var loadError: Error?

    init(fileURL: URL? = nil) {
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
                try data.write(to: self.fileURL, options: .atomic)
                self.paths = updated
                return tagged
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

final class PhotoTrash {
    private let queue = DispatchQueue(label: "dev.photoselect.trash", qos: .userInitiated)
    private let move: (URL) throws -> Void
    init(move: @escaping (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) { self.move = move }

    func trash(_ photo: Photo, lease: FolderLease, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result: Result<Void, Error> = withExtendedLifetime(lease) { Result { try self.move(photo.url) } }
            // There is deliberately no permanent-delete fallback.
            DispatchQueue.main.async { completion(result) }
        }
    }
}
