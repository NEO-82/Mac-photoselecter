import AppKit
import ImageIO
import XCTest
@testable import PhotoSelect

final class ImagePipelineTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func jpeg(width: Int = 1800, height: Int = 1200, adobe: Bool = false) throws -> Data {
        let space = CGColorSpace(name: adobe ? CGColorSpace.adobeRGB1998 : CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.5, 0.3, 0.15, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = CFDataCreateMutable(kCFAllocatorDefault, 0)!
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func withoutJPEGMetadata(_ data: Data) -> Data {
        var result = Data(data.prefix(2)), offset = 2
        while offset + 4 <= data.count {
            guard data[offset] == 0xff else { break }
            let marker = data[offset + 1]
            if marker == 0xda { result.append(data[offset...]); return result }
            let length = Int(data[offset + 2]) * 256 + Int(data[offset + 3])
            guard length >= 2, length + 2 <= data.count - offset else { break }
            if marker != 0xe1 && marker != 0xe2 { result.append(data[offset..<(offset + length + 2)]) }
            offset += length + 2
        }
        return data
    }
    private func arw(_ jpeg: Data, adobe: Bool = false, orientation: UInt32 = 1,
                     sensorWidth: UInt32 = 4000, sensorHeight: UInt32 = 3000) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(value & 65535)); u16(UInt16(value >> 16)) }
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) { u16(tag); u16(type); u32(count); u32(value) }
        data.append(contentsOf: [0x49, 0x49]); u16(42); u32(8)
        u16(6)
        entry(256, 4, 1, sensorWidth); entry(257, 4, 1, sensorHeight)
        entry(274, 3, 1, orientation); entry(513, 4, 1, 158); entry(514, 4, 1, UInt32(jpeg.count))
        entry(34665, 4, 1, 86); u32(0)
        u16(4)
        entry(0xa001, 3, 1, adobe ? 65535 : 1); entry(0xa002, 4, 1, sensorWidth)
        entry(0xa003, 4, 1, sensorHeight); entry(0xa005, 4, 1, 140); u32(0)
        u16(1); entry(1, 2, 4, adobe ? 0x00333052 : 0x00383952); u32(0)
        XCTAssertEqual(data.count, 158); data.append(jpeg)
        return data
    }
    private func load(_ pipeline: ImagePipeline, _ url: URL, _ quality: ImagePipeline.Quality = .preview) throws -> (DecodedImage, Bool) {
        let done = expectation(description: "decode \(url.lastPathComponent) \(quality.rawValue)")
        var output: Result<DecodedImage, Error>?
        var hit = false
        pipeline.load(Photo(url: url), lease: FolderLease(url.deletingLastPathComponent()), quality: quality) { result, cached in
            XCTAssertTrue(Thread.isMainThread); output = result; hit = cached; done.fulfill()
        }
        withExtendedLifetime(pipeline) { wait(for: [done], timeout: 30) }
        return (try XCTUnwrap(output).get(), hit)
    }
    private func pixel(_ image: CGImage, x: Int? = nil, y: Int? = nil) throws -> [Double] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x ?? image.width / 2, y: y ?? image.height / 2, width: 1, height: 1)))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Double(bytes[$0]) / 255 }
    }
    private func mean(_ image: CGImage) throws -> [Double] {
        let side = 64
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { channel in (0..<(side * side)).reduce(0.0) { $0 + Double(bytes[$1 * 4 + channel]) } / Double(side * side * 255) }
    }
    func testARWUsesSameNativeJPEGForDisplayZoomAndThumbnailColor() throws {
        let root = try folder(), url = root.appendingPathComponent("fixture.ARW")
        try arw(jpeg(), orientation: 6).write(to: url)
        let pipeline = ImagePipeline()
        let (display, _) = try load(pipeline, url)
        let (zoom, hit) = try load(pipeline, url, .full)
        let (thumbnail, _) = try load(pipeline, url, .thumbnail)
        XCTAssertTrue(hit); XCTAssertTrue(display.image === zoom.image)
        XCTAssertEqual(display.image.width, 1200); XCTAssertEqual(display.image.height, 1800)
        XCTAssertEqual(display.sourceSize, CGSize(width: 1200, height: 1800))
        XCTAssertEqual(display.sensorSize, CGSize(width: 3000, height: 4000))
        XCTAssertFalse(display.fullResolution)
        XCTAssertEqual(display.provenance, .embeddedJPEG)
        XCTAssertTrue(display.qualityDescription.contains("RAW 원본 해상도 아님"))
        XCTAssertEqual(display.image.colorSpace?.name as String?, CGColorSpace.sRGB as String)
        let fullPixel = try pixel(display.image), thumbPixel = try pixel(thumbnail.image)
        for channel in 0..<3 { XCTAssertEqual(fullPixel[channel], thumbPixel[channel], accuracy: 0.025) }
    }
    func testOuterAdobeRGBHintIsAppliedBeforeConsistentSRGBConversion() throws {
        let root = try folder(), data = withoutJPEGMetadata(try jpeg())
        let adobe = root.appendingPathComponent("adobe.ARW"), srgb = root.appendingPathComponent("srgb.ARW")
        try arw(data, adobe: true).write(to: adobe); try arw(data).write(to: srgb)
        let pipeline = ImagePipeline()
        let (a, _) = try load(pipeline, adobe), (s, _) = try load(pipeline, srgb)
        let (thumb, _) = try load(pipeline, adobe, .thumbnail)
        XCTAssertEqual(a.colorSpaceDescription, "Adobe RGB → sRGB")
        let ap = try pixel(a.image), sp = try pixel(s.image), tp = try pixel(thumb.image)
        XCTAssertGreaterThan(zip(ap, sp).map { abs($0.0 - $0.1) }.max() ?? 0, 0.02)
        for channel in 0..<3 { XCTAssertEqual(ap[channel], tp[channel], accuracy: 0.025) }
    }
    func testEmbeddedICCOverridesContradictoryOuterColorHint() throws {
        let root = try folder(), data = try jpeg(adobe: true)
        let raw = root.appendingPathComponent("icc.ARW"), original = root.appendingPathComponent("original.jpg")
        try arw(data, adobe: false).write(to: raw); try data.write(to: original)
        let pipeline = ImagePipeline()
        let (a, _) = try load(pipeline, raw), (b, _) = try load(pipeline, original)
        XCTAssertEqual(a.colorSpaceDescription, "JPEG ICC → sRGB")
        let ap = try pixel(a.image), bp = try pixel(b.image)
        for channel in 0..<3 { XCTAssertEqual(ap[channel], bp[channel], accuracy: 0.01) }
    }
    func testJPEGDisplayAndZoomNeverReplaceWithAnotherResolution() throws {
        let root = try folder(), url = root.appendingPathComponent("original.jpg")
        try jpeg(width: 2800, height: 1600).write(to: url)
        let pipeline = ImagePipeline()
        let (display, _) = try load(pipeline, url), (zoom, hit) = try load(pipeline, url, .full)
        XCTAssertTrue(hit); XCTAssertTrue(display.image === zoom.image)
        XCTAssertEqual(display.sourceSize, CGSize(width: 2800, height: 1600)); XCTAssertTrue(display.fullResolution)
    }
    func testAllEightJPEGOrientationsMatchImageIOReferenceGeometry() throws {
        let root = try folder(), space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
            bytesPerRow: 320, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (x, y, rgb) in [(0, 0, [1.0, 0.0, 0.0]), (40, 0, [0.0, 1.0, 0.0]),
                            (0, 20, [0.0, 0.0, 1.0]), (40, 20, [1.0, 1.0, 0.0])] {
            context.setFillColor(CGColor(colorSpace: space, components: rgb.map { CGFloat($0) } + [1])!)
            context.fill(CGRect(x: x, y: y, width: 40, height: 20))
        }
        let sourceImage = try XCTUnwrap(context.makeImage())
        for orientation in 1...8 {
            let data = CFDataCreateMutable(kCFAllocatorDefault, 0)!
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, sourceImage,
                [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let url = root.appendingPathComponent("orientation\(orientation).jpg")
            try (data as Data).write(to: url)
            let image = try load(ImagePipeline(), url).0.image
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
            let reference = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: 80] as CFDictionary))
            XCTAssertEqual(image.width, reference.width); XCTAssertEqual(image.height, reference.height)
            for x in [image.width / 4, image.width * 3 / 4] {
                for y in [image.height / 4, image.height * 3 / 4] {
                    let actual = try pixel(image, x: x, y: y), expected = try pixel(reference, x: x, y: y)
                    for channel in 0..<3 {
                        XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.05, "orientation \(orientation)")
                    }
                }
            }
        }
    }
    func testPrefetchForegroundAndFullRequestsCoalesceWithIndependentCancellation() throws {
        let root = try folder(), url = root.appendingPathComponent("coalesced.jpg")
        let imageData = try jpeg(width: 20, height: 10)
        try imageData.write(to: url)
        let image = try load(ImagePipeline(), url).0
        let entered = expectation(description: "prefetch decoder entered"), done = expectation(description: "foreground completed")
        let release = DispatchSemaphore(value: 0)
        let countLock = NSLock(); var calls = 0; var cancelledCallbacks = 0
        let pipeline = ImagePipeline(decoder: { _, quality in
            XCTAssertEqual(quality, .preview)
            countLock.lock(); calls += 1; countLock.unlock(); entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            return image
        })
        let ticket = pipeline.load(Photo(url: url), lease: FolderLease(root), quality: .preview, prefetch: true) { _, _ in cancelledCallbacks += 1 }
        wait(for: [entered], timeout: 2)
        pipeline.load(Photo(url: url), lease: FolderLease(root), quality: .full) { result, hit in
            XCTAssertFalse(hit); XCTAssertTrue((try? result.get().image) === image.image); done.fulfill()
        }
        ticket?.cancel(); release.signal()
        wait(for: [done], timeout: 3)
        countLock.lock(); let actualCalls = calls; countLock.unlock()
        XCTAssertEqual(actualCalls, 1); XCTAssertEqual(cancelledCallbacks, 0)
        XCTAssertTrue(pipeline.cached(Photo(url: url), quality: .full)?.image === image.image)
    }
    func testCancelledQueuedThumbnailDoesNotDecodeBehindVisibleRequests() throws {
        let root = try folder(), url = root.appendingPathComponent("fixture.jpg")
        try jpeg(width: 20, height: 10).write(to: url)
        let image = try load(ImagePipeline(), url).0
        let occupied = expectation(description: "both decoder slots occupied"); occupied.expectedFulfillmentCount = 2
        let visible = expectation(description: "new visible thumbnail decoded")
        let cancelled = expectation(description: "cancelled thumbnail must not decode"); cancelled.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let pipeline = ImagePipeline(decoder: { url, _ in
            if url.lastPathComponent.hasPrefix("busy") {
                occupied.fulfill(); _ = release.wait(timeout: .now() + 5)
            } else if url.lastPathComponent == "cancelled.jpg" { cancelled.fulfill() }
            return image
        })
        for name in ["busy1.jpg", "busy2.jpg"] {
            pipeline.load(Photo(url: root.appendingPathComponent(name)), lease: FolderLease(root), quality: .thumbnail) { _, _ in }
        }
        wait(for: [occupied], timeout: 2)
        let ticket = pipeline.load(Photo(url: root.appendingPathComponent("cancelled.jpg")), lease: FolderLease(root), quality: .thumbnail) { _, _ in XCTFail("Cancelled callback") }
        ticket?.cancel()
        pipeline.load(Photo(url: root.appendingPathComponent("visible.jpg")), lease: FolderLease(root), quality: .thumbnail) { _, _ in visible.fulfill() }
        release.signal(); release.signal()
        wait(for: [visible], timeout: 3)
        wait(for: [cancelled], timeout: 0.2)
        XCTAssertNil(pipeline.cached(Photo(url: root.appendingPathComponent("cancelled.jpg")), quality: .thumbnail))
    }
    func testClearRejectsFinishedOldWorkAndDoesNotRepopulateCache() throws {
        let root = try folder(), url = root.appendingPathComponent("old.jpg")
        try jpeg(width: 20, height: 10).write(to: url)
        let image = try load(ImagePipeline(), url).0
        let entered = expectation(description: "old decoder entered")
        let unexpected = expectation(description: "old completion rejected"); unexpected.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let pipeline = ImagePipeline(decoder: { _, _ in
            entered.fulfill(); _ = release.wait(timeout: .now() + 5); return image
        })
        pipeline.load(Photo(url: url), lease: FolderLease(root), quality: .preview) { _, _ in unexpected.fulfill() }
        wait(for: [entered], timeout: 2)
        pipeline.clear(); release.signal()
        wait(for: [unexpected], timeout: 0.3)
        XCTAssertNil(pipeline.cached(Photo(url: url), quality: .preview))
    }
    func testPinnedCurrentAndNeighborsUseBoundedLRUWithoutDiscardingSelectedBitmap() throws {
        let root = try folder(), url = root.appendingPathComponent("tiny.jpg")
        try jpeg(width: 20, height: 10).write(to: url)
        let image = try load(ImagePipeline(), url).0
        let cost = image.image.bytesPerRow * image.image.height
        let cache = BitmapCache(limit: cost * 2)
        cache.pin("current"); cache.insert(image, for: "current")
        cache.insert(image, for: "previous"); cache.insert(image, for: "next")
        XCTAssertNotNil(cache.value(for: "current")); XCTAssertNotNil(cache.value(for: "previous")); XCTAssertNotNil(cache.value(for: "next"))
        cache.insert(image, for: "third")
        XCTAssertNotNil(cache.value(for: "current")); XCTAssertNotNil(cache.value(for: "third"))
        XCTAssertNil(cache.value(for: "previous"))
        cache.clear(); XCTAssertNil(cache.value(for: "current"))
    }
    private func realSample(_ name: String) throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOSELECT_ARW_SAMPLE_DIRECTORY"] else {
            throw XCTSkip("실제 Sony ARW fixture 경로가 지정되지 않았습니다.")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)); return url
    }
    private func validateRealSample(_ name: String, width: Int, height: Int, sensor: CGSize, color: String) throws {
        let url = try realSample(name), pipeline = ImagePipeline()
        pipeline.retain(photos: [Photo(url: url)])
        let start = ProcessInfo.processInfo.systemUptime
        let (display, _) = try load(pipeline, url)
        let cold = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(display.image.width, width); XCTAssertEqual(display.image.height, height)
        XCTAssertEqual(display.sourceSize, CGSize(width: width, height: height)); XCTAssertEqual(display.sensorSize, sensor)
        XCTAssertEqual(display.colorSpaceDescription, color)
        let warmStart = ProcessInfo.processInfo.systemUptime
        let immediate = try XCTUnwrap(pipeline.cached(Photo(url: url), quality: .full))
        let warm = (ProcessInfo.processInfo.systemUptime - warmStart) * 1000
        XCTAssertTrue(immediate.image === display.image)
        let (zoom, hit) = try load(pipeline, url, .full); XCTAssertTrue(hit); XCTAssertTrue(zoom.image === display.image)
        let (thumbnail, _) = try load(pipeline, url, .thumbnail)
        let a = try mean(display.image), b = try mean(thumbnail.image)
        for channel in 0..<3 { XCTAssertEqual(a[channel], b[channel], accuracy: 0.04) }
        let delta = zip(a, b).map { abs($0.0 - $0.1) }.max() ?? 0
        let extractionStart = ProcessInfo.processInfo.systemUptime
        _ = try EmbeddedPreview.extract(from: url)
        let extractionWarmFileMs = (ProcessInfo.processInfo.systemUptime - extractionStart) * 1000
        print("REAL_ARW \(name) native=\(width)x\(height) coldMs=\(cold) warmLookupMs=\(warm) displayZoomSameObject=true colors=\(color)")
        if let path = ProcessInfo.processInfo.environment["PHOTOSELECT_UI_SNAPSHOT_PATH"] {
            let camera = name.contains("A7M3") ? "A7M3" : "A7M4"
            let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("arw-pipeline-" + camera + ".json")
            #if DEBUG
            let configuration = "Debug"
            #else
            let configuration = "Release"
            #endif
            let evidence: [String: Any] = ["configuration": configuration, "file": name, "nativeWidth": width, "nativeHeight": height,
                "sensorWidth": sensor.width, "sensorHeight": sensor.height, "sensorParity": display.fullResolution,
                "colorManagement": color, "coldDecodeMs": cold, "warmSynchronousLookupMs": warm,
                "extractionWarmFileMs": extractionWarmFileMs,
                "displayAndZoomSameCGImage": true, "displayMeanSRGB": a, "thumbnailMeanSRGB": b,
                "maxMeanSRGBDifference": delta]
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        }
    }
    func testRealSonyA7M3PortraitAdobeRGBPreviewIsStableAndHonest() throws {
        try validateRealSample("Sony-A7M3.arw", width: 1080, height: 1616,
            sensor: CGSize(width: 4000, height: 6000), color: "Adobe RGB → sRGB")
    }
    func testRealSonyA7M4FullSizeCameraJPEGIsStableAndColorManaged() throws {
        try validateRealSample("Sony-A7M4.ARW", width: 7008, height: 4672,
            sensor: CGSize(width: 7008, height: 4672), color: "sRGB")
    }
}
