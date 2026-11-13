import Foundation
import ImageIO

enum PhotoSortCriterion: String, CaseIterable {
    case name, captured, size
    var title: String { switch self { case .name: return "파일 이름순"; case .captured: return "촬영 시간순"; case .size: return "크기순" } }
}
struct PhotoSortOrder: Equatable {
    var criterion: PhotoSortCriterion = .name
    var ascending = true
    mutating func choose(_ criterion: PhotoSortCriterion) {
        if self.criterion == criterion { ascending.toggle() }
        else { self.criterion = criterion; ascending = true }
    }
    var title: String { criterion.title + (ascending ? " ↑" : " ↓") }
    static func nameBefore(_ a: BrowserEntry, _ b: BrowserEntry) -> Bool {
        let result = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
        if result != .orderedSame { return result == .orderedAscending }
        return a.url.lastPathComponent < b.url.lastPathComponent
    }
    func photos(_ entries: [BrowserEntry]) -> [BrowserEntry] {
        entries.filter(\.isPhoto).sorted { a, b in
            switch criterion {
            case .name:
                return ascending ? Self.nameBefore(a, b) : Self.nameBefore(b, a)
            case .captured:
                if a.capturedAt != b.capturedAt {
                    guard let aDate = a.capturedAt else { return false }
                    guard let bDate = b.capturedAt else { return true }
                    return ascending ? aDate < bDate : aDate > bDate
                }
            case .size:
                if a.fileBytes != b.fileBytes {
                    guard let aSize = a.fileBytes else { return false }
                    guard let bSize = b.fileBytes else { return true }
                    return ascending ? aSize < bSize : aSize > bSize
                }
            }
            return Self.nameBefore(a, b)
        }
    }
    // Keep folders/documents in their existing slots and relative order.
    func arrange(_ entries: [BrowserEntry]) -> [BrowserEntry] {
        let sorted = photos(entries); var index = 0
        return entries.map { entry in
            guard entry.isPhoto else { return entry }
            defer { index += 1 }; return sorted[index]
        }
    }
}

// Metadata-only ImageIO calls. No CGImage is created and no RAW pixels are decoded.
final class PhotoSortMetadata {
    private struct Value { let size: Int64?; let modified: Date?; let date: Date? }
    private let reader: (URL) -> Date?
    init(reader: @escaping (URL) -> Date? = PhotoSortMetadata.captureDate) { self.reader = reader }
    private var cache: [String: Value] = [:] // accessed only on queue
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility; return queue
    }()
    func clear() { queue.addBarrierBlock { [weak self] in self?.cache.removeAll() } }
    func remapFiles(_ mapping: [URL: URL]) {
        queue.addBarrierBlock { [weak self] in
            guard let self else { return }
            let old = self.cache
            let keys = Dictionary(uniqueKeysWithValues: mapping.map { (TagStore.key($0.key), TagStore.key($0.value)) })
            let targets = Set(keys.values)
            self.cache = old.filter { keys[$0.key] == nil && !targets.contains($0.key) }
            for (from, to) in keys { if let value = old[from] { self.cache[to] = value } }
        }
    }
    static func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        guard let text = original ?? exif[kCGImagePropertyExifDateTimeDigitized as String] as? String else { return nil }
        // TIFF DateTime is an edit timestamp, not a reliable capture time.
        let offsetKey = original != nil ? "OffsetTimeOriginal" : "OffsetTimeDigitized"
        let subsecondKey = original != nil ? "SubsecTimeOriginal" : "SubsecTimeDigitized"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let offset = exif[offsetKey] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: text + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"; formatter.isLenient = false
        guard var date = formatter.date(from: text) else { return nil }
        if let sub = exif[subsecondKey] as? String, let fraction = Double("0." + sub) { date.addTimeInterval(fraction) }
        return date
    }
    @discardableResult
    func prepare(_ entries: [BrowserEntry], order: PhotoSortOrder = PhotoSortOrder(criterion: .captured, ascending: true), lease: FolderLease, completion: @escaping ([BrowserEntry]) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation else { return }
            var result = entries
            for index in result.indices where order.criterion == .captured && result[index].isPhoto {
                if operation.isCancelled { return }
                autoreleasepool {
                    var url = result[index].url; url.removeAllCachedResourceValues()
                    let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = attributes?.fileSize.map(Int64.init), modified = attributes?.contentModificationDate
                    let key = TagStore.key(url)
                    let date: Date?
                    if let cached = self.cache[key], cached.size == size, cached.modified == modified { date = cached.date }
                    else {
                        date = withExtendedLifetime(lease) { self.reader(url) }
                        self.cache[key] = Value(size: size, modified: modified, date: date)
                    }
                    result[index].capturedAt = date; result[index].fileBytes = size
                }
            }
            if self.cache.count > 12_000 { self.cache.removeAll() }
            let prepared = order.arrange(result)
            DispatchQueue.main.async { if !operation.isCancelled { completion(prepared) } }
        }
        queue.addOperation(operation); return operation
    }
}
