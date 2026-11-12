// Read-only verification of the installed bundle's icon; not part of the app target.
import AppKit
import CryptoKit
import ImageIO
import Foundation

struct IconCheckError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw IconCheckError(message: message) }
}
func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw IconCheckError(message: "Cannot decode icon image: \(url.lastPathComponent)")
    }
    return image
}
func raster(_ image: CGImage, side: Int) throws -> (CGImage, Data) {
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw IconCheckError(message: "Cannot allocate icon verification raster")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let rendered = context.makeImage(), let pixels = context.data else {
        throw IconCheckError(message: "Cannot render icon verification raster")
    }
    return (rendered, Data(bytes: pixels, count: side * side * 4))
}
func meanRGBError(_ first: Data, _ second: Data) -> Double {
    precondition(first.count == second.count)
    return first.withUnsafeBytes { a in
        second.withUnsafeBytes { b in
            let left = a.bindMemory(to: UInt8.self), right = b.bindMemory(to: UInt8.self)
            var sum: UInt64 = 0
            for index in 0..<left.count where index % 4 != 3 {
                sum += UInt64(abs(Int(left[index]) - Int(right[index])))
            }
            return Double(sum) / Double(left.count / 4 * 3 * 255)
        }
    }
}

do {
    try require(CommandLine.arguments.count == 4, "Usage: verify-app-icon.swift source.png bundle.app output-directory")
    let fileManager = FileManager.default
    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let appURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
    let sourceData = try Data(contentsOf: sourceURL)
    let source = try loadImage(sourceURL)
    try require(source.width == 1024 && source.height == 1024, "Official icon must be 1024 × 1024")
    guard let bundle = Bundle(url: appURL),
          let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else {
        throw IconCheckError(message: "Bundle icon registration is missing")
    }
    try require(iconName == "AppIcon.icns", "Unexpected CFBundleIconFile")
    let iconURL = appURL.appendingPathComponent("Contents/Resources").appendingPathComponent(iconName)
    let iconsetURL = outputURL.appendingPathComponent("verified-AppIcon.iconset", isDirectory: true)
    if fileManager.fileExists(atPath: iconsetURL.path) { try fileManager.removeItem(at: iconsetURL) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "iconset", "--output", iconsetURL.path, iconURL.path]
    try process.run(); process.waitUntilExit()
    try require(process.terminationStatus == 0, "Cannot decode the generated ICNS")
    var sizes: [String: Int] = [:]
    for side in [16, 32, 128, 256, 512] {
        for retina in [false, true] {
            let name = "icon_\(side)x\(side)" + (retina ? "@2x" : "") + ".png"
            let expected = side * (retina ? 2 : 1)
            let frame = try loadImage(iconsetURL.appendingPathComponent(name))
            try require(frame.width == expected && frame.height == expected, "Wrong ICNS rendition: \(name)")
            sizes[name] = expected
        }
    }
    let largest = try loadImage(iconsetURL.appendingPathComponent("icon_512x512@2x.png"))
    let sourceRaster = try raster(source, side: 1024)
    let largestRaster = try raster(largest, side: 1024)
    let largestError = meanRGBError(sourceRaster.1, largestRaster.1)
    try require(largestError < 0.03, "Packaged ICNS does not match the supplied artwork")

    // NSWorkspace is the native icon lookup used for files/app bundles in Finder.
    // The arm64 application is not launched on this Intel verification host.
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let finder = NSWorkspace.shared.icon(forFile: appURL.path)
    finder.size = NSSize(width: 512, height: 512)
    var rect = NSRect(x: 0, y: 0, width: 512, height: 512)
    guard let resolved = finder.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        throw IconCheckError(message: "Finder cannot resolve the application's icon")
    }
    let finderRaster = try raster(resolved, side: 512)
    let comparison = try raster(source, side: 512)
    let finderError = meanRGBError(finderRaster.1, comparison.1)
    let finderPNG = outputURL.appendingPathComponent("finder-icon.png")
    guard let png = NSBitmapImageRep(cgImage: finderRaster.0).representation(using: .png, properties: [:]) else {
        throw IconCheckError(message: "Cannot save Finder icon evidence")
    }
    try png.write(to: finderPNG)
    let report: [String: Any] = [
        "source_sha256": SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined(),
        "source_dimensions": [source.width, source.height],
        "bundle_identifier": bundle.bundleIdentifier ?? "",
        "bundle_version": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        "bundle_short_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        "CFBundleIconFile": iconName, "renditions": sizes,
        "largest_rendition_mean_rgb_error": largestError,
        "finder_mean_rgb_error": finderError, "finder_evidence": "finder-icon.png",
        "dock_on_apple_silicon_executed": false
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: outputURL.appendingPathComponent("icon-validation.json"))
    print("Verified official artwork in AppIcon.icns: 10 renditions, 16–1024 pixels; Finder lookup captured")
} catch {
    fputs("Icon verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
