import Foundation
import Darwin

struct RenameProblem: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct RenameSettings {
    var base = "Photo", separator = "_"
    var start = 1, digits = 4
}
struct RenamePreview {
    let original: String
    let proposed: String
    var issue: String?
}
struct RenamePlan {
    let folder: URL
    let orderTitle: String
    var rows: [RenamePreview]
    var volumeUUID: String? = nil
    var selectedOnly = false
    var snapshots: [String: RenameSourceSnapshot] = [:]
    var valid: Bool {
        !rows.isEmpty && rows.count <= 10_000 && Set(rows.map(\.original)).count == rows.count && rows.allSatisfy {
            $0.issue == nil && Self.leaf($0.original) && Self.leaf($0.proposed) && !$0.proposed.hasPrefix("._") && $0.proposed.utf8.count <= 255 &&
            ($0.original as NSString).pathExtension == ($0.proposed as NSString).pathExtension
        } && Set(rows.map { Self.folded($0.proposed) }).count == rows.count
    }
    var changedCount: Int { rows.filter { $0.original != $0.proposed }.count }
    static func isTargetPhoto(_ entry: BrowserEntry) -> Bool {
        entry.isPhoto && !entry.url.lastPathComponent.hasPrefix("._")
    }
    static func leaf(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && !text.contains("/") && !text.contains("\0")
    }
    static func folded(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    static func make(folder: URL, photos: [BrowserEntry], orderTitle: String, settings: RenameSettings, existingNames: Set<String>, selectedOnly: Bool = false) throws -> RenamePlan {
        guard settings.base.utf8.count + settings.separator.utf8.count <= 255,
              !settings.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(settings.base + settings.separator).contains(where: { "/:\0\n\r".contains($0) }),
              settings.start >= 0, (1...12).contains(settings.digits),
              settings.start <= Int.max - max(0, photos.count - 1) else {
            throw RenameProblem(message: "기본 이름·구분 문자 합계는 UTF-8 255바이트 이내여야 하며 / : 또는 줄바꿈을 사용할 수 없습니다. 시작 번호는 0 이상, 자릿수는 1–12로 입력하세요.")
        }
        var rows = photos.filter(isTargetPhoto).enumerated().map { index, photo -> RenamePreview in
            let number = String(settings.start + index)
            let padded = String(repeating: "0", count: max(0, settings.digits - number.count)) + number
            let name = settings.base + settings.separator + padded + "." + photo.url.pathExtension
            let sameFolder = TagStore.key(photo.url.deletingLastPathComponent()) == TagStore.key(folder)
            return RenamePreview(original: photo.url.lastPathComponent, proposed: name,
                issue: !sameFolder ? "현재 폴더 밖의 파일" : (!leaf(name) || name.utf8.count > 255 || name.hasPrefix("._") ? "잘못되었거나 너무 긴 이름 / macOS 메타데이터 접두사" : nil))
        }
        let original = Set(rows.map(\.original))
        let occupied = Set(existingNames.filter { !original.contains($0) }.map(folded))
        let counts = Dictionary(grouping: rows, by: { folded($0.proposed) }).mapValues(\.count)
        for index in rows.indices {
            if counts[folded(rows[index].proposed), default: 0] > 1 { rows[index].issue = "변경 예정 이름 중복" }
            if occupied.contains(folded(rows[index].proposed)) { rows[index].issue = "기존 폴더/파일과 충돌" }
        }
        var plan = RenamePlan(folder: folder, orderTitle: orderTitle, rows: rows, volumeUUID: BatchRenameEngine.volume(folder).0)
        plan.selectedOnly = selectedOnly
        for entry in photos.filter(isTargetPhoto) {
            if let snapshot = entry.snapshot ?? (try? RenameSourceSnapshot.read(entry.url)) {
                plan.snapshots[entry.url.lastPathComponent] = snapshot
            }
        }
        return plan
    }
}

struct RenameIdentity: Codable, Hashable {
    let device: UInt64, inode: UInt64
    static func read(_ url: URL) throws -> RenameIdentity {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }; return lstat(path, &info)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw RenameProblem(message: "일반 파일이 아닙니다: " + url.lastPathComponent) }
        return RenameIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }
}
// Captured off the main thread, then checked immediately before any move.
struct RenameSourceSnapshot: Hashable {
    let identity: RenameIdentity
    let bytes: Int64, modifiedSeconds: Int64, modifiedNanos: Int64
    let bornSeconds: Int64, bornNanos: Int64, links: UInt64
    let changedSeconds: Int64, changedNanos: Int64
    static func read(_ url: URL) throws -> RenameSourceSnapshot {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }; return lstat(path, &info)
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw RenameProblem(message: "일반 파일이 아닙니다: " + url.lastPathComponent) }
        return RenameSourceSnapshot(identity: RenameIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino)),
            bytes: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
            bornSeconds: Int64(info.st_birthtimespec.tv_sec), bornNanos: Int64(info.st_birthtimespec.tv_nsec), links: UInt64(info.st_nlink),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
}

private final class RenameLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent(".rename.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw RenameProblem(message: "다른 이름 변경 작업이 실행 중입니다.") }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
struct RenameJournal: Codable {
    struct Item: Codable {
        let original: String, destination: String, temporary: String
        let identity: RenameIdentity
    }
    let version: Int
    let id: UUID
    let folderPath: String
    let volumeUUID: String?
    let relativeFolder: String?
    let orderTitle: String
    let items: [Item]
    let tagSnapshot: [String]
    var phase: String
}
struct RenameOutcome {
    let completed: Bool
    let restored: Bool
    let mapping: [URL: URL]
    let taggedPaths: Set<String>?
    let message: String
    let journalURL: URL?
}

// Images are only moved with the OS exclusive rename primitive, never copied or opened for writing.
final class BatchRenameEngine {
    typealias Move = (URL, URL) throws -> Void
    typealias Progress = (Int, Int, String) -> Void
    let journalDirectory: URL
    private let move: Move
    private let queue = DispatchQueue(label: "dev.photoselect.rename", qos: .userInitiated)
    init(journalDirectory: URL? = nil, move: @escaping Move = BatchRenameEngine.exclusiveMove) {
        self.journalDirectory = journalDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.photoselect.app/rename-journals")
        self.move = move
    }
    static func exclusiveMove(_ source: URL, _ destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from -> Int32 in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { errno = EINVAL; return -1 }
                return renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func volume(_ folder: URL) -> (String?, String?) {
        var fresh = folder; fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        let root = values?.volume?.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        let relative = root.flatMap { root in path.hasPrefix(root == "/" ? "/" : root + "/") ? String(path.dropFirst(root == "/" ? 1 : root.count + 1)) : (path == root ? "" : nil) }
        return (values?.volumeUUIDString, relative)
    }
    func readJournal(_ url: URL, folder: URL) throws -> RenameJournal {
        let journal = try JSONDecoder().decode(RenameJournal.self, from: Data(contentsOf: url))
        guard journal.version == 1, TagStore.key(url.deletingLastPathComponent()) == TagStore.key(journalDirectory),
              url.lastPathComponent == journal.id.uuidString + ".json",
              !journal.items.isEmpty, journal.items.count <= 10_000,
              journal.items.allSatisfy({ RenamePlan.leaf($0.original) && RenamePlan.leaf($0.destination) && RenamePlan.leaf($0.temporary) && $0.temporary.hasPrefix(".J-S-rename-" + journal.id.uuidString + "-") }),
              Set(journal.items.map(\.original)).count == journal.items.count,
              Set(journal.items.map(\.destination)).count == journal.items.count,
              Set(journal.items.map(\.temporary)).count == journal.items.count,
              Set(journal.items.map(\.identity)).count == journal.items.count,
              journal.folderPath.hasPrefix("/"),
              ["prepared", "staged", "committed", "rollingBack", "complete"].contains(journal.phase),
              journal.items.allSatisfy({ URL(fileURLWithPath: $0.original).pathExtension == URL(fileURLWithPath: $0.destination).pathExtension }) else { throw RenameProblem(message: "복구 기록 형식이 올바르지 않습니다: " + url.path) }
        let allowedTags = Set(journal.items.flatMap { item in [item.original, item.destination, item.temporary].map { TagStore.key(URL(fileURLWithPath: journal.folderPath).appendingPathComponent($0)) } })
        guard Set(journal.tagSnapshot).isSubset(of: allowedTags) else { throw RenameProblem(message: "복구 기록의 태그 경로 범위가 올바르지 않습니다.") }
        let volume = Self.volume(folder)
        let samePath = TagStore.key(URL(fileURLWithPath: journal.folderPath)) == TagStore.key(folder)
        let sameVolumeFolder = journal.volumeUUID != nil && journal.relativeFolder != nil && journal.volumeUUID == volume.0 && journal.relativeFolder == volume.1
        guard samePath || sameVolumeFolder else { throw RenameProblem(message: "이 폴더의 복구 기록이 아닙니다.") }
        if let originalVolume = journal.volumeUUID, originalVolume != volume.0 { throw RenameProblem(message: "원래 저장장치와 볼륨 식별자가 다릅니다. 파일을 변경하지 않았습니다.") }
        return journal
    }
    func pending(in folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: journalDirectory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let volume = Self.volume(folder)
        var result: [URL] = []
        for url in urls {
            let journal: RenameJournal
            do { journal = try JSONDecoder().decode(RenameJournal.self, from: Data(contentsOf: url)) }
            catch { throw RenameProblem(message: "읽을 수 없는 복구 기록이 있습니다. 기록을 보존했습니다: " + url.path) }
            if journal.phase == "complete" { continue }
            if TagStore.key(URL(fileURLWithPath: journal.folderPath)) == TagStore.key(folder) ||
                (journal.volumeUUID != nil && journal.relativeFolder != nil && journal.volumeUUID == volume.0 && journal.relativeFolder == volume.1) {
                _ = try readJournal(url, folder: folder); result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private final class Transaction {
        var journal: RenameJournal
        let url: URL, folder: URL, lease: FolderLease
        let lock: RenameLock
        let move: Move
        var locations: [String: String] = [:]
        var locationErrors: [String] = []
        var locationsVerified = false
        init(journal: RenameJournal, url: URL, folder: URL, lease: FolderLease, lock: RenameLock, move: @escaping Move) {
            self.journal = journal; self.url = url; self.folder = folder; self.lease = lease; self.lock = lock; self.move = move
        }
        func save(_ phase: String) throws {
            journal.phase = phase
            let data = try JSONEncoder().encode(journal)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
        }
        func identityMatches(_ a: RenameIdentity, _ b: RenameIdentity) -> Bool {
            a.inode == b.inode && (a.device == b.device || (journal.volumeUUID != nil && journal.volumeUUID == BatchRenameEngine.volume(folder).0))
        }
        func refresh() throws {
            locationsVerified = false
            let volume = BatchRenameEngine.volume(folder).0
            if let original = journal.volumeUUID, volume != original { throw RenameProblem(message: "원래 저장장치를 확인할 수 없습니다.") }
            let candidates = Set(journal.items.flatMap { [$0.original, $0.destination, $0.temporary] })
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { candidates.contains($0) }
            locations = [:]; locationErrors = []
            let byInode = Dictionary(grouping: journal.items, by: { $0.identity.inode })
            for name in names {
                guard let identity = try? RenameIdentity.read(folder.appendingPathComponent(name)) else { continue }
                for item in byInode[identity.inode, default: []] where identityMatches(identity, item.identity) && [item.original, item.destination, item.temporary].contains(name) {
                    if locations[item.original] != nil { locationErrors.append(item.original + ": 파일 식별이 모호합니다.") }
                    else { locations[item.original] = name }
                }
            }
            if !locationErrors.isEmpty { throw RenameProblem(message: locationErrors.joined(separator: "\n")) }
            locationsVerified = true
        }
        func relocate(_ item: RenameJournal.Item, to name: String) throws {
            guard let current = locations[item.original] else { throw RenameProblem(message: item.original + ": 파일 위치를 확인할 수 없습니다.") }
            if current == name { return }
            let source = folder.appendingPathComponent(current), destination = folder.appendingPathComponent(name)
            guard identityMatches(try RenameIdentity.read(source), item.identity) else { throw RenameProblem(message: item.original + ": 다른 파일로 변경됐습니다.") }
            do { try move(source, destination); locations[item.original] = name }
            catch { throw RenameProblem(message: item.original + " → " + item.destination + ": " + error.localizedDescription) }
        }
        func commit(progress: Progress) throws {
            for (index, item) in journal.items.enumerated() { try relocate(item, to: item.temporary); progress(index + 1, journal.items.count * 2, "임시 이름 준비") }
            try save("staged")
            for (index, item) in journal.items.enumerated() { try relocate(item, to: item.destination); progress(journal.items.count + index + 1, journal.items.count * 2, "새 이름 적용") }
            try save("committed")
        }
        func rollback(progress: Progress) -> [String] {
            var errors: [String] = []
            do { try refresh() } catch { return [error.localizedDescription] }
            try? save("rollingBack")
            for (index, item) in journal.items.enumerated() {
                if locations[item.original] != item.original && locations[item.original] != item.temporary {
                    do { try relocate(item, to: item.temporary) } catch { errors.append(error.localizedDescription) }
                }
                progress(index + 1, journal.items.count * 2, "복구 준비")
            }
            for (index, item) in journal.items.enumerated() {
                if locations[item.original] != item.original {
                    do { try relocate(item, to: item.original) } catch { errors.append(error.localizedDescription) }
                }
                progress(journal.items.count + index + 1, journal.items.count * 2, "원래 이름 복구")
            }
            return errors
        }
        var atOriginal: Bool { locationsVerified && journal.items.allSatisfy { locations[$0.original] == $0.original } }
        var atDestination: Bool { locationsVerified && journal.items.allSatisfy { locations[$0.original] == $0.destination } }
        var mapping: [URL: URL] {
            Dictionary(uniqueKeysWithValues: journal.items.compactMap { item in
                guard let name = locations[item.original] else { return nil }
                return (URL(fileURLWithPath: journal.folderPath).appendingPathComponent(item.original), folder.appendingPathComponent(name))
            })
        }
        var affectedKeys: Set<String> {
            Set(journal.items.flatMap { item in
                [item.original, item.destination, item.temporary].flatMap { name in
                    [TagStore.key(folder.appendingPathComponent(name)), TagStore.key(URL(fileURLWithPath: journal.folderPath).appendingPathComponent(name))]
                }
            })
        }
        var tagsForCurrentLocations: Set<String> {
            let snapshot = Set(journal.tagSnapshot)
            if atOriginal && TagStore.key(folder) == TagStore.key(URL(fileURLWithPath: journal.folderPath)) { return snapshot }
            var result: Set<String> = []
            let current = mapping
            for item in journal.items {
                let old = URL(fileURLWithPath: journal.folderPath).appendingPathComponent(item.original)
                if snapshot.contains(TagStore.key(old)) { result.insert(TagStore.key(current[old] ?? old)) }
            }
            return result
        }
        func finish() throws { try save("complete"); try FileManager.default.removeItem(at: url) }
    }
    private func prepare(_ plan: RenamePlan, tags: Set<String>, lease: FolderLease, lock: RenameLock) throws -> Transaction {
        guard plan.valid, plan.changedCount > 0 else { throw RenameProblem(message: "미리보기의 이름 충돌을 해결하거나 변경 규칙을 입력하세요.") }
        if let expected = plan.volumeUUID, expected != Self.volume(plan.folder).0 { throw RenameProblem(message: "미리보기 이후 저장장치가 달라졌습니다. 파일을 변경하지 않았습니다.") }
        guard try pending(in: plan.folder).isEmpty else { throw RenameProblem(message: "중단된 작업을 먼저 복구하세요.") }
        let entries = try BrowserEntry.read(plan.folder, showHidden: true)
        let current = Set(entries.filter(RenamePlan.isTargetPhoto).map { $0.url.lastPathComponent })
        let expected = Set(plan.rows.map(\.original))
        guard (plan.selectedOnly ? expected.isSubset(of: current) : current == expected) else { throw RenameProblem(message: "폴더의 사진 목록이 변경됐습니다. 미리보기를 다시 여세요.") }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: plan.folder.path))
        let sourceNames = Set(plan.rows.map(\.original))
        let occupied = Set(names.filter { !sourceNames.contains($0) }.map(RenamePlan.folded))
        guard !plan.rows.contains(where: { occupied.contains(RenamePlan.folded($0.proposed)) }) else { throw RenameProblem(message: "새 파일/폴더와 이름이 충돌합니다. 덮어쓰지 않았습니다.") }
        for row in plan.rows {
            guard let snapshot = plan.snapshots[row.original],
                  try RenameSourceSnapshot.read(plan.folder.appendingPathComponent(row.original)) == snapshot else {
                throw RenameProblem(message: row.original + ": 미리보기 이후 파일의 식별자나 내용/수정 상태가 변경됐습니다. 다시 확인하세요.")
            }
        }
        let id = UUID(); var identities: Set<RenameIdentity> = []
        let items = try plan.rows.filter { $0.original != $0.proposed }.enumerated().map { index, row -> RenameJournal.Item in
            let source = plan.folder.appendingPathComponent(row.original)
            let identity = try RenameIdentity.read(source)
            guard identities.insert(identity).inserted else { throw RenameProblem(message: "같은 실제 파일을 가리키는 하드 링크는 안전한 복구 식별을 위해 지원하지 않습니다.") }
            let ext = source.pathExtension
            return RenameJournal.Item(original: row.original, destination: row.proposed, temporary: ".J-S-rename-" + id.uuidString + "-\(index)." + ext, identity: identity)
        }
        let volume = Self.volume(plan.folder)
        let keys = Set(items.flatMap { [$0.original, $0.destination, $0.temporary].map { TagStore.key(plan.folder.appendingPathComponent($0)) } })
        let journal = RenameJournal(version: 1, id: id, folderPath: plan.folder.standardizedFileURL.path, volumeUUID: volume.0,
            relativeFolder: volume.1, orderTitle: plan.orderTitle, items: items, tagSnapshot: tags.intersection(keys).sorted(), phase: "prepared")
        let transaction = Transaction(journal: journal, url: journalDirectory.appendingPathComponent(id.uuidString + ".json"), folder: plan.folder, lease: lease, lock: lock, move: move)
        try transaction.refresh(); try transaction.save("prepared"); return transaction
    }
    private func progressHandler(_ callback: @escaping Progress) -> Progress {
        var last = TimeInterval(0), lastPhase = ""
        return { done, total, phase in
            let now = ProcessInfo.processInfo.systemUptime
            if phase != lastPhase || now - last > 0.05 || done == total { last = now; lastPhase = phase; DispatchQueue.main.async { callback(done, total, phase) } }
        }
    }
    func execute(_ plan: RenamePlan, tagStore: TagStore, lease: FolderLease, progress: @escaping Progress, completion: @escaping (RenameOutcome) -> Void) {
        start(folder: plan.folder, tagStore: tagStore, lease: lease, progress: progress, completion: completion) { lock, tags in
            try self.prepare(plan, tags: tags, lease: lease, lock: lock)
        }
    }
    func recover(_ journalURL: URL, folder: URL, tagStore: TagStore, lease: FolderLease, progress: @escaping Progress, completion: @escaping (RenameOutcome) -> Void) {
        start(folder: folder, tagStore: tagStore, lease: lease, progress: progress, completion: completion, recovering: true) { lock, _ in
            let journal = try self.readJournal(journalURL, folder: folder)
            let transaction = Transaction(journal: journal, url: journalURL, folder: folder, lease: lease, lock: lock, move: self.move)
            try transaction.refresh(); return transaction
        }
    }
    private func start(folder: URL, tagStore: TagStore, lease: FolderLease, progress: @escaping Progress, completion: @escaping (RenameOutcome) -> Void,
                       recovering: Bool = false, make: @escaping (RenameLock, Set<String>) throws -> Transaction) {
        queue.async {
            do {
                let lock = try RenameLock(directory: self.journalDirectory)
                tagStore.load { result in
                    self.queue.async {
                        do {
                            let transaction = try make(lock, result.get())
                            let report = self.progressHandler(progress)
                            var failure: String?
                            if recovering {
                                if !transaction.atDestination { failure = transaction.rollback(progress: report).joined(separator: "\n") }
                            } else {
                                do { try transaction.commit(progress: report) }
                                catch { failure = error.localizedDescription; let errors = transaction.rollback(progress: report); if !errors.isEmpty { failure! += "\n" + errors.joined(separator: "\n") } }
                            }
                            self.reconcile(transaction, tagStore: tagStore, failure: failure, recovering: recovering, progress: report, completion: completion)
                        } catch {
                            withExtendedLifetime(lock) { DispatchQueue.main.async { completion(RenameOutcome(completed: false, restored: false, mapping: [:], taggedPaths: nil, message: error.localizedDescription, journalURL: nil)) } }
                        }
                    }
                }
            } catch { DispatchQueue.main.async { completion(RenameOutcome(completed: false, restored: false, mapping: [:], taggedPaths: nil, message: error.localizedDescription, journalURL: nil)) } }
        }
    }
    private func reconcile(_ transaction: Transaction, tagStore: TagStore, failure: String?, recovering: Bool, progress: @escaping Progress, completion: @escaping (RenameOutcome) -> Void) {
        var beforeTags = failure
        do { try transaction.refresh() } catch { beforeTags = (beforeTags ?? "") + "\n파일 위치 확인 실패: " + error.localizedDescription }
        let verifiedFailure = beforeTags
        progress(0, 1, "태그 연결 저장")
        tagStore.updatePaths(removing: transaction.affectedKeys, adding: transaction.tagsForCurrentLocations, force: recovering) { result in
            self.queue.async {
                var message = verifiedFailure ?? ""
                do { try transaction.refresh() } catch { message += "\n완료 전 파일 위치 확인 실패: " + error.localizedDescription }
                var complete = verifiedFailure == nil && transaction.atDestination
                let restored = transaction.atOriginal
                if !complete && !restored && message.isEmpty { message = "일부 파일 위치가 달라졌습니다. 복구 기록을 유지합니다." }
                var paths: Set<String>?
                switch result {
                case .success(let value): paths = value
                case .failure(let error):
                    complete = false; message += "\n태그 저장 실패: " + error.localizedDescription
                    // Restore filenames too if a new-name tag commit failed.
                    if transaction.atDestination && !recovering {
                        let errors = transaction.rollback(progress: progress)
                        self.reconcile(transaction, tagStore: tagStore, failure: message + "\n" + errors.joined(separator: "\n"), recovering: true, progress: progress, completion: completion)
                        return
                    }
                }
                var journalURL: URL? = transaction.url
                if paths != nil && (complete || restored) {
                    do { try transaction.finish(); journalURL = nil } catch { message += "\n복구 기록 정리 실패: " + error.localizedDescription }
                }
                if recovering && restored && paths != nil { message = "원래 이름과 태그를 복구했습니다." + (message.isEmpty ? "" : "\n" + message) }
                if complete { message = "이름 변경과 태그 저장이 완료됐습니다." + (message.isEmpty ? "" : "\n" + message) }
                if !complete && restored && !recovering { message += "\n변경을 취소하고 원래 파일명을 복구했습니다." }
                if let journalURL { message += "\n미완료 작업 기록 보존: " + journalURL.path }
                let outcome = RenameOutcome(completed: complete, restored: restored, mapping: transaction.mapping, taggedPaths: paths, message: message, journalURL: journalURL)
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }
}
