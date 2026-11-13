import Foundation
import CoreGraphics

struct Photo: Hashable {
    let url: URL
    static func accepts(_ url: URL) -> Bool {
        ["arw", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }
}

// Browser contents are separate from the photo-only viewer sequence.
struct BrowserEntry {
    let url: URL
    let isDirectory: Bool
    var fileBytes: Int64? = nil
    var capturedAt: Date? = nil
    var isPhoto: Bool { !isDirectory && (Photo.accepts(url) || ["png", "heic", "heif", "tif", "tiff", "gif", "bmp"].contains(url.pathExtension.lowercased())) }
    static func read(_ folder: URL, showHidden: Bool) throws -> [BrowserEntry] {
        try FolderReader.entries(folder, directories: false, allFiles: true, showHidden: showHidden)
            .map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return BrowserEntry(url: url, isDirectory: values?.isDirectory == true, fileBytes: values?.fileSize.map(Int64.init))
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
    }
}

struct PhotoList {
    private(set) var photos: [Photo] = []
    private(set) var selectedIndex: Int?
    var selectedPhoto: Photo? { selectedIndex.map { photos[$0] } }

    mutating func replace(with photos: [Photo]) {
        self.photos = photos
        selectedIndex = photos.isEmpty ? nil : 0
    }
    mutating func clearSelection() { selectedIndex = nil }
    @discardableResult
    mutating func select(_ index: Int) -> Bool {
        guard photos.indices.contains(index) else { return false }
        selectedIndex = index
        return true
    }
    @discardableResult
    mutating func remove(_ url: URL) -> Bool {
        guard let removed = photos.firstIndex(where: { $0.url == url }) else { return false }
        let selectedURL = selectedPhoto?.url
        photos.remove(at: removed)
        if photos.isEmpty { selectedIndex = nil }
        else if selectedURL == url { selectedIndex = min(removed, photos.count - 1) }
        else { selectedIndex = photos.firstIndex(where: { $0.url == selectedURL }) ?? 0 }
        return true
    }
}

// NSScreen.visibleFrame is already in logical points, including on Retina.
// Backing scale belongs in pixel zoom, never in window/column sizing.
enum WindowLayout {
    enum Kind: Equatable { case browser, viewer }
    struct Columns {
        let folders: CGFloat
        let photos: CGFloat
        let preview: CGFloat
    }
    static func usableFrame(in visible: CGRect) -> CGRect {
        visible.insetBy(dx: min(12, visible.width * 0.02), dy: min(12, visible.height * 0.02))
    }
    static func minimumSize(in visible: CGRect, kind: Kind) -> CGSize {
        let safe = kind == .viewer ? visible : usableFrame(in: visible)
        let preferred = kind == .browser ? CGSize(width: 900, height: 560) : CGSize(width: 640, height: 480)
        return CGSize(width: min(preferred.width, safe.width), height: min(preferred.height, safe.height))
    }
    static func initialFrame(in visible: CGRect, kind: Kind) -> CGRect {
        // Fill the available screen with the outer window frame, title bar included.
        // visibleFrame already excludes the menu bar and a visible Dock.
        if kind == .viewer { return visible }
        let safe = usableFrame(in: visible)
        let minimum = minimumSize(in: visible, kind: kind)
        let preferred = CGSize(width: min(1600, visible.width * 0.92), height: min(1000, visible.height * 0.90))
        let size = CGSize(width: min(safe.width, max(minimum.width, preferred.width)),
                          height: min(safe.height, max(minimum.height, preferred.height)))
        return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    static func fittedFrame(_ frame: CGRect, in visible: CGRect, kind: Kind) -> CGRect {
        let safe = kind == .viewer ? visible : usableFrame(in: visible)
        let minimum = minimumSize(in: visible, kind: kind)
        let size = CGSize(width: min(safe.width, max(minimum.width, frame.width)),
                          height: min(safe.height, max(minimum.height, frame.height)))
        return CGRect(x: min(max(frame.minX, safe.minX), safe.maxX - size.width),
                      y: min(max(frame.minY, safe.minY), safe.maxY - size.height),
                      width: size.width, height: size.height)
    }
    static func columns(for width: CGFloat, divider: CGFloat = 1, preferredFolders: CGFloat? = nil, preferredPreview: CGFloat? = nil) -> Columns {
        let usable = max(0, width - divider * 2)
        var folders = max(144, preferredFolders ?? min(240, max(144, usable * 0.18)))
        var preview = max(168, preferredPreview ?? min(320, max(168, usable * 0.22)))
        let photoMinimum = (preferredFolders != nil || preferredPreview != nil) ? min(300, usable * 0.5) : usable * 0.5
        let sideBudget = usable - photoMinimum
        if folders + preview > sideBudget {
            let scale = sideBudget / (folders + preview)
            folders *= scale; preview *= scale
        }
        return Columns(folders: folders, photos: usable - folders - preview, preview: preview)
    }
}

// All coordinates here are in view points. One source pixel occupies 1/backingScale points.
enum ZoomGeometry {
    static func rect(image: CGSize, view: CGSize, cursor: CGPoint, backingScale: CGFloat) -> CGRect {
        let fit = min(view.width / image.width, view.height / image.height)
        let origin = CGPoint(x: (view.width - image.width * fit) / 2,
                             y: (view.height - image.height * fit) / 2)
        let u = min(1, max(0, (cursor.x - origin.x) / (image.width * fit)))
        let v = min(1, max(0, (cursor.y - origin.y) / (image.height * fit)))
        let size = CGSize(width: image.width / backingScale, height: image.height / backingScale)
        func offset(_ cursor: CGFloat, _ fraction: CGFloat, _ size: CGFloat, _ viewport: CGFloat) -> CGFloat {
            size <= viewport ? (viewport - size) / 2 : min(0, max(viewport - size, cursor - fraction * size))
        }
        return CGRect(x: offset(cursor.x, u, size.width, view.width),
                      y: offset(cursor.y, v, size.height, view.height), width: size.width, height: size.height)
    }
}

// The folder lease stays alive in every decode operation, including canceled operations
// whose synchronous system decoder has not returned yet.
final class FolderLease {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

enum FolderReader {
    static func errorMessage(for error: Error) -> String {
        let nsError = error as NSError
        let denied = (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.fileReadNoPermission.rawValue) ||
            (nsError.domain == NSPOSIXErrorDomain && [1, 13].contains(nsError.code))
        if denied {
            return "접근 권한이 필요합니다. ‘폴더 열기…’에서 이 폴더를 다시 선택해 주세요."
        }
        return error.localizedDescription
    }
    static func entries(_ url: URL, directories: Bool, allFiles: Bool = false, showHidden: Bool = false) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles]).filter { item in
                let values = try item.resourceValues(forKeys: keys)
                // Do not follow symlinks outside the selected security scope.
                guard values.isSymbolicLink != true else { return false }
                if allFiles { return true }
                return directories ? values.isDirectory == true : values.isRegularFile == true && Photo.accepts(item)
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
