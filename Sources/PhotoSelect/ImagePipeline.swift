import AppKit
import ImageIO
import CoreImage

struct DecodedImage {
    let image: CGImage
    let sourceSize: CGSize
    let fullResolution: Bool
    let raw: Bool
}

// A strict decoded-bitmap budget, excluding current display and in-flight system decoders.
final class BitmapCache {
    private let lock = NSLock()
    private var entries: [String: (value: DecodedImage, cost: Int, age: UInt64)] = [:]
    private var total = 0
    private var clock: UInt64 = 0
    private let limit = 192 * 1024 * 1024
    func value(for key: String) -> DecodedImage? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        clock &+= 1; entries[key] = (entry.value, entry.cost, clock)
        return entry.value
    }
    func insert(_ value: DecodedImage, for key: String) {
        let cost = value.image.bytesPerRow * value.image.height
        guard cost <= limit else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { total -= old.cost }
        while total + cost > limit || entries.count >= 256 {
            guard let oldest = entries.min(by: { $0.value.age < $1.value.age })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            total -= removed.cost
        }
        clock &+= 1; entries[key] = (value, cost, clock); total += cost
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); total = 0
    }
}

final class ImagePipeline {
    enum Quality: String { case thumbnail, preview, full }
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated; return q
    }()
    private let cache = BitmapCache()
    private let context = CIContext(options: [.cacheIntermediates: false])
    func cancelAll() { queue.cancelAllOperations() }
    func clear() { cancelAll(); cache.clear() }

    @discardableResult
    func load(_ photo: Photo, lease: FolderLease, quality: Quality, prefetch: Bool = false,
              completion: @escaping (Result<DecodedImage, Error>, Bool) -> Void) -> Operation? {
        let key = photo.url.path + "|" + quality.rawValue
        if let value = cache.value(for: key) {
            DispatchQueue.main.async { completion(.success(value), true) }; return nil
        }
        let operation = BlockOperation()
        operation.queuePriority = prefetch ? .veryLow : .veryHigh
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation, !operation.isCancelled else { return }
            withExtendedLifetime(lease) {
                let result: Result<DecodedImage, Error> = autoreleasepool {
                    Result { try self.decode(photo.url, quality: quality) }
                }
                guard !operation.isCancelled else { return }
                if case .success(let decoded) = result {
                    self.cache.insert(decoded, for: key)
                }
                DispatchQueue.main.async {
                    guard !operation.isCancelled else { return }
                    completion(result, false)
                }
            }
        }
        queue.addOperation(operation)
        return operation
    }

    private func decode(_ url: URL, quality: Quality) throws -> DecodedImage {
        let raw = url.pathExtension.lowercased() == "arw"
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw failure("파일을 읽을 수 없습니다: \(url.lastPathComponent)")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let rotated = (5...8).contains(Int(orientation))
        let size = CGSize(width: rotated ? height : width, height: rotated ? width : height)
        if quality == .full && raw {
            // CIRAWFilter availability depends on macOS and the camera's RAW variant.
            guard let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage,
                  let image = context.createCGImage(output, from: output.extent) else {
                throw failure("이 ARW의 고해상도 RAW 렌더링을 지원하지 않습니다. 프리뷰만 표시합니다.")
            }
            return DecodedImage(image: image, sourceSize: CGSize(width: image.width, height: image.height),
                                fullResolution: true, raw: true)
        }
        let maxPixel = quality == .thumbnail ? 320 : quality == .preview ? 2560 : max(width, height)
        var options: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        // First ask only for an existing embedded thumbnail. Its presence/size is not guaranteed.
        options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
        var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        let wanted = min(maxPixel, max(width, height))
        if image == nil || (!raw && Double(max(image!.width, image!.height)) < wanted) {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        // ImageIO may perform RAW decode here when no embedded preview exists; it runs off-main.
        guard let image else { throw failure("이미지 디코딩 실패 또는 지원하지 않는 ARW: \(url.lastPathComponent)") }
        let full = !raw && width > 0 && height > 0 && image.width >= Int(size.width) && image.height >= Int(size.height)
        return DecodedImage(image: image, sourceSize: size, fullResolution: full, raw: raw)
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoSelect", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
