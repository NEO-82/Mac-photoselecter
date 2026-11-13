import AppKit
import ImageIO

struct DecodedImage {
    enum Provenance: Equatable { case jpegOriginal, embeddedJPEG }
    let image: CGImage
    // The geometry of the pixels actually displayed, never the larger RAW sensor.
    let sourceSize: CGSize
    let fullResolution: Bool
    let raw: Bool
    let sensorSize: CGSize?
    let provenance: Provenance
    let colorSpaceDescription: String?

    init(image: CGImage, sourceSize: CGSize, fullResolution: Bool, raw: Bool,
         sensorSize: CGSize? = nil, provenance: Provenance? = nil, colorSpaceDescription: String? = nil) {
        self.image = image; self.sourceSize = sourceSize; self.fullResolution = fullResolution; self.raw = raw
        self.sensorSize = sensorSize; self.provenance = provenance ?? (raw ? .embeddedJPEG : .jpegOriginal)
        self.colorSpaceDescription = colorSpaceDescription
    }
    var qualityDescription: String {
        let pixels = "\(image.width) × \(image.height)"
        if raw {
            let limitation = !fullResolution ? " · RAW 원본 해상도 아님 · 초점 판별 제한" : ""
            return "카메라 내장 JPEG \(pixels) · 100%는 JPEG 실제 픽셀" + limitation
        }
        return "JPEG \(pixels) · " + (fullResolution ? "원본 실제 픽셀" : "썸네일")
    }
}

// A strict LRU budget. The selected display bitmap can be pinned separately:
// it is the same object the UI already retains and is outside this cache budget.
final class BitmapCache {
    private let lock = NSLock()
    private var entries: [String: (value: DecodedImage, cost: Int, age: UInt64)] = [:]
    private var total = 0
    private var clock: UInt64 = 0
    private var limit: Int
    private var pinnedKey: String?
    private var pinnedValue: DecodedImage?
    init(limit: Int = 512 * 1024 * 1024) { self.limit = max(0, limit) }
    func value(for key: String) -> DecodedImage? {
        lock.lock(); defer { lock.unlock() }
        if key == pinnedKey { return pinnedValue }
        guard let entry = entries[key] else { return nil }
        clock &+= 1; entries[key] = (entry.value, entry.cost, clock)
        return entry.value
    }
    func insert(_ value: DecodedImage, for key: String) {
        lock.lock(); defer { lock.unlock() }
        insertLocked(value, for: key)
    }
    private func insertLocked(_ value: DecodedImage, for key: String) {
        if key == pinnedKey { pinnedValue = value; return }
        let cost = value.image.bytesPerRow * value.image.height
        guard cost <= limit else { return }
        if let old = entries.removeValue(forKey: key) { total -= old.cost }
        while total + cost > limit || entries.count >= 256 {
            guard let oldest = entries.min(by: { $0.value.age < $1.value.age })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            total -= removed.cost
        }
        clock &+= 1; entries[key] = (value, cost, clock); total += cost
    }
    func pin(_ key: String?) {
        lock.lock(); defer { lock.unlock() }
        guard pinnedKey != key else { return }
        let oldKey = pinnedKey, oldValue = pinnedValue
        pinnedKey = key; pinnedValue = nil
        if let key, let entry = entries.removeValue(forKey: key) {
            total -= entry.cost; pinnedValue = entry.value
        }
        if let oldKey, let oldValue { insertLocked(oldValue, for: oldKey) }
    }
    var residentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return total + (pinnedValue.map { $0.image.bytesPerRow * $0.image.height } ?? 0)
    }
    func setBudget(_ bytes: Int) { lock.lock(); limit = max(0, bytes); lock.unlock() }
    func trim(to bytes: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let bytes { limit = max(0, bytes) }
        entries.removeAll(); total = 0
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); total = 0; pinnedKey = nil; pinnedValue = nil
    }
}

// Avoid rescanning a RAW container when a large decoded bitmap has been evicted.
// This is compressed JPEG data, limited by both bytes and number of entries.
private final class EmbeddedSourceCache {
    private let lock = NSLock()
    private var entries: [URL: (value: EmbeddedJPEG, age: UInt64)] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private let limit = 128 * 1024 * 1024
    func value(for url: URL) -> EmbeddedJPEG? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url] else { return nil }
        clock &+= 1; entries[url] = (entry.value, clock); return entry.value
    }
    func insert(_ value: EmbeddedJPEG, for url: URL) {
        guard value.data.count <= limit else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: url) { bytes -= old.value.data.count }
        while bytes + value.data.count > limit {
            guard let key = entries.min(by: { $0.value.age < $1.value.age })?.key,
                  let old = entries.removeValue(forKey: key) else { break }
            bytes -= old.value.data.count
        }
        clock &+= 1; entries[url] = (value, clock); bytes += value.data.count
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); bytes = 0
    }
}

final class ImagePipeline {
    enum Quality: String { case thumbnail, preview, full }
    typealias Decoder = (URL, Quality) throws -> DecodedImage
    private struct Subscriber {
        let ticket: Operation
        let completion: (Result<DecodedImage, Error>, Bool) -> Void
    }
    private final class Work {
        var operation = BlockOperation()
        var started = false
        let url: URL
        let epoch: UInt64
        let queuedAt = ProcessInfo.processInfo.systemUptime
        var subscribers: [Subscriber] = []
        var prefetch = false
        var foreground = false
        init(url: URL, epoch: UInt64) { self.url = url; self.epoch = epoch }
    }
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated; return q
    }()
    private let speculative: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility; return q
    }()
    private let lock = NSLock()
    private var works: [String: Work] = [:]
    private var epoch: UInt64 = 0
    private let cache: BitmapCache
    private let normalCacheLimit: Int
    private let embedded = EmbeddedSourceCache()
    private let injectedDecoder: Decoder?

    private var pressure: DispatchSourceMemoryPressure?
    private let metricsLock = NSLock()
    private var measurements: [[String: Double]] = []
    private var hits = 0, misses = 0
    static var defaultCacheLimit: Int { Int(min(ProcessInfo.processInfo.physicalMemory / 8, 1536 * 1024 * 1024)) }
    var diagnostics: [String: Any] {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return ["hits": hits, "misses": misses, "residentBitmapBytes": cache.residentBytes, "stages": measurements]
    }
    private func measure(_ values: [String: Double]) {
        metricsLock.lock(); defer { metricsLock.unlock() }
        measurements.append(values)
        if measurements.count > 256 { measurements.removeFirst() }
    }
    func handleMemoryPressure() {
        lock.lock(); defer { lock.unlock() }
        cache.trim(to: normalCacheLimit / 4); embedded.clear()
        for key in works.compactMap({ !$0.value.foreground && !$0.value.started ? $0.key : nil }) {
            if let work = works.removeValue(forKey: key) { work.operation.cancel() }
        }
    }
    init(cacheLimit: Int = ImagePipeline.defaultCacheLimit, foregroundConcurrency: Int = 2, decoder: Decoder? = nil) {
        normalCacheLimit = cacheLimit
        cache = BitmapCache(limit: cacheLimit); injectedDecoder = decoder
        queue.maxConcurrentOperationCount = max(1, foregroundConcurrency)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.pressure?.data.contains(.normal) == true { self.cache.setBudget(self.normalCacheLimit) }
            else { self.handleMemoryPressure() }
        }
        source.resume(); pressure = source
    }
    deinit { pressure?.cancel() }
    private func key(_ photo: Photo, _ quality: Quality) -> String {
        photo.url.standardizedFileURL.path + (quality == .thumbnail ? "|thumbnail" : "|display")
    }
    func cached(_ photo: Photo, quality: Quality) -> DecodedImage? {
        let value = cache.value(for: key(photo, quality))
        metricsLock.lock(); if value != nil { hits += 1 } else { misses += 1 }; metricsLock.unlock()
        return value
    }

    // Keep the selected image first. Preserve and promote in-flight neighbors;
    // cancel only work outside the current navigation window, not every switch.
    func retain(photos: [Photo]) {
        let urls = Set(photos.map(\.url))
        lock.lock()
        for key in works.compactMap({ urls.contains($0.value.url) ? nil : $0.key }) {
            if let work = works[key] {
                // Running synchronous decoders stay registered for sharing on reversal.
                // Obsolete queued work is removed before it can compete with the selection.
                work.subscribers.forEach { $0.ticket.cancel() }
                if !work.started { works.removeValue(forKey: key); work.operation.cancel() }
            }
        }
        cache.pin(photos.first.map { key($0, .preview) })
        lock.unlock()
    }
    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        works.values.forEach { work in
            work.operation.cancel(); work.subscribers.forEach { $0.ticket.cancel() }
        }
        works.removeAll()
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        works.values.forEach { work in
            work.operation.cancel(); work.subscribers.forEach { $0.ticket.cancel() }
        }
        works.removeAll(); cache.clear(); embedded.clear()
    }

    @discardableResult
    func load(_ photo: Photo, lease: FolderLease, quality: Quality, prefetch: Bool = false,
              completion: @escaping (Result<DecodedImage, Error>, Bool) -> Void) -> Operation? {
        let cacheKey = key(photo, quality)
        lock.lock()
        if let value = cache.value(for: cacheKey) {
            metricsLock.lock(); hits += 1; metricsLock.unlock()
            let generation = epoch
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let valid = self.epoch == generation; self.lock.unlock()
                if valid { completion(.success(value), true) }
            }
            return nil
        }
        metricsLock.lock(); misses += 1; metricsLock.unlock()
        // A subscriber owns its cancellation ticket, not a shared decoder.
        let ticket = BlockOperation()
        let subscriber = Subscriber(ticket: ticket, completion: completion)
        if let existing = works[cacheKey], !existing.operation.isCancelled {
            existing.subscribers.append(subscriber)
            existing.foreground = existing.foreground || !prefetch
            existing.prefetch = existing.prefetch || prefetch
            if !prefetch && !existing.started && existing.prefetch {
                // Move a queued prefetch to the foreground lane without duplicating decode.
                existing.operation.cancel()
                let promoted = BlockOperation()
                existing.operation = promoted
                promoted.queuePriority = .veryHigh
                promoted.qualityOfService = .userInitiated
                promoted.addExecutionBlock { [weak self, weak existing] in
                    guard let self, let existing else { return }
                    self.execute(existing, cacheKey: cacheKey, lease: lease, quality: quality)
                }
                lock.unlock(); queue.addOperation(promoted); return ticket
            }
            if !prefetch {
                existing.operation.queuePriority = .veryHigh
                existing.operation.qualityOfService = .userInitiated
            }
            lock.unlock(); return ticket
        }
        let work = Work(url: photo.url, epoch: epoch)
        work.subscribers = [subscriber]; work.prefetch = prefetch; work.foreground = !prefetch
        work.operation.queuePriority = prefetch ? .veryLow : .veryHigh
        works[cacheKey] = work
        let decodeQuality: Quality = quality == .thumbnail ? .thumbnail : .preview
        work.operation.addExecutionBlock { [weak self, weak work] in
            guard let self, let work else { return }
            self.execute(work, cacheKey: cacheKey, lease: lease, quality: decodeQuality)
        }
        lock.unlock()
        (prefetch ? speculative : queue).addOperation(work.operation)
        return ticket
    }
    private func execute(_ work: Work, cacheKey: String, lease: FolderLease, quality: Quality) {
        lock.lock()
        guard !work.started, !work.operation.isCancelled, works[cacheKey] === work else { lock.unlock(); return }
        let interested = work.prefetch || work.subscribers.contains { !$0.ticket.isCancelled }
        guard interested else { works.removeValue(forKey: cacheKey); lock.unlock(); return }
        work.started = true
        lock.unlock()
        let start = ProcessInfo.processInfo.systemUptime
        let result: Result<DecodedImage, Error> = withExtendedLifetime(lease) {
            autoreleasepool { Result { try injectedDecoder?(work.url, quality == .thumbnail ? .thumbnail : .preview) ?? decode(work.url, quality: quality == .thumbnail ? .thumbnail : .preview, generation: work.epoch) } }
        }
        measure(["totalDecodeMs": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                 "queueWaitMs": (start - work.queuedAt) * 1000])
        lock.lock()
        let valid = epoch == work.epoch
        if valid, case .success(let image) = result { cache.insert(image, for: cacheKey) }
        let subscribers = work.subscribers
        if works[cacheKey] === work { works.removeValue(forKey: cacheKey) }
        lock.unlock()
        guard valid else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.epoch == work.epoch; self.lock.unlock()
            guard current, !work.operation.isCancelled else { return }
            for subscriber in subscribers where !subscriber.ticket.isCancelled { subscriber.completion(result, false) }
        }
    }

    private func decode(_ url: URL, quality: Quality, generation: UInt64) throws -> DecodedImage {
        let raw = url.pathExtension.lowercased() == "arw"
        let source: CGImageSource
        let embeddedJPEG: EmbeddedJPEG?
        let jpegData: Data
        let extractionStart = ProcessInfo.processInfo.systemUptime
        var sourceHit = false
        if raw {
            let jpeg: EmbeddedJPEG
            if let cached = embedded.value(for: url) { jpeg = cached; sourceHit = true }
            else {
                jpeg = try EmbeddedPreview.extract(from: url)
                lock.lock()
                if epoch == generation { embedded.insert(jpeg, for: url) }
                lock.unlock()
            }
            embeddedJPEG = jpeg; jpegData = jpeg.data
            guard let jpegSource = CGImageSourceCreateWithData(jpeg.data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { throw failure("내장 JPEG 프리뷰를 읽을 수 없습니다.") }
            source = jpegSource
        } else {
            embeddedJPEG = nil
            jpegData = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let jpegSource = CGImageSourceCreateWithData(jpegData as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { throw failure("파일을 읽을 수 없습니다: \(url.lastPathComponent)") }
            source = jpegSource
        }
        let extractionMs = (ProcessInfo.processInfo.systemUptime - extractionStart) * 1000
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= 100_000_000 / height else { throw failure("이미지 크기가 잘못되었거나 지원 범위를 초과합니다.") }
        let jpegOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let orientation = jpegOrientation.flatMap { (1...8).contains($0) ? $0 : nil } ?? embeddedJPEG?.orientation ?? 1
        let image: CGImage
        if quality == .thumbnail {
            // Force the JPEG's primary image, never its differently profiled EXIF
            // thumbnail. The exact same JPEG+ICC is used by the display decoder.
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false, kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw failure("JPEG 썸네일 디코딩 실패") }
            image = decoded
        } else {
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw failure("JPEG 디코딩 실패") }
            image = decoded
        }
        let hasICC = Self.hasICCProfile(jpegData)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let jpegColorSpace = (exif?[kCGImagePropertyExifColorSpace] as? NSNumber)?.intValue
        let sourceSpace: CGColorSpace?
        let colorDescription: String
        if hasICC {
            sourceSpace = nil; colorDescription = "JPEG ICC → sRGB"
        } else if jpegColorSpace == 1 {
            sourceSpace = CGColorSpace(name: CGColorSpace.sRGB); colorDescription = "sRGB"
        } else if jpegColorSpace == 65535,
                  (image.colorSpace?.name as String?) == (CGColorSpace.adobeRGB1998 as String) {
            sourceSpace = CGColorSpace(name: CGColorSpace.adobeRGB1998); colorDescription = "Adobe RGB → sRGB"
        } else if embeddedJPEG?.colorSpaceHint == .adobeRGB {
            sourceSpace = CGColorSpace(name: CGColorSpace.adobeRGB1998); colorDescription = "Adobe RGB → sRGB"
        } else if embeddedJPEG?.colorSpaceHint == .sRGB {
            sourceSpace = CGColorSpace(name: CGColorSpace.sRGB); colorDescription = "sRGB"
        } else {
            sourceSpace = CGColorSpace(name: CGColorSpace.sRGB); colorDescription = "색공간 정보 없음 · sRGB 가정"
        }
        let jpegMs = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000
        let normalizeStart = ProcessInfo.processInfo.systemUptime
        let normalized = try Self.normalized(image, orientation: orientation, sourceSpace: sourceSpace)
        measure(["sourceReadExtractMs": extractionMs, "imageIOCreateMs": jpegMs,
                 "rasterizeIncludingDeferredJPEGMs": (ProcessInfo.processInfo.systemUptime - normalizeStart) * 1000,
                 "compressedCacheHit": sourceHit ? 1 : 0])
        let sensor = embeddedJPEG?.sensorSize.map { size in
            (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
        }
        let parity = sensor.map { Int($0.width) == normalized.width && Int($0.height) == normalized.height } ?? false
        return DecodedImage(image: normalized, sourceSize: CGSize(width: normalized.width, height: normalized.height),
            fullResolution: quality != .thumbnail && (!raw || parity), raw: raw, sensorSize: sensor,
            provenance: raw ? .embeddedJPEG : .jpegOriginal, colorSpaceDescription: colorDescription)
    }

    // Both thumbnail and full display pass through this same color conversion.
    // Tagged JPEG ICC profiles are respected; untagged device RGB assumes sRGB.
    private static func normalized(_ image: CGImage, orientation: UInt32, sourceSpace: CGColorSpace?) throws -> CGImage {
        let w = image.width, h = image.height
        let rotated = (5...8).contains(orientation)
        let outW = rotated ? h : w, outH = rotated ? w : h
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                bytesPerRow: outW * 4, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw failure("이미지 메모리를 준비할 수 없습니다.")
        }
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(w), ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(w), ty: CGFloat(h))
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h))
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: CGFloat(h), ty: CGFloat(w))
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w))
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0)
        default: transform = .identity
        }
        context.concatenate(transform)
        context.interpolationQuality = .high
        let tagged = sourceSpace.flatMap { image.copy(colorSpace: $0) } ?? image
        context.draw(tagged, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.makeImage() else { throw failure("JPEG 색상 변환 실패") }
        return result
    }
    private static func hasICCProfile(_ data: Data) -> Bool {
        // ICC metadata is authoritative only in a JPEG APP2 segment, not a
        // coincidental byte sequence elsewhere in compressed image payload.
        guard data.count >= 4, data[0] == 0xff, data[1] == 0xd8 else { return false }
        var offset = 2
        let signature = Array("ICC_PROFILE\0".utf8)
        while offset + 4 <= data.count {
            guard data[offset] == 0xff else { return false }
            let marker = data[offset + 1]
            if marker == 0xda || marker == 0xd9 { return false }
            if marker == 0xff { offset += 1; continue }
            let length = Int(data[offset + 2]) * 256 + Int(data[offset + 3])
            guard length >= 2, length <= data.count - offset - 2 else { return false }
            if marker == 0xe2, length >= signature.count + 2,
               Array(data[(offset + 4)..<(offset + 4 + signature.count)]) == signature { return true }
            offset += length + 2
        }
        return false
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoSelect", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func failure(_ message: String) -> NSError { Self.failure(message) }
}
