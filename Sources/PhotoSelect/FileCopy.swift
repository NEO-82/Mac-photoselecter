import Foundation
import CryptoKit
import Darwin

struct FileCopyFailure {
    let source: URL
    let destination: URL
    let message: String
    let retainedTemporaryURL: URL?
}

struct FileCopyReport {
    var copied: [URL] = []
    var createdTargets: [URL] = []
    var failures: [FileCopyFailure] = []
    var unprocessed: [URL] = []
    var verifiedPartialItems: [URL] = []
    var cancelled = false
}

struct FileCopyProgress {
    let completed: Int
    let total: Int
    let bytes: Int64
    let name: String
}

final class FileCopyCancellation {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws { if isCancelled { throw CopyError("사용자가 복사를 취소했습니다.") } }
}

struct CopyError: LocalizedError {
    let message: String
    let underlying: Error?
    init(_ message: String, underlying: Error? = nil) { self.message = message; self.underlying = underlying }
    var errorDescription: String? { message }
}

/// One worker, bounded 1 MiB buffers. Never calls a source write, move or delete API.
/// The browser excludes rename/trash while this worker runs. NSFileCoordinator
/// additionally serializes cooperating processes; it is not a filesystem lock.
final class FileCopyEngine {
    private struct TemporaryItem {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let directory: Bool
        static func capture(_ url: URL, descriptor: Int32? = nil) -> TemporaryItem? {
            var info = stat()
            let result: Int32
            if let descriptor { result = fstat(descriptor, &info) }
            else { result = lstat(url.path, &info) }
            guard result == 0 else { return nil }
            return TemporaryItem(url: url, device: info.st_dev, inode: info.st_ino,
                                 directory: (info.st_mode & S_IFMT) == S_IFDIR)
        }
        func stillOwned() -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && info.st_dev == device && info.st_ino == inode
        }
    }

    private struct PackedAttributes {
        let digests: [String: Data]
        let hasACL: Bool
    }

    private struct PackedSidecar {
        let url: URL
        let digest: Data
        let attributes: PackedAttributes
    }

    private struct PreparedSidecar {
        let packed: PackedSidecar
        let reservation: SidecarReservation
    }

    private final class PackedSidecars {
        var byPayloadPath: [String: PackedSidecar] = [:]
        var payloadDigests: [String: Data] = [:]
    }

    private final class SidecarReservation {
        let url: URL
        let descriptor: Int32

        init(url: URL, descriptor: Int32) {
            self.url = url
            self.descriptor = descriptor
        }

        deinit { close(descriptor) }
    }

    private let queue = DispatchQueue(label: "dev.photoselect.copy", qos: .utility)
    private let publish: (URL, URL) throws -> Void
    private let readBuffer: (Int32, UnsafeMutableRawPointer, Int) -> Int
    private let writeBuffer: (Int32, UnsafeRawPointer, Int) -> Int
    private let makeDirectory: (String, mode_t) -> Int32

    init(publish: @escaping (URL, URL) throws -> Void = { source, target in
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
    }, read: @escaping (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) },
       write: @escaping (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) },
       makeDirectory: @escaping (String, mode_t) -> Int32 = { Darwin.mkdir($0, $1) }) {
        self.publish = publish; self.readBuffer = read; self.writeBuffer = write
        self.makeDirectory = makeDirectory
    }

    static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    func start(_ sources: [URL], to destination: URL, cancellation: FileCopyCancellation,
               retaining retainedLeases: [FolderLease] = [],
               progress: @escaping (FileCopyProgress) -> Void,
               completion: @escaping (FileCopyReport) -> Void) {
        // Retain security-scoped access until the last worker access, including verification.
        queue.async {
            let leases = (sources + [destination]).map { FolderLease($0) }
            let report = withExtendedLifetime(retainedLeases + leases) {
                self.run(sources, to: destination, cancellation: cancellation) { value in
                    DispatchQueue.main.async { progress(value) }
                }
            }
            DispatchQueue.main.async { completion(report) }
        }
    }

    // Synchronous entry for deterministic macOS filesystem tests; never call on the UI thread.
    func run(_ sources: [URL], to destination: URL, cancellation: FileCopyCancellation = FileCopyCancellation(),
             progress: @escaping (FileCopyProgress) -> Void = { _ in }) -> FileCopyReport {
        var report = FileCopyReport(), seen = Set<String>(), bytes: Int64 = 0
        let total = sources.reduce(0) { count, source in
            guard source.isFileURL, destination.isFileURL else { return count + 1 }
            do {
                try validate(source, destination: destination)
                return count + (try countItems(source, cancellation: cancellation))
            } catch { return count + 1 }
        }
        var completed = 0
        for (index, source) in sources.enumerated() {
            if cancellation.isCancelled {
                report.cancelled = true; report.unprocessed = Array(sources[index...]); break
            }
            autoreleasepool {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                var stage: URL?
                var temporaryItems: [TemporaryItem] = []
                let createdBefore = report.createdTargets.count
                var verifiedFinalItems: [URL] = []
                do {
                    guard source.isFileURL, destination.isFileURL else { throw CopyError("로컬 파일 URL만 복사할 수 있습니다.") }
                    try validate(source, destination: destination)
                    guard seen.insert(Self.nameKey(source.lastPathComponent)).inserted else { throw CopyError("선택 항목의 이름이 충돌합니다. 건너뛰었습니다.") }
                    var coordinationError: NSError?
                    var operationError: Error?
                    var completedTarget: URL?
                    NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges,
                        writingItemAt: destination, options: [], error: &coordinationError) { readURL, writeURL in
                        do {
                            let actualTarget = writeURL.appendingPathComponent(source.lastPathComponent)
                            try self.validate(readURL, destination: writeURL)
                            try self.requireUnused(actualTarget)
                            let sidecars = try self.usesAppleDouble(writeURL) ? PackedSidecars() : nil
                            let scratch = writeURL.appendingPathComponent(".photoselect-copy-" + UUID().uuidString, isDirectory: true)
                            guard mkdir(scratch.path, 0o700) == 0 else { throw self.operationError("mkdir(임시 폴더)", at: scratch) }
                            stage = scratch
                            if let item = TemporaryItem.capture(scratch) { temporaryItems.append(item) }
                            let payload = scratch.appendingPathComponent(source.lastPathComponent)
                            var lastUpdate = ProcessInfo.processInfo.systemUptime
                            try self.copyTree(readURL, to: payload, cancellation: cancellation, sidecars: sidecars,
                                              temporaryStorage: true, onItem: {
                                completed += 1
                            }, onTemporaryCreated: { url, descriptor in
                                if let item = TemporaryItem.capture(url, descriptor: descriptor) { temporaryItems.append(item) }
                            }) { count in
                                bytes += count
                                let now = ProcessInfo.processInfo.systemUptime
                                if now - lastUpdate >= 0.1 {
                                    lastUpdate = now
                                    progress(FileCopyProgress(completed: completed, total: total, bytes: bytes, name: source.lastPathComponent))
                                }
                            }
                            try cancellation.check()
                            try self.requireUnused(actualTarget)
                            // A root-level AppleDouble is a sibling. Publishing only the
                            // payload by rename cannot guarantee the pair is preserved.
                            var needsExclusiveCopy = sidecars?.byPayloadPath[payload.path] != nil
                            if !needsExclusiveCopy {
                                do {
                                    try self.publish(payload, actualTarget)
                                    report.createdTargets.append(actualTarget)
                                } catch {
                                    let problem = error as NSError
                                    guard problem.domain == NSPOSIXErrorDomain,
                                          [Int(ENOTSUP), Int(EINVAL), Int(ENOSYS)].contains(problem.code) else {
                                        throw self.operationError("renamex_np(RENAME_EXCL)", at: actualTarget, underlying: error)
                                    }
                                    needsExclusiveCopy = true
                                }
                            }
                            if needsExclusiveCopy {
                                // exFAT may not implement RENAME_EXCL. Create every final item
                                // exclusively instead. A failed/cancelled publication may be visible
                                // partially; preserve it and report its path, never delete user data.
                                try self.requireUnused(actualTarget)
                                try self.copyTree(payload, to: actualTarget, cancellation: cancellation, onCreated: {
                                    report.createdTargets.append(actualTarget)
                                }, sidecars: sidecars, onVerified: { verifiedFinalItems.append($0) }, onBytes: { _ in })
                            }
                            do {
                                try FileManager.default.removeItem(at: scratch)
                            } catch {
                                throw self.operationError("검증된 복사본의 FileManager.removeItem(임시 폴더 정리)",
                                                          at: scratch, underlying: error)
                            }
                            stage = nil
                            completedTarget = actualTarget
                        } catch { operationError = error }
                    }
                    if let operationError { throw operationError }
                    if let coordinationError { throw coordinationError }
                    guard let completedTarget else { throw CopyError("복사 조정을 시작하지 못했습니다.") }
                    report.copied.append(completedTarget)
                } catch {
                    if let scratch = stage, report.createdTargets.count == createdBefore,
                       cancellation.isCancelled || isNoSpace(error) {
                        // Unlink only entries recorded at exclusive creation, never
                        // recursively remove an error-stage tree containing unknown files.
                        if cleanupTemporary(temporaryItems, root: scratch) { stage = nil }
                    }
                    if !report.copied.contains(target) { report.verifiedPartialItems.append(contentsOf: verifiedFinalItems) }
                    report.failures.append(FileCopyFailure(source: source, destination: target,
                        message: error.localizedDescription, retainedTemporaryURL: stage))
                }
                progress(FileCopyProgress(completed: completed, total: total, bytes: bytes, name: source.lastPathComponent))
            }
        }
        report.cancelled = cancellation.isCancelled
        return report
    }

    private func posixError(_ code: Int32 = errno) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
    }

    private func operationError(_ operation: String, at url: URL, underlying error: Error? = nil) -> CopyError {
        let cause = error ?? posixError()
        let problem = cause as NSError
        return CopyError("\(operation): \(url.path) [\(problem.domain) \(problem.code)] \(cause.localizedDescription)",
                         underlying: cause)
    }

    private func isNoSpace(_ error: Error) -> Bool {
        if let copy = error as? CopyError, let underlying = copy.underlying { return isNoSpace(underlying) }
        let problem = error as NSError
        return problem.domain == NSPOSIXErrorDomain && problem.code == Int(ENOSPC)
    }

    private func cleanupTemporary(_ items: [TemporaryItem], root: URL) -> Bool {
        guard let first = items.first, first.url == root else { return false }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_dev == first.device,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
        for item in items where item.directory && item.stillOwned() { _ = chmod(item.url.path, 0o700) }
        for item in items.reversed() {
            if item.directory {
                // Directory IDs may change on exFAT. rmdir never recursively
                // deletes entries and preserves any unknown children.
                _ = rmdir(item.url.path)
            } else if item.stillOwned() { _ = unlink(item.url.path) }
        }
        var info = stat()
        return lstat(root.path, &info) != 0 && errno == ENOENT
    }

    private func unlinkOwnedOpen(_ url: URL, descriptor: Int32) {
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0, lstat(url.path, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              (named.st_mode & S_IFMT) == S_IFREG else { return }
        _ = unlink(url.path)
    }

    private func countItems(_ url: URL, cancellation: FileCopyCancellation, depth: Int = 0) throws -> Int {
        try cancellation.check()
        guard depth < 128 else { throw CopyError("폴더 깊이가 안전 제한(128)을 넘습니다.") }
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeDirectory else { return 1 }
        let children = try folderChildren(url)
        return try children.filter { !$0.lastPathComponent.hasPrefix("._") }.reduce(1) {
            $0 + (try countItems($1, cancellation: cancellation, depth: depth + 1))
        }
    }

    // Foundation directory enumeration can omit AppleDouble entries on macOS.
    // Collision decisions must include the actual on-disk names, including orphans.
    private func directoryURLs(_ folder: URL) throws -> [URL] {
        guard let directory = opendir(folder.path) else { throw posixError() }
        defer { closedir(directory) }
        var urls: [URL] = []
        while true {
            errno = 0
            guard let pointer = readdir(directory) else {
                if errno != 0 { throw posixError() }
                break
            }
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { urls.append(folder.appendingPathComponent(name)) }
        }
        return urls
    }

    private func validate(_ source: URL, destination: URL) throws {
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CopyError("대상은 실제 폴더여야 합니다.") }
        let from = source.resolvingSymlinksInPath().standardizedFileURL.path
        let to = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let descendantPrefix = from.hasSuffix("/") ? from : from + "/"
        guard to != from, !to.hasPrefix(descendantPrefix),
              source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw CopyError("같은 폴더 또는 원본 자신의 하위 폴더에는 복사하지 않습니다.")
        }
    }

    private func requireUnused(_ target: URL) throws {
        let names = try directoryURLs(target.deletingLastPathComponent()).map(\.lastPathComponent)
        let key = Self.nameKey(target.lastPathComponent)
        // Account conservatively for AppleDouble companions on removable filesystems.
        guard !names.contains(where: { Self.nameKey($0) == key || Self.nameKey($0) == Self.nameKey("._" + target.lastPathComponent) }) else {
            throw CopyError("동일 이름 또는 대소문자/Unicode/메타데이터 이름 충돌: " + target.lastPathComponent + " (건너뜀)")
        }
    }

    private func folderChildren(_ folder: URL) throws -> [URL] {
        // Finder updates its view settings independently of the copied files.
        try directoryURLs(folder).filter { ![".DS_Store", "._.DS_Store"].contains($0.lastPathComponent) }
    }

    private func usesAppleDouble(_ directory: URL) throws -> Bool {
        var info = statfs()
        guard statfs(directory.path, &info) == 0 else { throw operationError("statfs", at: directory) }
        let capacity = MemoryLayout.size(ofValue: info.f_fstypename)
        return withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0).lowercased() == "exfat" }
        }
    }

    private func copyTree(_ source: URL, to destination: URL, cancellation: FileCopyCancellation,
                          onCreated: () -> Void = {},
                          depth: Int = 0, sidecars: PackedSidecars? = nil, temporaryStorage: Bool = false, onItem: () -> Void = {},
                          onVerified: (URL) -> Void = { _ in },
                          onTemporaryCreated: (URL, Int32?) -> Void = { _, _ in },
                          onBytes: (Int64) -> Void) throws {
        try cancellation.check()
        guard depth < 128 else { throw CopyError("폴더 깊이가 안전 제한(128)을 넘습니다.") }
        let info = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let type = info[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else {
            throw CopyError("심볼릭 링크와 특수 파일은 복사하지 않습니다: " + source.path)
        }
        let stagedSidecar = temporaryStorage ? nil : sidecars?.byPayloadPath[source.path]
        if type == .typeDirectory {
            let prepared = try createCopyDirectory(source, at: destination, stagingMetadata: temporaryStorage && sidecars != nil,
                stagedSidecar: stagedSidecar, cancellation: cancellation, onCreated: onCreated,
                onTemporaryCreated: onTemporaryCreated)
            let children = try folderChildren(source)
            var keys = Set<String>()
            let names = Set(children.map(\.lastPathComponent))
            for child in children {
                // copyfile preserves associated metadata. Do not duplicate a sidecar
                // as an unrelated file or overwrite one generated by copyfile.
                if child.lastPathComponent.hasPrefix("._") {
                    if names.contains(String(child.lastPathComponent.dropFirst(2))) { continue }
                    throw CopyError("연결된 원본이 없는 AppleDouble 파일은 검토가 필요합니다: " + child.path)
                }
                guard keys.insert(Self.nameKey(child.lastPathComponent)).inserted else { throw CopyError("폴더 내부 이름 충돌: " + child.path) }
                let target = destination.appendingPathComponent(child.lastPathComponent)
                do {
                    try copyTree(child, to: target, cancellation: cancellation,
                                 depth: depth + 1, sidecars: sidecars, temporaryStorage: temporaryStorage,
                                 onItem: onItem, onVerified: onVerified,
                                 onTemporaryCreated: onTemporaryCreated, onBytes: onBytes)
                } catch {
                    throw CopyError("실패한 항목: \(child.path)\n대상: \(target.path)\n" + error.localizedDescription, underlying: error)
                }
            }
            let after = try folderChildren(source)
            guard Set(children.map(\.lastPathComponent)) == Set(after.map(\.lastPathComponent)) else { throw CopyError("복사 중 원본 폴더 내용이 변경되었습니다.") }
            try withOpenDirectory(source) { input in
                try withOpenDirectory(destination) { output in
                    try finishMetadata(input, to: output, source: source, destination: destination,
                                       usesAppleDouble: sidecars != nil, prepared: prepared, cancellation: cancellation)
                }
            }
            if temporaryStorage { sidecars?.byPayloadPath[destination.path] = prepared?.packed }
        } else {
            guard !source.lastPathComponent.hasPrefix("._") else { throw CopyError("AppleDouble 메타데이터 파일은 단독 복사하지 않습니다.") }
            if stagedSidecar != nil { try requireUnusedSidecar(for: destination, operation: "파일 생성 전 AppleDouble 확인") }
            let input = open(source.path, O_RDONLY | O_NOFOLLOW)
            guard input >= 0 else { throw operationError("open(원본)", at: source) }
            defer { close(input) }
            var before = stat()
            guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw CopyError("원본 파일 유형이 변경되었습니다.") }
            let output = open(destination.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw operationError("open(대상)", at: destination) }
            onCreated()
            onTemporaryCreated(destination, output)
            var transferError: Error?
            defer {
                if temporaryStorage && (cancellation.isCancelled || transferError.map { isNoSpace($0) } == true) {
                    // On exFAT a file's ID can change on close. Remove a cancelled
                    // private stream while its exclusive descriptor still binds it.
                    unlinkOwnedOpen(destination, descriptor: output)
                }
                // exFAT may assign a new file ID when an empty file first grows.
                // Refresh ownership from the still-open descriptor before cleanup.
                onTemporaryCreated(destination, output)
                close(output)
            }
            do {
                // Darwin can discard an orphan AppleDouble when the base file
                // is created. Reserve and fill it before streaming the payload.
                let published = try preparePublishedSidecar(stagedSidecar, for: destination, cancellation: cancellation)
                let transferred = try stream(input, to: output, source: source, destination: destination,
                                             cancellation: cancellation, onBytes: onBytes)
                guard fsync(output) == 0 else { throw operationError("fsync(대상)", at: destination) }
                var after = stat()
                guard fstat(input, &after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                      transferred.size == before.st_size else { throw CopyError("복사 중 원본 파일이 변경되었습니다.") }
                var current = stat()
                guard lstat(source.path, &current) == 0, current.st_dev == before.st_dev, current.st_ino == before.st_ino else {
                    throw CopyError("복사 중 원본 경로가 교체되었습니다.")
                }
                let verifiedDigest: Data
                do {
                    verifiedDigest = try digest(output, cancellation: cancellation)
                } catch {
                    throw operationError("SHA-256 검증 중 대상 읽기", at: destination, underlying: error)
                }
                guard verifiedDigest == transferred.digest else {
                    throw CopyError("복사본 SHA-256 내용 검증 실패: " + destination.path)
                }
                if let sidecars {
                    if temporaryStorage {
                        sidecars.payloadDigests[destination.path] = verifiedDigest
                    } else if sidecars.payloadDigests[source.path] != verifiedDigest {
                        throw CopyError("검증된 임시 파일의 SHA-256이 변경되었습니다: " + source.path)
                    }
                }
                _ = try requireOwned(destination, descriptor: output)
                let prepared: PreparedSidecar?
                if temporaryStorage && sidecars != nil {
                    let attributes = try packedAttributes(input, source: source, cancellation: cancellation)
                    prepared = try packSidecar(input, attributes: attributes, for: destination, cancellation: cancellation,
                                               onTemporaryCreated: onTemporaryCreated)
                } else {
                    prepared = published
                }
                try finishMetadata(input, to: output, source: source, destination: destination,
                                   usesAppleDouble: sidecars != nil, prepared: prepared, cancellation: cancellation)
                if temporaryStorage { sidecars?.byPayloadPath[destination.path] = prepared?.packed }
                _ = try requireOwned(destination, descriptor: output)
            } catch { transferError = error; throw error }
        }
        onItem()
        onVerified(destination)
    }

    private func stream(_ input: Int32, to output: Int32, source: URL, destination: URL,
                        cancellation: FileCopyCancellation, onBytes: (Int64) -> Void) throws -> (size: Int64, digest: Data) {
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024), hash = SHA256(), size: Int64 = 0
        while true {
            try cancellation.check()
            let count = buffer.withUnsafeMutableBytes { self.readBuffer(input, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw operationError("read(원본)", at: source)
            }
            if count == 0 { break }
            autoreleasepool { hash.update(data: Data(buffer.prefix(count))) }
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < count {
                    try cancellation.check()
                    let written = self.writeBuffer(output, raw.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw operationError("write(대상)", at: destination)
                    }
                    guard written > 0 else { throw CopyError("대상 쓰기가 중단되었습니다.") }
                    offset += written
                }
            }
            size += Int64(count); onBytes(Int64(count))
        }
        return (size, Data(hash.finalize()))
    }

    private func digest(_ descriptor: Int32, cancellation: FileCopyCancellation) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while true {
            try cancellation.check()
            let more = try autoreleasepool { () throws -> Bool in
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !more { break }
        }
        return Data(hash.finalize())
    }

    private func withOpenDirectory<T>(_ url: URL, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw operationError("open(폴더)", at: url) }
        defer { close(descriptor) }
        return try body(descriptor)
    }

    private func createCopyDirectory(_ source: URL, at destination: URL, stagingMetadata: Bool,
                                     stagedSidecar: PackedSidecar?, cancellation: FileCopyCancellation,
                                     onCreated: () -> Void, onTemporaryCreated: (URL, Int32?) -> Void) throws -> PreparedSidecar? {
        func create(attributes: PackedAttributes?, input: Int32?) throws -> PreparedSidecar? {
            try cancellation.check()
            if attributes != nil { try requireUnusedSidecar(for: destination, operation: "mkdir 전 AppleDouble 확인") }
            guard makeDirectory(destination.path, 0o700) == 0 else { throw operationError("mkdir", at: destination) }
            onCreated()
            onTemporaryCreated(destination, nil)
            guard let attributes, let input else { return nil }

            let reservation: SidecarReservation
            do {
                reservation = try reserveSidecar(for: destination)
            } catch let error as CopyError {
                guard let underlying = error.underlying else { throw error }
                let problem = underlying as NSError
                guard problem.domain == NSPOSIXErrorDomain, problem.code == Int(EEXIST) else { throw error }
                // mkdir can be followed by filesystem metadata such as quarantine.
                // Keep nonexclusive companions read-only and use XATTR_CREATE on
                // the new directory only after verifying its attached metadata.
                return try preserveDirectorySidecar(input, attributes: attributes, at: destination,
                                                   cancellation: cancellation, collision: error)
            }
            if let stagedSidecar {
                return try preparePublishedSidecar(stagedSidecar, for: destination, reservation: reservation,
                                                   cancellation: cancellation)
            }
            return try packSidecar(input, attributes: attributes, for: destination, reservation: reservation,
                                   cancellation: cancellation, onTemporaryCreated: onTemporaryCreated)
        }

        if stagingMetadata || stagedSidecar != nil {
            return try withOpenDirectory(source) { input in
                let attributes = try stagedSidecar?.attributes ?? packedAttributes(input, source: source, cancellation: cancellation)
                return try create(attributes: attributes, input: input)
            }
        }
        return try create(attributes: nil, input: nil)
    }

    private func finishMetadata(_ input: Int32, to output: Int32, source: URL, destination: URL,
                                usesAppleDouble: Bool, prepared: PreparedSidecar?, cancellation: FileCopyCancellation) throws {
        if usesAppleDouble {
            try copyStatMetadata(input, to: output, destination: destination)
            if let prepared {
                try verifySidecar(prepared.reservation, expected: prepared.packed, payload: destination,
                                  descriptor: output, cancellation: cancellation)
            }
            return
        }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            let error = posixError()
            throw CopyError("파일 기술자 메타데이터 복사 실패: \(source.path) → \(destination.path): " + error.localizedDescription, underlying: error)
        }
    }

    private let metadataLimit = 64 * 1024 * 1024

    private func attributeNames(_ descriptor: Int32) throws -> [String] {
        let count = flistxattr(descriptor, nil, 0, 0)
        guard count >= 0 else { throw posixError() }
        guard count <= 256 * 1024 else { throw CopyError("확장 속성 이름 목록이 안전 제한을 넘습니다.") }
        if count == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let actual = bytes.withUnsafeMutableBytes {
            flistxattr(descriptor, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, 0)
        }
        guard actual >= 0 else { throw posixError() }
        return try bytes.prefix(actual).split(separator: 0).map {
            guard let name = String(bytes: $0, encoding: .utf8) else { throw CopyError("확장 속성 이름을 읽지 못했습니다.") }
            return name
        }
    }

    private func attributeContents(_ descriptor: Int32, name: String) throws -> Data {
        let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
        guard size >= 0 else { throw posixError() }
        guard size <= metadataLimit else { throw CopyError("확장 속성/리소스 포크가 안전 메모리 제한(64 MiB)을 넘습니다: " + name) }
        var bytes = Data(count: size)
        let actual = bytes.withUnsafeMutableBytes { fgetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0) }
        guard actual == size else { throw CopyError("확장 속성이 읽는 동안 변경되었습니다: " + name) }
        return bytes
    }

    private func quarantineRecord(_ bytes: Data, name: String) -> Data {
        // Apple's packer can wrap quarantine as "q/<record>\0".
        // Strip only that envelope before comparing the exact record bytes.
        if name == "com.apple.quarantine", bytes.starts(with: "q/".utf8), bytes.last == 0 {
            return Data(bytes.dropFirst(2).dropLast())
        }
        return bytes
    }

    private func attributeDigest(_ descriptor: Int32, name: String) throws -> (Int, Data) {
        let bytes = try attributeContents(descriptor, name: name)
        return (bytes.count, Data(SHA256.hash(data: quarantineRecord(bytes, name: name))))
    }

    private func sidecarURL(for payload: URL) -> URL {
        payload.deletingLastPathComponent().appendingPathComponent("._" + payload.lastPathComponent)
    }

    private func requireUnusedSidecar(for payload: URL, operation: String) throws {
        let companion = sidecarURL(for: payload)
        var info = stat()
        guard lstat(companion.path, &info) != 0 else {
            throw operationError(operation + "(기존 보조 파일 보존)", at: companion, underlying: posixError(EEXIST))
        }
        guard errno == ENOENT else { throw operationError("lstat(AppleDouble)", at: companion) }
    }

    private func reserveSidecar(for payload: URL) throws -> SidecarReservation {
        let sidecar = sidecarURL(for: payload)
        let descriptor = open(sidecar.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            let operation = code == EEXIST ? "open(AppleDouble, O_EXCL, 기존 보조 파일 보존)" : "open(AppleDouble, O_EXCL)"
            throw operationError(operation, at: sidecar, underlying: posixError(code))
        }
        return SidecarReservation(url: sidecar, descriptor: descriptor)
    }

    private func requireOwned(_ url: URL, descriptor: Int32) throws -> TemporaryItem {
        guard let item = TemporaryItem.capture(url, descriptor: descriptor), item.stillOwned() else {
            throw CopyError("복사 중 경로가 교체되었습니다: " + url.path)
        }
        return item
    }

    private func preserveDirectorySidecar(_ input: Int32, attributes: PackedAttributes, at payload: URL,
                                          cancellation: FileCopyCancellation, collision: CopyError) throws -> PreparedSidecar {
        let path = sidecarURL(for: payload)
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw collision }
        // This descriptor pins the observed file for verification. Only
        // reserveSidecar grants permission to write raw AppleDouble bytes.
        let observed = SidecarReservation(url: path, descriptor: descriptor)
        return try withOpenDirectory(payload) { output in
            let folder = try requireOwned(payload, descriptor: output)
            let companion = try requireOwned(path, descriptor: descriptor)
            var folderInfo = stat(), sidecarInfo = stat()
            let magic: [UInt8] = [0, 5, 0x16, 7, 0, 2, 0, 0]
            var header = [UInt8](repeating: 0, count: magic.count)
            guard fstat(output, &folderInfo) == 0, fstat(descriptor, &sidecarInfo) == 0,
                  (sidecarInfo.st_mode & S_IFMT) == S_IFREG, sidecarInfo.st_nlink == 1,
                  folder.device == companion.device, folderInfo.st_uid == sidecarInfo.st_uid,
                  sidecarInfo.st_size <= Int64(metadataLimit + 256 * 1024),
                  pread(descriptor, &header, header.count, 0) == magic.count, header == magic else {
                throw collision
            }
            // Never infer ownership from timing. Recognize only metadata
            // exposed by the new folder's descriptor, and preserve its values.
            let originalNames = try attributeNames(output)
            let automatic: Set<String> = ["com.apple.quarantine", "com.apple.provenance"]
            guard !originalNames.isEmpty, !attributes.hasACL else { throw collision }
            var preserved: [String: Data] = [:]
            for name in originalNames {
                try cancellation.check()
                let value = try attributeDigest(output, name: name).1
                if let expected = attributes.digests[name] {
                    guard expected == value else { throw collision }
                } else if !automatic.contains(name) {
                    throw collision
                }
                preserved[name] = value
            }
            try verifyAttributes(attributes.digests, on: input, at: payload, cancellation: cancellation)
            for (name, expected) in attributes.digests where preserved[name] == nil {
                try cancellation.check()
                guard companion.stillOwned(), folder.stillOwned() else { throw collision }
                let value = try quarantineRecord(attributeContents(input, name: name), name: name)
                guard Data(SHA256.hash(data: value)) == expected else { throw collision }
                let result = value.withUnsafeBytes {
                    fsetxattr(output, name, $0.baseAddress, $0.count, 0, XATTR_CREATE)
                }
                guard result == 0 else { throw operationError("fsetxattr(XATTR_CREATE, \(name))", at: payload) }
                guard companion.stillOwned(), folder.stillOwned() else { throw collision }
            }
            let verifiedNames = Set(preserved.keys).union(attributes.digests.keys)
            guard Set(try attributeNames(output)) == verifiedNames else { throw collision }
            try verifyAttributes(preserved, on: output, at: payload, cancellation: cancellation)
            try verifyAttributes(attributes.digests, on: output, at: payload, cancellation: cancellation)
            let hash = try digest(descriptor, cancellation: cancellation)
            guard companion.stillOwned(), folder.stillOwned() else { throw collision }
            return PreparedSidecar(packed: PackedSidecar(url: path, digest: hash, attributes: attributes),
                                   reservation: observed)
        }
    }

    private func preparePublishedSidecar(_ staged: PackedSidecar?, for payload: URL, reservation: SidecarReservation? = nil,
                                         cancellation: FileCopyCancellation) throws -> PreparedSidecar? {
        guard let staged else { return nil }
        try cancellation.check()
        let reservation = try reservation ?? reserveSidecar(for: payload)
        let path = staged.url
        let input = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw operationError("open(임시 AppleDouble)", at: path) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              try digest(input, cancellation: cancellation) == staged.digest else {
            throw CopyError("검증된 임시 AppleDouble의 SHA-256이 변경되었습니다: " + path.path)
        }
        _ = try requireOwned(path, descriptor: input)
        guard lseek(input, 0, SEEK_SET) == 0 else { throw operationError("lseek(임시 AppleDouble)", at: path) }
        let destination = reservation.descriptor
        _ = try requireOwned(reservation.url, descriptor: destination)
        guard fstat(destination, &info) == 0 else { throw operationError("fstat(AppleDouble)", at: reservation.url) }
        guard info.st_size == 0 else { throw CopyError("예약한 AppleDouble 내용이 변경되었습니다: " + reservation.url.path) }
        let transferred = try stream(input, to: destination, source: path, destination: reservation.url,
                                     cancellation: cancellation, onBytes: { _ in })
        guard transferred.digest == staged.digest else {
            throw CopyError("검증된 임시 AppleDouble의 SHA-256이 변경되었습니다: " + path.path)
        }
        guard fsync(destination) == 0 else { throw operationError("fsync(AppleDouble)", at: reservation.url) }
        return PreparedSidecar(packed: staged, reservation: reservation)
    }

    private func verifyAttributes(_ expected: [String: Data], on output: Int32, at destination: URL,
                                  cancellation: FileCopyCancellation) throws {
        for (name, digest) in expected {
            try cancellation.check()
            let actual: Data
            do {
                actual = try autoreleasepool { try attributeDigest(output, name: name).1 }
            } catch {
                throw operationError("fgetxattr(AppleDouble 검증, \(name))", at: destination, underlying: error)
            }
            guard actual == digest else { throw CopyError("복사본 확장 속성/리소스 포크 SHA-256 검증 실패: " + name) }
        }
    }

    private func verifySidecar(_ reservation: SidecarReservation, expected: PackedSidecar,
                               payload: URL, descriptor: Int32, cancellation: FileCopyCancellation) throws {
        _ = try requireOwned(reservation.url, descriptor: reservation.descriptor)
        try verifyAttributes(expected.attributes.digests, on: descriptor, at: payload, cancellation: cancellation)
        guard try digest(reservation.descriptor, cancellation: cancellation) == expected.digest else {
            throw CopyError("복사본 AppleDouble SHA-256 검증 실패: " + reservation.url.path)
        }
        _ = try requireOwned(reservation.url, descriptor: reservation.descriptor)
        _ = try requireOwned(payload, descriptor: descriptor)
    }

    private func packedAttributes(_ input: Int32, source: URL, cancellation: FileCopyCancellation) throws -> PackedAttributes? {
        let names = try attributeNames(input)
        var expected: [String: Data] = [:], total = 0
        for name in names {
            try cancellation.check()
            let value = try autoreleasepool { try attributeDigest(input, name: name) }
            total += value.0
            guard total <= metadataLimit else { throw CopyError("파일 메타데이터 합계가 안전 메모리 제한(64 MiB)을 넘습니다.") }
            expected[name] = value.1
        }
        let flags = copyfile_flags_t(COPYFILE_CHECK | COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC)
        let check = copyfile(source.path, nil, nil, flags)
        guard check >= 0 else { throw operationError("copyfile(COPYFILE_CHECK)", at: source) }
        let hasACL = (UInt32(check) & UInt32(COPYFILE_ACL)) != 0
        return !names.isEmpty || hasACL ? PackedAttributes(digests: expected, hasACL: hasACL) : nil
    }

    private func packSidecar(_ input: Int32, attributes: PackedAttributes?, for destination: URL,
                             reservation: SidecarReservation? = nil,
                             cancellation: FileCopyCancellation,
                             onTemporaryCreated: (URL, Int32?) -> Void) throws -> PreparedSidecar? {
        // exFAT rejects native ResourceFork writes, including through copyfile.
        guard let attributes else { return nil }
        let reservation = try reservation ?? reserveSidecar(for: destination)
        let sidecar = reservation.url, packed = reservation.descriptor
        onTemporaryCreated(sidecar, packed)
        var packingError: Error?
        defer {
            if cancellation.isCancelled || packingError.map({ isNoSpace($0) }) == true {
                unlinkOwnedOpen(sidecar, descriptor: packed)
            }
            onTemporaryCreated(sidecar, packed)
        }
        do {
            guard fcopyfile(input, packed, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_PACK)) == 0 else {
                throw operationError("fcopyfile(COPYFILE_PACK)", at: sidecar)
            }
            guard fsync(packed) == 0 else { throw operationError("fsync(AppleDouble)", at: sidecar) }
            let hash = try digest(packed, cancellation: cancellation)
            _ = try requireOwned(sidecar, descriptor: packed)
            return PreparedSidecar(packed: PackedSidecar(url: sidecar, digest: hash, attributes: attributes),
                                   reservation: reservation)
        } catch {
            packingError = error
            throw error
        }
    }

    private func copyStatMetadata(_ input: Int32, to output: Int32, destination: URL) throws {
        // fcopyfile(COPYFILE_STAT) can also apply com.apple.quarantine.
        // Keep all extended metadata exclusively in the verified AppleDouble.
        var info = stat()
        guard fstat(input, &info) == 0 else { throw posixError() }
        let times = [info.st_atimespec, info.st_mtimespec]
        let result = times.withUnsafeBufferPointer { futimens(output, $0.baseAddress) }
        guard result == 0 else { throw operationError("futimens", at: destination) }
        // exFAT can synthesize ownership and POSIX modes. Restore what the
        // mount supports, without copying setuid or filesystem-private flags.
        _ = fchown(output, info.st_uid, info.st_gid)
        _ = fchmod(output, info.st_mode & 0o1777)
        let supportedFlags = UInt32(UF_HIDDEN | UF_IMMUTABLE | SF_ARCHIVED)
        _ = fchflags(output, info.st_flags & supportedFlags)
        if (info.st_mode & S_IFMT) == S_IFREG {
            guard fsync(output) == 0 else { throw operationError("fsync(대상)", at: destination) }
        }
    }
}
