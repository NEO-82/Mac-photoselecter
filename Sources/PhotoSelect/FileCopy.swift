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
    private let queue = DispatchQueue(label: "dev.photoselect.copy", qos: .utility)
    private let publish: (URL, URL) throws -> Void
    private let readBuffer: (Int32, UnsafeMutableRawPointer, Int) -> Int
    private let writeBuffer: (Int32, UnsafeRawPointer, Int) -> Int

    init(publish: @escaping (URL, URL) throws -> Void = { source, target in
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
    }, read: @escaping (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) },
       write: @escaping (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }) {
        self.publish = publish; self.readBuffer = read; self.writeBuffer = write
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
                var performed = false
                NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges,
                    writingItemAt: destination, options: [], error: &coordinationError) { readURL, writeURL in
                    do {
                        let actualTarget = writeURL.appendingPathComponent(source.lastPathComponent)
                        try self.validate(readURL, destination: writeURL)
                        try self.requireUnused(actualTarget)
                        let scratch = writeURL.appendingPathComponent(".photoselect-copy-" + UUID().uuidString, isDirectory: true)
                        guard mkdir(scratch.path, 0o700) == 0 else { throw self.posixError() }
                        stage = scratch
                        if let item = TemporaryItem.capture(scratch) { temporaryItems.append(item) }
                        let payload = scratch.appendingPathComponent(source.lastPathComponent)
                        var lastUpdate = ProcessInfo.processInfo.systemUptime
                        try self.copyTree(readURL, to: payload, cancellation: cancellation, onItem: {
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
                        // Atomic exclusive publication where supported. No nonexclusive rename fallback.
                        do {
                            try self.publish(payload, actualTarget)
                            report.createdTargets.append(actualTarget)
                        } catch {
                            let problem = error as NSError
                            guard problem.domain == NSPOSIXErrorDomain,
                                  [Int(ENOTSUP), Int(EINVAL), Int(ENOSYS)].contains(problem.code) else { throw error }
                            // exFAT may not implement RENAME_EXCL. Create every final item
                            // exclusively instead. A failed/cancelled publication may be visible
                            // partially; preserve it and report its path, never delete user data.
                            try self.copyTree(payload, to: actualTarget, cancellation: cancellation, onCreated: {
                                report.createdTargets.append(actualTarget)
                            }, onVerified: { verifiedFinalItems.append($0) }, onBytes: { _ in })
                        }
                        report.copied.append(actualTarget)
                        performed = true
                        try FileManager.default.removeItem(at: scratch)
                        stage = nil
                    } catch { operationError = error }
                }
                if let operationError { throw operationError }
                if let coordinationError { throw coordinationError }
                guard performed else { throw CopyError("복사 조정을 시작하지 못했습니다.") }
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
        report.cancelled = cancellation.isCancelled
        return report
    }

    private func posixError(_ code: Int32 = errno) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
    }

    private func isNoSpace(_ error: Error) -> Bool {
        if let copy = error as? CopyError, let underlying = copy.underlying { return isNoSpace(underlying) }
        let problem = error as NSError
        return problem.domain == NSPOSIXErrorDomain && problem.code == Int(ENOSPC)
    }

    private func cleanupTemporary(_ items: [TemporaryItem], root: URL) -> Bool {
        guard items.first?.url == root, items.first?.stillOwned() == true else { return false }
        for item in items where item.directory && item.stillOwned() { _ = chmod(item.url.path, 0o700) }
        for item in items.reversed() where item.stillOwned() {
            if item.directory { _ = rmdir(item.url.path) }
            else { _ = unlink(item.url.path) }
        }
        var info = stat()
        return lstat(root.path, &info) != 0 && errno == ENOENT
    }

    private func countItems(_ url: URL, cancellation: FileCopyCancellation, depth: Int = 0) throws -> Int {
        try cancellation.check()
        guard depth < 128 else { throw CopyError("폴더 깊이가 안전 제한(128)을 넘습니다.") }
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeDirectory else { return 1 }
        let children = try directoryURLs(url)
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

    private func copyTree(_ source: URL, to destination: URL, cancellation: FileCopyCancellation,
                          onCreated: () -> Void = {},
                          depth: Int = 0, onItem: () -> Void = {},
                          onVerified: (URL) -> Void = { _ in },
                          onTemporaryCreated: (URL, Int32?) -> Void = { _, _ in },
                          onBytes: (Int64) -> Void) throws {
        try cancellation.check()
        guard depth < 128 else { throw CopyError("폴더 깊이가 안전 제한(128)을 넘습니다.") }
        let info = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let type = info[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else {
            throw CopyError("심볼릭 링크와 특수 파일은 복사하지 않습니다: " + source.path)
        }
        if type == .typeDirectory {
            guard mkdir(destination.path, 0o700) == 0 else { throw posixError() }
            onCreated()
            onTemporaryCreated(destination, nil)
            let children = try directoryURLs(source)
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
                                 depth: depth + 1, onItem: onItem, onVerified: onVerified,
                                 onTemporaryCreated: onTemporaryCreated, onBytes: onBytes)
                } catch {
                    throw CopyError("실패한 항목: \(child.path)\n대상: \(target.path)\n" + error.localizedDescription, underlying: error)
                }
            }
            try metadata(source, to: destination)
            let after = try directoryURLs(source)
            guard Set(children.map(\.lastPathComponent)) == Set(after.map(\.lastPathComponent)) else { throw CopyError("복사 중 원본 폴더 내용이 변경되었습니다.") }
        } else {
            guard !source.lastPathComponent.hasPrefix("._") else { throw CopyError("AppleDouble 메타데이터 파일은 단독 복사하지 않습니다.") }
            let input = open(source.path, O_RDONLY | O_NOFOLLOW)
            guard input >= 0 else { throw posixError() }
            defer { close(input) }
            var before = stat()
            guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw CopyError("원본 파일 유형이 변경되었습니다.") }
            let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw posixError() }
            onCreated()
            onTemporaryCreated(destination, output)
            defer {
                // exFAT may assign a new file ID when an empty file first grows.
                // Refresh ownership from the still-open descriptor before cleanup.
                onTemporaryCreated(destination, output)
                close(output)
            }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024), hash = SHA256(), size: Int64 = 0
            while true {
                try cancellation.check()
                let count = buffer.withUnsafeMutableBytes { self.readBuffer(input, $0.baseAddress!, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw posixError() }
                if count == 0 { break }
                hash.update(data: Data(buffer.prefix(count)))
                try buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < count {
                        try cancellation.check()
                        let written = self.writeBuffer(output, raw.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 { if errno == EINTR { continue }; throw posixError() }
                        guard written > 0 else { throw CopyError("대상 쓰기가 중단되었습니다.") }
                        offset += written
                    }
                }
                size += Int64(count); onBytes(Int64(count))
            }
            guard fsync(output) == 0 else { throw posixError() }
            var after = stat()
            guard fstat(input, &after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  size == before.st_size else { throw CopyError("복사 중 원본 파일이 변경되었습니다.") }
            var current = stat()
            guard lstat(source.path, &current) == 0, current.st_dev == before.st_dev, current.st_ino == before.st_ino else {
                throw CopyError("복사 중 원본 경로가 교체되었습니다.")
            }
            guard try digest(destination, cancellation: cancellation) == Data(hash.finalize()) else { throw CopyError("복사본 SHA-256 내용 검증 실패: " + destination.path) }
            try metadata(source, to: destination)
        }
        onItem()
        onVerified(destination)
    }

    private func digest(_ url: URL, cancellation: FileCopyCancellation) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try cancellation.check()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }; hash.update(data: data)
        }
        return Data(hash.finalize())
    }

    private func metadata(_ source: URL, to destination: URL) throws {
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else {
            let error = posixError()
            throw CopyError("메타데이터 복사 실패: \(source.path) → \(destination.path): " + error.localizedDescription, underlying: error)
        }
    }
}
